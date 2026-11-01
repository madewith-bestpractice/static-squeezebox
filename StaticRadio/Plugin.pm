package Plugins::StaticRadio::Plugin;

# Static Radio for Lyrion Music Server: the stations of staticradio.app as a
# radio menu. Each station plays the live moment of its shared timeline,
# streamed straight from each show's own host.

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::StaticRadio::Schedule;
use Plugins::StaticRadio::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.staticradio',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_STATICRADIO',
});

sub initPlugin {
	my $class = shift;

	Slim::Player::ProtocolHandlers->registerHandler(staticradio => 'Plugins::StaticRadio::ProtocolHandler');

	$class->SUPER::initPlugin(
		feed   => \&stations,
		tag    => 'staticradio',
		menu   => 'radios',
		is_app => 1,
		weight => 5,
	);

	Plugins::StaticRadio::Schedule->get(sub {});   # warm the cache
}

sub getDisplayName { 'PLUGIN_STATICRADIO' }

sub playerMenu { 'RADIO' }

sub icon { 'plugins/StaticRadio/html/images/icon.png' }

# The station list: one playable item per station, showing what's on now.
sub stations {
	my ($client, $cb, $args) = @_;

	Plugins::StaticRadio::Schedule->get(sub {
		my $schedule = shift;
		if (!$schedule) {
			$cb->({ items => [{ name => cstring($client, 'PLUGIN_STATICRADIO_NO_SCHEDULE'), type => 'text' }] });
			return;
		}
		my @items;
		for my $st (@{ $schedule->{stations} }) {
			my $live = Plugins::StaticRadio::Schedule->live($st);
			my $ep = $live ? $live->{ep} : {};
			push @items, {
				name     => $st->{tag},
				line1    => $st->{tag},
				line2    => join(': ', grep { $_ } $ep->{feedTitle}, $ep->{title}),
				type     => 'audio',
				url      => "staticradio://station/$st->{id}",
				image    => __PACKAGE__->icon,
				on_select => 'play',
			};
		}
		$cb->({ items => \@items });
	});
}

1;
