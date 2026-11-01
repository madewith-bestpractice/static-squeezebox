# Checks Schedule.pm's live math against the published schedule, without LMS.
use strict; use lib "$ENV{T}/stub"; use lib "$ENV{T}/../StaticRadio/..";
BEGIN { $INC{'Plugins/StaticRadio/Schedule.pm'} = "$ENV{T}/../StaticRadio/Schedule.pm"; require "$ENV{T}/../StaticRadio/Schedule.pm"; }
use JSON::PP;
open my $fh, '<', $ARGV[0] or die; local $/; my $raw = decode_json(<$fh>);
my $s = Plugins::StaticRadio::Schedule::_build($raw) or die "build failed";
{ no warnings; $Plugins::StaticRadio::Schedule::{schedule}; }
# install it as the cached schedule
{ package Plugins::StaticRadio::Schedule; no strict 'vars'; }
my $t = $ARGV[1] || int(time() * 1000);
Plugins::StaticRadio::Schedule::_set_for_test($s);
for my $st (@{ $s->{stations} }) {
  my $l = Plugins::StaticRadio::Schedule->live($st, $t);
  printf "%s|%s|%d|%d\n", $st->{id}, $l->{ep}{audioUrl}, int($l->{offset_ms}/1000), $l->{bulletin};
}
