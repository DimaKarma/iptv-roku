# IPTV Player for Roku

A personal IPTV player for a Hisense Roku TV (Roku OS 15+), built with BrightScript
and SceneGraph. It loads an M3U playlist over HLS, groups channels by category, and
adds favorites, recents, search, an on-screen guide (EPG), and a channel zapper — all
driven by the remote. Installed by developer-mode sideload; not distributed through the
Roku Channel Store.

## Features
- **Playlist** — M3U over HLS (`index.m3u8`), parsed and cached on device; optional
  extra playlists merged in as their own category.
- **Channels** — two-pane rail + grid, category counts, logo/initials tiles, incompatible
  streams flagged.
- **Favorites & Recents** — stored by channel name (survives provider domain/token changes);
  toggle with `*` or long-press OK.
- **Player** — HLS video with an info overlay, channel zap (▲/▼), a side zapper panel, and
  an error dialog with retry / next / favorite / back.
- **Search / Settings / Onboarding** — on-screen keyboard search, editable playlist & EPG
  URLs, cache reset.
- **EPG** — compact "now/next" guide generated off-device (see [`epg/`](epg/)) and shown on
  cards and in the player overlay.

## Repository layout
```
manifest              Roku channel manifest (title, version, artwork)
config.example.json   Config template (copy to config.json; real config.json is gitignored)
deploy.ps1            Build + sideload helper (Windows / PowerShell)
source/               Shared BrightScript: Theme, ChannelStore, M3uParser, Epg
components/           SceneGraph components (screens, cards) + tasks/ (async config/playlist/epg)
images/               Splash screens and channel/app icons
epg/                  EPG generator (Python) — see epg/README.md
.github/workflows/    GitHub Action that regenerates the EPG on a schedule
```

## Requirements
- A Roku device with **Developer Mode** enabled.
- Windows with PowerShell for `deploy.ps1` (or any OS for the manual upload flow).

## Configuration
Copy `config.example.json` to `config.json` and fill in your URLs:
```json
{
  "playlistUrl": "http://HOST/path/TOKEN/playlist.m3u8",
  "epgUrl": "https://raw.githubusercontent.com/DimaKarma/iptv-roku/epg-data/epg.json",
  "extraPlaylists": [
    { "url": "https://iptv-org.github.io/iptv/categories/sports.m3u", "category": "Sport2" }
  ]
}
```
`config.json` holds a subscription token in `playlistUrl`, so it is **gitignored** and never
committed. The playlist and EPG URLs can also be changed on the TV in Settings.

## Install via the deploy script (Windows)
1. Enable Developer Mode on the Roku TV: `Home x3, Up x2, Right, Left, Right, Left, Right`.
2. Set a password and note the TV's IP address.
3. Open `deploy.ps1` and fill in your `RokuIp` and `RokuPass` at the top.
4. Run `deploy.ps1` in PowerShell. It builds the ZIP archive and uploads it to the TV.

## Install manually
1. Build a ZIP from the `manifest` and `config.json` files and the `source`, `components`,
   and `images` folders (`manifest` must sit at the archive root, not inside a folder).
2. Open a browser on your PC and go to `http://<ROKU_IP>`.
3. Enter the username `rokudev` and your Developer Mode password.
4. Click **Upload**, select the ZIP, then click **Install**.

## EPG
The provider playlist has no embedded guide, and a full XMLTV feed is too large for the TV,
so the EPG is generated off-device. [`epg/generate_epg.py`](epg/generate_epg.py) builds a
compact `epg.json`, and a scheduled GitHub Action publishes it to the **`epg-data`** branch;
the app fetches it from the `epgUrl` above. See [`epg/README.md`](epg/README.md) for details.

## Debugging
View BrightScript logs and errors over telnet:
```cmd
telnet <ROKU_IP> 8085
```
If `telnet` is not installed on Windows, enable it via "Turn Windows features on or off",
or use PuTTY (connection type: Raw, port 8085).

## License
[MIT](LICENSE) © 2026 DimaKarma. The license covers this repository's own source code.
Roku OS / SceneGraph APIs it calls remain Roku's, and playlist/EPG data come from their
respective third-party sources.
