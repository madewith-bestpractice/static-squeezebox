package Plugins::StaticRadio::Presence;

# Listener presence and counts, the phone apps' contract (presence_manager.dart):
# PUT {rtdb}/presence/{station}/{device}.json {"ts":{".sv":"timestamp"}} every
# 30 s while listening (an entry counts for 75 s), DELETE when leaving.
# Counts for every station: GET staticradio.app/api/counts.
#
# Each player gets an anonymous device id derived from this server's own id and
# the player's id, so no MAC address leaves the house.

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use Time::HiRes;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant RTDB        => 'https://static-3c8b6-default-rtdb.firebaseio.com';
use constant COUNTS_URL  => 'https://staticradio.app/api/counts';
use constant HEARTBEAT_S => 30;
use constant COMMIT_S    => 3;     # count a listener after 3 s on a station, as the phone does
use constant COUNTS_S    => 60;

my $log = logger('plugin.staticradio');

my %on;            # client id => station id currently announced
my %want;          # client id => station id the player is tuned to
my %counts;        # station id => listeners
my $countsAt = 0;

sub device_id {
	my $client = shift;
	my $server = preferences('server')->get('server_uuid') || '';
	return 'sb' . substr(md5_hex("$server/" . $client->id), 0, 14);
}

sub _url {
	my ($station, $client) = @_;
	return RTDB . "/presence/$station/" . device_id($client) . '.json';
}

sub _put {
	my ($client, $station) = @_;
	Slim::Networking::SimpleAsyncHTTP->new(
		sub { main::DEBUGLOG && $log->is_debug && $log->debug("presence: on $station") },
		sub { $log->warn("presence: PUT $station failed: $_[1]") },
		{ timeout => 15 },
	)->put(_url($station, $client), 'Content-Type' => 'application/json', '{"ts":{".sv":"timestamp"}}');
}

sub _delete {
	my ($client, $station) = @_;
	Slim::Networking::SimpleAsyncHTTP->new(
		sub { main::DEBUGLOG && $log->is_debug && $log->debug("presence: left $station") },
		sub { $log->warn("presence: DELETE $station failed: $_[1]") },
		{ timeout => 15 },
	)->delete(_url($station, $client));
}

# The player is now tuned to $station (undef: not listening to Static).
sub tune {
	my ($class, $client, $station) = @_;
	return unless $client;
	my $id = $client->id;
	$want{$id} = $station;
	Slim::Utils::Timers::killTimers($client, \&_commit);
	if (!$station) {
		_leave($client);
		return;
	}
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + COMMIT_S, \&_commit);
}

sub _listening {
	my ($client, $station) = @_;
	return 0 unless $client->isPlaying;
	my $song = $client->playingSong or return 0;
	my $url = $song->track->url || '';
	return $url eq "staticradio://station/$station";
}

sub _commit {
	my $client = shift;
	my $id = $client->id;
	my $station = $want{$id};
	if (!$station || !_listening($client, $station)) {
		_leave($client);
		return;
	}
	if (($on{$id} || '') ne $station) {
		_delete($client, $on{$id}) if $on{$id};
		$on{$id} = $station;
		$log->info("presence: " . $client->name . " is listening on $station");
	}
	_put($client, $station);
	Slim::Utils::Timers::killTimers($client, \&_commit);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + HEARTBEAT_S, \&_commit);
}

sub _leave {
	my $client = shift;
	my $id = $client->id;
	Slim::Utils::Timers::killTimers($client, \&_commit);
	if (my $was = delete $on{$id}) {
		_delete($client, $was);
		$log->info("presence: " . $client->name . " left $was");
	}
}

# On server shutdown: take every player off the counts.
sub leave_all {
	for my $client (Slim::Player::Client::clients()) {
		_leave($client);
	}
}

# Listener counts, cached for a minute; count($station) is -1 until known.
sub refresh_counts {
	my ($class, $cb) = @_;
	if (time() - $countsAt < COUNTS_S) {
		$cb->() if $cb;
		return;
	}
	$countsAt = time();
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $data = eval { from_json(${ $http->contentRef }) };
			if ($data && ref $data->{counts} eq 'HASH') {
				%counts = %{ $data->{counts} };
			}
			$cb->() if $cb;
		},
		sub { $cb->() if $cb },
		{ timeout => 10 },
	)->get(COUNTS_URL);
}

sub count {
	my ($class, $station) = @_;
	return exists $counts{$station} ? $counts{$station} : -1;
}

1;
