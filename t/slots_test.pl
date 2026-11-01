#!/usr/bin/perl
# Offline check of Slots.pm: Central dates and matching. t/slots_test.pl
use strict;
BEGIN {
	for my $m (qw(Slim/Networking/SimpleAsyncHTTP.pm Slim/Utils/Log.pm JSON/XS/VersionOneAndTwo.pm)) { $INC{$m} = 1 }
	package Slim::Utils::Log; sub import { no strict 'refs'; *{caller() . '::logger'} = sub { bless {}, 'Log' } }
	package Log; sub info {} sub debug {} sub warn {}
	package JSON::XS::VersionOneAndTwo; sub import { no strict 'refs'; require JSON::PP; *{caller() . '::from_json'} = sub { JSON::PP::decode_json($_[0]) } }
}
use FindBin;
require "$FindBin::Bin/../StaticRadio/Slots.pm";
my $S = 'Plugins::StaticRadio::Slots';
my $bad = 0;
for ([1793505600000, '2026-10-31'], [1793512740000, '2026-11-01'], [1793516340000, '2026-11-01'],
     [1793516400000, '2026-11-01'], [1793599140000, '2026-11-01'], [1793599200000, '2026-11-02'], [1773043200000, '2026-03-09']) {
	my $d = $S->central_date($_->[0]);
	if ($d ne $_->[1]) { print "DATE FAIL $_->[0]: $d want $_->[1]\n"; $bad++ }
}
print "dates: ", ($bad ? "FAIL" : "ok"), "\n";
my $list = { slots => [
	{ channel_id => 9, placement_id => 'p1', play_at_utc => '2026-11-01T22:16:43+00:00', kind => 'paid', bulletin_id => 'bulletin-x', audio_url => 'https://x/a.mp3', link_url => 'https://x/' },
	{ channel_id => 9, placement_id => 'p1', play_at_utc => '2026-11-02T16:29:26+00:00', kind => 'house', bulletin_id => 'bulletin-y', audio_url => 'https://x/b.mp3' },
	{ channel_id => 9, placement_id => 'p2', play_at_utc => '2026-11-01T22:16:43+00:00', kind => 'surprise', bulletin_id => 'bulletin-z', audio_url => 'https://x/c.mp3' },
] };
$S->_set_for_test($list);
my $at = 1793571403000;   # 2026-11-01T22:16:43Z
my $r = $S->swap_for('news_01', { placementId => 'p1', audioUrl => 'https://base' }, $at);
print "nearest paid: ", ($r && $r->{bulletin_id} eq 'bulletin-x' ? 'ok' : 'FAIL'), "\n";
print "unknown kind plays baked: ", ($S->swap_for('news_01', { placementId => 'p2', audioUrl => 'https://base' }, $at) ? 'FAIL' : 'ok'), "\n";
print "other station plays baked: ", ($S->swap_for('work_01', { placementId => 'p1', audioUrl => 'https://base' }, $at) ? 'FAIL' : 'ok'), "\n";
print "3 h off plays baked: ", ($S->swap_for('news_01', { placementId => 'p1', audioUrl => 'https://base' }, $at - 3 * 3600 * 1000) ? 'FAIL' : 'ok'), "\n";
