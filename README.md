# Static Radio for Lyrion Music Server (Squeezebox)

[Static](https://staticradio.app) is a radio made of independent podcasts:
every station plays one shared live timeline, so everyone tuned in hears the
same moment. This plugin puts Static's stations on your Squeezebox: the Radio,
Boom, Touch, Transporter and Receiver, plus any squeezelite or piCorePlayer
setup and other players that work with Lyrion Music Server.

**Static's website: [staticradio.app](https://staticradio.app)**, where you can
also listen in your browser and get the phone apps.

## What it does

- **Static Radio** appears under your apps, with every station and what's on
  it right now, plus how many people are listening.
- Picking a station joins it live: you land on the same moment as everyone
  else listening on the phones, the web and other radios, and it carries on
  from show to show by itself, like a radio.
- Each episode streams straight from the show's own host, so every listen
  counts for the podcaster as a normal download. Nothing goes through us.
- The now-playing screen shows the show, the episode, the cover art and the
  station's live listener count. Your player counts in it too, with an
  anonymous ID (no MAC address leaves your home).

## Install

Lyrion Music Server 8.0 or later.

1. Download `StaticRadio-<version>.zip` from
   [Releases](https://github.com/madewith-bestpractice/static-squeezebox/releases/latest)
   and unzip it.
2. Copy the `StaticRadio` folder into your server's plugins folder for
   manually installed plugins:
   - macOS: `~/Library/Application Support/Squeezebox/Plugins/`
   - Linux (Debian/Ubuntu package): `/usr/share/squeezeboxserver/Plugins/`
   - Docker: the `config` volume's `Plugins/` folder
   - Windows: `C:\Program Files\Lyrion\server\Plugins\`
3. Restart Lyrion Music Server. **Static Radio** appears under
   *My Apps* on your players and in the web interface.

## How it works

`staticradio://station/<id>` is a repeating stream. Whenever a player needs
something to play, the plugin works out the station's live episode from the
published schedule, with the same rules as the phone apps (the daily epoch,
each station's loop, a 1.5 s gap after each episode, bulletins capped at 30 s).
Lyrion scans the episode (redirects, format, bitrate) and starts it at the live
offset with a ranged request to the show's host. A timer moves on at each
episode's scheduled end, even if the file runs longer.

`t/live_test.pl` checks the plugin's timeline math against the published
schedule without a server.

## Feedback

Please open an issue if something doesn't play or lands in the wrong place;
include your Lyrion version, player model and the station.

## License

MIT, see [LICENSE](LICENSE). Made by [Best Practice](https://madewithbestpractice.com)
in Chicago. Squeezebox is a trademark of Logitech; this plugin isn't made or
endorsed by Logitech or the Lyrion project.
