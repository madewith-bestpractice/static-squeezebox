package Plugins::StaticRadio::ProtocolHandler;

# staticradio://station/<id> is a repeating stream: whenever the player needs
# something to play, getNextTrack() works out the station's live episode (the
# phone's timeline), has Lyrion scan it (redirects, format, bitrate) and starts
# it at the live offset with a ranged request to the show's own host. Nothing
# is proxied or stored by us: the player (or the listener's own server) fetches
# each episode from its publisher, so every listen counts as a normal download.

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Utils::Scanner::Remote;

use Plugins::StaticRadio::Schedule;

my $log = logger('plugin.staticradio');

# Start this far ahead of the live moment: the scan, the request and the
# player's buffer all take time before the first sample is heard.
use constant LEAD_MS => 2500;

my %now;   # client id => what's on: { station, key, show, title, image, link, slot_end }

sub isRepeatingStream { 1 }
sub canSeek { 0 }               # the live moment decides where we are
sub isRemote { 1 }

sub _station_id {
	my $url = shift || '';
	return $url =~ m{^staticradio://station/([\w-]+)} ? $1 : undef;
}

sub new {
	my ($class, $args) = @_;
	# stream the episode, not our station URL
	$args->{url} = $args->{song}->streamUrl unless $args->{redir};
	return $class->SUPER::new($args);
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $client = $song->master;
	my $id = _station_id($song->track->url) or return $errorCb->('PROBLEM_OPENING_REMOTE_URL');

	Plugins::StaticRadio::Schedule->get(sub {
		my $schedule = shift;
		my $st = $schedule && Plugins::StaticRadio::Schedule->station($id);
		return $errorCb->('PLUGIN_STATICRADIO_NO_SCHEDULE', $song->track->url) unless $st;

		my $t    = Plugins::StaticRadio::Schedule::now_ms();
		my $live = Plugins::StaticRadio::Schedule->live($st, $t + LEAD_MS)
			or return $errorCb->('PLUGIN_STATICRADIO_NO_SCHEDULE', $song->track->url);
		my $ep  = $live->{ep};
		my $key = "$ep->{audioUrl}|$live->{slot_start}";
		my $was = $now{ $client->id } || {};
		# called again because the last episode ended (not a fresh tune)?
		my $cur = $song->_currentTrack;
		my $repeat = $cur && $cur->url ne $song->track->url;

		# In the gap after an episode (or past a bulletin's 30 s), or this episode
		# already played to its end: wait quietly for the next one, as the phone does.
		if ($live->{offset_ms} >= $live->{audio_end} - 1000 || ($repeat && $was->{key} && $was->{key} eq $key)) {
			my $wait_ms = $live->{slot_start} + $live->{slot_ms} - ($t + LEAD_MS) + 50;
			$wait_ms = 250 if $wait_ms < 250;
			main::INFOLOG && $log->info("$id: between episodes, next in ${wait_ms} ms");
			Slim::Utils::Timers::killTimers($client, \&_retry);
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $wait_ms / 1000, \&_retry, $class, $song, $successCb, $errorCb);
			return;
		}

		main::INFOLOG && $log->info(sprintf("%s: %s / %s at %.1f s", $id, $ep->{feedTitle}, $ep->{title}, $live->{offset_ms} / 1000));

		Slim::Utils::Scanner::Remote->scanURL($ep->{audioUrl}, {
			client => $client,
			song   => $song,
			title  => $ep->{title},
			cb     => sub {
				my ($track, $error) = @_;
				if (!$track) {
					$log->warn("$id: couldn't open $ep->{audioUrl}: " . ($error || '?'));
					return $errorCb->($error || 'PROBLEM_OPENING_REMOTE_URL', $song->track->url);
				}

				# the episode is what's playing; our station URL stays the playlist item
				$song->_currentTrack($track);
				$song->streamUrl($track->url);
				$track->title($ep->{title});

				# land on the true live position: recompute now that the scan is done
				my $off = Plugins::StaticRadio::Schedule->live($st, Plugins::StaticRadio::Schedule::now_ms() + LEAD_MS);
				my $start_s = ($off && $off->{slot_start} == $live->{slot_start}) ? $off->{offset_ms} / 1000 : $live->{offset_ms} / 1000;
				if ($start_s > 1) {
					if (my $seek = $song->getSeekData($start_s)) {
						$song->seekdata($seek);
					} else {
						$log->warn("$id: can't seek in this file (no bitrate); starting from the top");
					}
				}

				$now{ $client->id } = {
					station  => $id,
					tag      => $st->{tag},
					key      => $key,
					show     => $ep->{feedTitle},
					title    => $ep->{title},
					image    => $ep->{imageUrl},
					link     => $ep->{episodeUrl},
					slot_end => $live->{slot_start} + $live->{slot_ms},
					audio_end_wall => $live->{slot_start} + $live->{audio_end},
				};

				# leave the episode on time even if the file runs long (or a bulletin
				# passes 30 s): the timeline moves on whether or not the file has
				_schedule_end($client, $live->{slot_start} + $live->{audio_end});

				$successCb->();
			},
		});
	});
}

sub _retry {
	my ($client, $class, $song, $successCb, $errorCb) = @_;
	$class->getNextTrack($song, $successCb, $errorCb);
}

# At the scheduled end of the episode, if it's still playing, re-tune the
# station: getNextTrack then finds the next episode (or waits out the gap).
sub _schedule_end {
	my ($client, $end_ms) = @_;
	Slim::Utils::Timers::killTimers($client, \&_episode_end);
	my $in = ($end_ms - Plugins::StaticRadio::Schedule::now_ms()) / 1000;
	return if $in <= 0;
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $in + 0.5, \&_episode_end);
}

sub _episode_end {
	my $client = shift;
	my $song = $client->playingSong or return;
	return unless _station_id($song->track->url);
	return unless $client->isPlaying;
	main::INFOLOG && $log->info("episode's scheduled time is up; moving on with the timeline");
	$client->execute([ 'playlist', 'index', Slim::Player::Source::playingSongIndex($client) ]);
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;
	my $id = _station_id($url);
	my $n = $client && $now{ $client->id };
	if ($n && $id && $n->{station} eq $id) {
		return {
			title  => $n->{title},
			artist => $n->{show},
			album  => "Static Radio \x{b7} $n->{tag}",
			cover  => $n->{image} || 'plugins/StaticRadio/html/images/icon.png',
			icon   => 'plugins/StaticRadio/html/images/icon.png',
			type   => 'Static Radio',
			bitrate => '',
		};
	}
	my $st = $id && Plugins::StaticRadio::Schedule->station($id);
	return {
		title => $st ? "Static Radio \x{b7} $st->{tag}" : 'Static Radio',
		cover => 'plugins/StaticRadio/html/images/icon.png',
		icon  => 'plugins/StaticRadio/html/images/icon.png',
		type  => 'Static Radio',
	};
}

sub getIcon { 'plugins/StaticRadio/html/images/icon.png' }

sub onStop {
	my ($class, $song) = @_;
	my $client = $song->master or return;
	Slim::Utils::Timers::killTimers($client, \&_episode_end);
	Slim::Utils::Timers::killTimers($client, \&_retry);
}

1;
