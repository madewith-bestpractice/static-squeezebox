package Plugins::StaticRadio::Slots;

# Bulletin slot list: what plays in each bulletin break, decided by the
# bulletin board (GET https://bulletin.staticradio.app/api/slots/{date}), so
# every listener on a station hears the same bulletin. The phones' rule
# (mobile_app/lib/audio/bulletin_slots.dart), as on the Chumby and Playdate:
#  - follow the list: a `paid` or `house` entry with content replaces the
#    baked break's audio (and link);
#  - no list, no entry, `baked`, an unknown kind, a failed fetch: play the
#    baked break exactly as the schedule says.
# Breaks match on (station, placementId), nearest in time within 2 h; the date
# is the US Central broadcast date. The list is refreshed when a break is about
# to start if it's more than a minute old: inside the board's 7 minute lock,
# so what it says then is final.

use strict;

use JSON::XS::VersionOneAndTwo;
use Time::Local qw(timegm);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use constant URL          => 'https://bulletin.staticradio.app/api/slots/';
use constant MAX_AGE_S    => 60;
use constant RETRY_S      => 30;
use constant TOLERANCE_MS => 2 * 3600 * 1000;

my $log = logger('plugin.staticradio');

# board channel id -> app station id
my %CHANNEL = (1 => 'nature_01', 2 => 'work_01', 3 => 'learn_01', 4 => 'weird_01',
               5 => 'unite_01', 6 => 'make_01', 9 => 'news_01');

my @slots;
my $fetchedAt = 0;
my $fetching;
my @waiting;

sub _first_sunday {
	my ($y, $m) = @_;
	my $dow = (gmtime(timegm(0, 0, 0, 1, $m - 1, $y)))[6];
	return 1 + (7 - $dow) % 7;
}

# US Central daylight time: second Sunday of March 08:00 UTC to first Sunday
# of November 07:00 UTC.
sub _central_dst {
	my $ms = shift;
	my $y = (gmtime(int($ms / 1000)))[5] + 1900;
	my $start = timegm(0, 0, 8, _first_sunday($y, 3) + 7, 2, $y) * 1000;
	my $end   = timegm(0, 0, 7, _first_sunday($y, 11), 10, $y) * 1000;
	return $ms >= $start && $ms < $end;
}

sub central_date {
	my ($class, $ms) = @_;
	my @g = gmtime(int($ms / 1000) - (_central_dst($ms) ? 5 : 6) * 3600);
	return sprintf('%04d-%02d-%02d', $g[5] + 1900, $g[4] + 1, $g[3]);
}

sub fresh { time() - $fetchedAt < MAX_AGE_S }

# refresh(sub { ... }): fetch today's list (and tomorrow's near Central
# midnight) unless fresh; the callback always runs, list or not.
sub refresh {
	my ($class, $cb) = @_;
	if (fresh()) { $cb->(); return }
	push @waiting, $cb;
	return if $fetching;
	$fetching = 1;
	my $now = Plugins::StaticRadio::Schedule::now_ms();
	my @dates = ($class->central_date($now));
	my $later = $class->central_date($now + 3 * 3600 * 1000);
	push @dates, $later if $later ne $dates[0];
	my $left = scalar @dates;
	my (@got, $ok);
	for my $date (@dates) {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $data = eval { from_json(${ $http->contentRef }) };
				if ($data && ref $data->{slots} eq 'ARRAY') { push @got, _parse($data); $ok = 1 }
				else { $log->warn("slots: bad list for $date") }
				_one(\$left, \@got, $ok);
			},
			sub {
				$log->warn("slots: fetch $date failed: $_[1]");
				_one(\$left, \@got, $ok);
			},
			{ timeout => 10 },
		)->get(URL . $date);
	}
}

sub _one {
	my ($left, $got, $ok) = @_;
	return if --$$left;
	if ($ok) { @slots = @$got; $fetchedAt = time() }
	else     { $fetchedAt = time() - MAX_AGE_S + RETRY_S }   # keep what we had; try again soon
	$fetching = 0;
	my @cbs = @waiting;
	@waiting = ();
	$_->() for @cbs;
}

sub _iso_ms {
	my $s = shift || return 0;
	my ($y, $mo, $d, $h, $mi, $se, $rest) = $s =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)(.*)$/ or return 0;
	my $t = timegm($se, $mi, $h, $d, $mo - 1, $y);
	$t -= ($1 eq '+' ? 1 : -1) * ($2 * 3600 + $3 * 60) if $rest =~ /([+-])(\d\d):(\d\d)/;
	return $t * 1000;
}

sub _parse {
	my $data = shift;
	my @out;
	for my $e (@{ $data->{slots} }) {
		next unless ref $e eq 'HASH';
		my $cat = $CHANNEL{ $e->{channel_id} // '' } or next;
		my $at = _iso_ms($e->{play_at_utc}) or next;
		next unless $e->{placement_id};
		push @out, {
			cat         => $cat,
			placement   => $e->{placement_id},
			at          => $at,
			# an unknown kind from a newer board: baked, never guess
			kind        => ($e->{kind} // '') =~ /^(paid|house)$/ ? $1 : 'baked',
			bulletin_id => $e->{bulletin_id},
			audio       => $e->{audio_url},
			link        => $e->{link_url},
		};
	}
	return @out;
}

# The entry to play for the baked break $ep on station $station starting at
# $at (ms), or undef for "play the baked break".
sub swap_for {
	my ($class, $station, $ep, $at) = @_;
	my $placement = $ep->{placementId} or return;
	my ($best, $best_d) = (undef, TOLERANCE_MS + 1);
	for my $s (@slots) {
		next unless $s->{placement} eq $placement && $s->{cat} eq $station;
		my $d = abs($s->{at} - $at);
		($best, $best_d) = ($s, $d) if $d < $best_d;
	}
	return unless $best && $best->{kind} ne 'baked' && $best->{bulletin_id} && $best->{audio};
	return if $best->{audio} eq ($ep->{audioUrl} || '');
	return $best;
}

# tests only
sub _set_for_test { my $class = shift; @slots = map { _parse($_) } @_; $fetchedAt = time() }

1;
