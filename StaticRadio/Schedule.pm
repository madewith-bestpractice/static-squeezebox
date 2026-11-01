package Plugins::StaticRadio::Schedule;

# The day's schedule and the phone's live-position rules: every station is a
# loop of episodes that started at the schedule's daily epoch, with a 1.5 s gap
# after each episode (sync_controller.dart _resolveLiveEpisodeForSchedule).
# Everyone who tunes in at the same moment lands on the same moment.

use strict;

use JSON::XS::VersionOneAndTwo;
use Time::HiRes;
use Time::Local qw(timegm);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use constant SCHEDULE_URL    => 'https://data.staticradio.app/schedule-wear.json';
use constant REFRESH_SECONDS => 15 * 60;
use constant GAP_MS          => 1500;
use constant BULLETIN_CAP_MS => 30_000;   # bulletins never play past 30 s (radio_audio_engine.dart)

my $log = logger('plugin.staticradio');

my $schedule;        # { epoch_ms, generated, stations => [ {id, tag, name, loop_ms, eps => [...] } ] }
my $fetchedAt = 0;
my @waiting;         # callbacks waiting for a fetch in flight
my $fetching;

sub now_ms { int(Time::HiRes::time() * 1000) }

sub _parse_iso_ms {
	my $s = shift || return 0;
	my ($y, $mo, $d, $h, $mi, $se, $rest) = $s =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)(.*)$/ or return 0;
	my $t = timegm($se, $mi, $h, $d, $mo - 1, $y);
	if ($rest =~ /([+-])(\d\d):(\d\d)/) {
		my $off = $2 * 3600 + $3 * 60;
		$t -= ($1 eq '+' ? $off : -$off);
	}
	return $t * 1000;
}

sub _build {
	my $raw = shift;
	my $epoch = _parse_iso_ms($raw->{daily_epoch_utc}) or return;
	my $cats = $raw->{categories} || {};
	my @stations;
	for my $id (keys %$cats) {
		my $c = $cats->{$id};
		next if exists $c->{is_active} && !$c->{is_active};
		my @eps = grep { ($_->{durationInSeconds} || 0) > 0 } @{ $c->{episodes} || [] };
		next unless @eps;
		my $tag = $c->{u_tag} || uc($c->{display_name} || $id);
		$tag =~ s/ [AB]$//;              # "SHEILA B" -> "SHEILA", as on the watches
		$tag = 'WEiRD' if $tag eq 'WEIRD';
		my $sum = 0;
		$sum += $_->{durationInSeconds} * 1000 for @eps;
		push @stations, {
			id      => $id,
			tag     => $tag,
			name    => $c->{display_name} || $tag,
			sort    => $c->{sort_index} // 999,
			loop_ms => ($c->{loop_duration_seconds} || 0) * 1000,
			sum_ms  => $sum,
			eps     => \@eps,
		};
	}
	@stations = sort { $a->{sort} <=> $b->{sort} } grep { $_->{loop_ms} > 0 } @stations;
	return unless @stations;
	return { epoch_ms => $epoch, generated => $raw->{generated_at_utc}, stations => \@stations };
}

# get(sub { my $schedule = shift; ... }) - cached, refreshed every 15 minutes
sub get {
	my ($class, $cb) = @_;
	if ($schedule && time() - $fetchedAt < REFRESH_SECONDS) {
		$cb->($schedule);
		return;
	}
	push @waiting, $cb;
	return if $fetching;
	$fetching = 1;
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $fresh = eval { _build(from_json(${ $http->contentRef })) };
			$log->error("schedule: couldn't read it: $@") if $@;
			if ($fresh) {
				# never play another broadcast day's timeline
				my $age = now_ms() - $fresh->{epoch_ms};
				if (abs($age) < 30 * 3600 * 1000) {
					$schedule = $fresh;
					$fetchedAt = time();
					main::INFOLOG && $log->info("schedule: " . scalar(@{ $fresh->{stations} }) . " stations, generated $fresh->{generated}");
				}
			}
			_done();
		},
		sub {
			my ($http, $error) = @_;
			$log->warn("schedule: fetch failed: $error");
			_done();
		},
		{ timeout => 30 },
	)->get(SCHEDULE_URL);
}

sub _done {
	$fetching = 0;
	my @cbs = @waiting;
	@waiting = ();
	$_->($schedule) for @cbs;
}

sub station {
	my ($class, $id) = @_;
	return unless $schedule;
	return (grep { $_->{id} eq $id } @{ $schedule->{stations} })[0];
}

# The live episode on a station at time t (ms): returns a hash with the
# episode, its offset into the slot, the slot's start, its length and the
# audio end (the duration, or the bulletin cap).
sub live {
	my ($class, $st, $t) = @_;
	return unless $schedule && $st;
	$t //= now_ms();
	my $n     = scalar @{ $st->{eps} };
	my $pad   = $n * GAP_MS;
	my $loop  = $st->{loop_ms} + $pad;
	my $total = $st->{sum_ms} + $pad;
	my $pos = ($t - $schedule->{epoch_ms}) % $loop;
	$pos += $loop if $pos < 0;
	$pos %= $total;
	my $acc = 0;
	for my $i (0 .. $n - 1) {
		my $ep  = $st->{eps}[$i];
		my $len = $ep->{durationInSeconds} * 1000 + GAP_MS;
		if ($acc + $len > $pos) {
			my $audio_end = $ep->{durationInSeconds} * 1000;
			my $bulletin = $ep->{isBulletin} || lc($ep->{sponsorName} || '') eq 'community bulletin';
			$audio_end = BULLETIN_CAP_MS if $bulletin && $audio_end > BULLETIN_CAP_MS;
			return {
				ep         => $ep,
				slot       => $i,
				offset_ms  => $pos - $acc,
				slot_start => $t - ($pos - $acc),
				slot_ms    => $len,
				audio_end  => $audio_end,
				bulletin   => $bulletin ? 1 : 0,
			};
		}
		$acc += $len;
	}
	return;
}

# tests only
sub _set_for_test { $schedule = shift; $fetchedAt = time() }

1;
