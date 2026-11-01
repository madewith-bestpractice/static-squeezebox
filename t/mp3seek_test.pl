#!/usr/bin/perl
# Offline check of MP3Seek's header parsing: t/mp3seek_test.pl <file.mp3> <total size> <seconds> [<duration>]
# Prints the byte the plugin would seek to.
use strict;
BEGIN {
	for my $m (qw(HTTP/Request.pm Slim/Networking/Async/HTTP.pm Slim/Utils/Log.pm)) { $INC{$m} = 1 }
	package Slim::Utils::Log; sub import { no strict 'refs'; *{caller() . '::logger'} = sub { bless {}, 'Log' } }
	package Log; sub info {} sub debug {} sub warn {}
}
use FindBin; use lib "$FindBin::Bin/../..";
require "$FindBin::Bin/../StaticRadio/MP3Seek.pm";
my ($file, $total, $s, $dur) = @ARGV;
open my $fh, '<:raw', $file or die; local $/; my $b = <$fh>;
my $tag = Plugins::StaticRadio::MP3Seek::_id3_size($b);
my $i = Plugins::StaticRadio::MP3Seek::_first_frame(substr($b, $tag, 16384), $tag, $total);
printf "tag %d start %d kbps %d srate %d walked %d byte_rate %s vbr %s toc %s frames %s\n", $tag, $i->{audio_start}, $i->{kbps}, $i->{srate},
	$i->{walked}, defined $i->{byte_rate} ? sprintf('%.1f', $i->{byte_rate}) : '-', $i->{vbr} ? 1 : 0, $i->{toc} ? 1 : 0, $i->{frames} // '-';
printf "byte for %.1f s: %d\n", $s, Plugins::StaticRadio::MP3Seek->byte_for($i, $s, $dur);
