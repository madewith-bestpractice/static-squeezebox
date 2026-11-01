package Plugins::StaticRadio::MP3Seek;

# Where in an MP3 file is second N? The phone apps' players answer from the
# file itself: the real size of the ID3 tag, then the Xing table of contents
# for VBR files or the frame bitrate for CBR ones. Lyrion's own remote seek
# divides by an average bitrate and can miss a large tag, which put VBR
# episodes up to a minute off the live moment. This reads the start of the
# file (a few KB, with a Range request) and does what the phones do.
# Same logic as the Chumby port's mp3probe.c.

use strict;

use HTTP::Request;

use Slim::Networking::Async::HTTP;
use Slim::Utils::Log;

my $log = logger('plugin.staticradio');

use constant HEAD_BYTES  => 32768;
use constant FRAME_BYTES => 16384;   # enough frames to measure the byte rate (~39 at 128 kbps)
use constant MAX_TAG    => 4 * 1024 * 1024;   # cover art can make a tag big; past this, give up

my @BR = (
	[0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0],   # MPEG1 layer III
	[0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],       # MPEG2/2.5 layer III
);
my @SR = ([44100, 48000, 32000], [22050, 24000, 16000], [11025, 12000, 8000]);

# Fetch bytes $from..$from+$len-1. $cb->($bytes, $total_size) or $cb->() on failure.
sub _range {
	my ($url, $from, $len, $cb) = @_;
	my $done;
	my $req = HTTP::Request->new(GET => $url);
	$req->header(Range => "bytes=$from-" . ($from + $len - 1));
	Slim::Networking::Async::HTTP->new->send_request({
		request   => $req,
		readLimit => $len,     # a host that ignores Range would otherwise send the whole episode
		Timeout   => 10,
		onBody    => sub {
			return if $done++;
			my $http = shift;
			my $res  = $http->response;
			my $body = $res->content;
			my $total;
			if (($res->header('Content-Range') || '') =~ m{/(\d+)}) {
				$total = $1;
			} elsif ($res->code == 200) {
				return $cb->() if $from > 0;   # Range ignored: what we have is the top, not $from
				$total = $res->header('Content-Length');
			}
			$cb->(substr($body, 0, $len), $total);
		},
		onError => sub {
			return if $done++;
			$log->info("mp3 probe of $url failed: $_[1]");
			$cb->();
		},
	});
}

sub _id3_size {
	my $b = shift;
	return 0 if length($b) < 10 || substr($b, 0, 3) ne 'ID3';
	my @s = unpack('C4', substr($b, 6, 4));
	return 0 if ($s[0] | $s[1] | $s[2] | $s[3]) & 0x80;      # not syncsafe: not a real tag
	my $flags = ord(substr($b, 5, 1));
	return 10 + ($s[0] << 21 | $s[1] << 14 | $s[2] << 7 | $s[3]) + (($flags & 0x10) ? 10 : 0);
}

# Parse the first frame (and its Xing/Info header) of $b, which starts at file
# offset $at. Returns an info hash or undef.
sub _first_frame {
	my ($b, $at, $total) = @_;
	my $len = length $b;
	for (my $i = 0; $i + 4 < $len && $i < 8192; $i++) {
		my ($b0, $b1, $b2, $b3) = unpack('C4', substr($b, $i, 4));
		next unless $b0 == 0xFF && ($b1 & 0xE0) == 0xE0;
		my $ver = ($b1 >> 3) & 3;           # 3 MPEG1, 2 MPEG2, 0 MPEG2.5
		my $layer = ($b1 >> 1) & 3;         # 1 = layer III
		my ($bri, $sri, $chan) = ($b2 >> 4, ($b2 >> 2) & 3, $b3 >> 6);
		next if $ver == 1 || $layer != 1 || $bri == 0 || $bri == 15 || $sri == 3;
		my $mpeg1 = $ver == 3;
		my %o = (
			audio_start => $at + $i,
			kbps        => $BR[$mpeg1 ? 0 : 1][$bri],
			srate       => $SR[$mpeg1 ? 0 : ($ver == 2 ? 1 : 2)][$sri],
			spf         => $mpeg1 ? 1152 : 576,
			total       => $total,
		);
		# Xing/Info follows the side info: MPEG1 stereo 32, mono 17; MPEG2 stereo 17, mono 9
		# The real byte rate: walk the frames we have. Some encoders under-pad, so
		# a "56 kbps" file can really be 55.7 (15 s off an hour in); a mix of
		# bitrates means VBR, where only a table or the average will do.
		my ($p, $n, $bytes, %rates) = ($i, 0, 0);
		while ($p + 4 <= $len) {
			my ($c0, $c1, $c2) = unpack('C3', substr($b, $p, 3));
			last unless $c0 == 0xFF && ($c1 & 0xE0) == 0xE0 && (($c1 >> 3) & 3) == $ver;
			my $fbri = $c2 >> 4;
			last if $fbri == 0 || $fbri == 15 || (($c2 >> 2) & 3) != $sri;
			my $flen = int(($mpeg1 ? 144000 : 72000) * $BR[$mpeg1 ? 0 : 1][$fbri] / $o{srate}) + (($c2 >> 1) & 1);
			last if $p + $flen > $len;
			$rates{$fbri}++; $n++; $bytes += $flen; $p += $flen;
		}
		$o{walked} = $n;
		$o{vbr} = 1 if keys(%rates) > 2;           # the Xing/Info frame itself may differ
		$o{byte_rate} = $bytes / ($n * $o{spf} / $o{srate}) if $n >= 30 && !$o{vbr};

		my $x = $i + 4 + ($mpeg1 ? ($chan == 3 ? 17 : 32) : ($chan == 3 ? 9 : 17));
		my $tag = $x + 8 <= $len ? substr($b, $x, 4) : '';
		if ($tag eq 'Xing' || $tag eq 'Info') {
			my $flags = unpack('N', substr($b, $x + 4, 4));
			my $q = $x + 8;
			if (($flags & 1) && $q + 4 <= $len) { $o{frames} = unpack('N', substr($b, $q, 4)); $q += 4 }
			if (($flags & 2) && $q + 4 <= $len) { $o{bytes}  = unpack('N', substr($b, $q, 4)); $q += 4 }
			if ($tag eq 'Xing' && ($flags & 4) && $q + 100 <= $len) { $o{toc} = [ unpack('C100', substr($b, $q, 100)) ] }
		}
		return \%o;
	}
	return;
}

# $cb->($info) with what's needed to seek in the MP3 at $url, or $cb->() if
# it isn't an MP3 we can read.
sub probe {
	my ($class, $url, $cb) = @_;
	_range($url, 0, HEAD_BYTES, sub {
		my ($head, $total) = @_;
		return $cb->() unless defined $head;
		my $tag = _id3_size($head);
		if ($tag + FRAME_BYTES <= length $head) {
			return $cb->(_first_frame(substr($head, $tag), $tag, $total));
		}
		return $cb->() if $tag > MAX_TAG;
		_range($url, $tag, FRAME_BYTES, sub {
			my ($frame, $total2) = @_;
			return $cb->() unless defined $frame;
			$cb->(_first_frame($frame, $tag, $total || $total2));
		});
	});
}

# Byte offset of second $s, as the phone players seek.
sub byte_for {
	my ($class, $i, $s, $dur) = @_;     # $dur: the episode's published length, for VBR files without a table
	return $i->{audio_start} if $s <= 0;
	my $audio = $i->{bytes} || (($i->{total} || 0) > $i->{audio_start} ? $i->{total} - $i->{audio_start} : 0);
	if ($i->{toc} && $i->{frames} && $audio) {
		# VBR: interpolate the 100-point Xing table
		my $dur = $i->{frames} * $i->{spf} / $i->{srate};
		my $pct = $s * 100 / $dur;
		return $i->{audio_start} + $audio if $pct >= 100;
		my $a  = int $pct;
		my $fa = $i->{toc}[$a];
		my $fb = $a < 99 ? $i->{toc}[$a + 1] : 256;
		return $i->{audio_start} + int(($fa + ($fb - $fa) * ($pct - $a)) / 256 * $audio);
	}
	if ($i->{frames} && $audio && !$i->{toc}) {
		# a Xing/Info header without a table: its frame count gives the true average
		return $i->{audio_start} + int($s / ($i->{frames} * $i->{spf} / $i->{srate}) * $audio);
	}
	if ($i->{vbr} && $dur && $audio) {
		# VBR without a table: the file's average over the episode's length
		return $i->{audio_start} + int($s / $dur * $audio);
	}
	# CBR: the measured byte rate (padding included), else the frame bitrate
	return $i->{audio_start} + int($s * ($i->{byte_rate} || $i->{kbps} * 1000 / 8));
}

1;
