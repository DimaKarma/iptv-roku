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
- **Player** — HLS video with an info overlay, channel zap (▲/▼), a side zapper panel
  (◀), **previous channel** on the Replay button, and an error dialog with retry / next /
  back. A stream that stalls is caught by a watchdog instead of spinning forever.
- **Resume** — the last channel watched for 10 seconds starts again at the next launch
  (Settings: `Resume last channel: On/Off`).
- **Search** — the app draws its own on-screen keyboard (Latin, Cyrillic and digits), with
  live results beside it. Matching is transliteration-aware: a query typed in either
  alphabet finds channels named in either.
- **Adult category** — channels of the provider's adult group are never added to Recent,
  never resumed at launch, never reached by the Replay button, and are skipped when
  flipping with ▲/▼ from an ordinary channel. They open only by an explicit choice.
- **Settings / Onboarding** — editable playlist & EPG URLs, reload, cache reset, a Diagnostics
  screen, and an About screen with the version and build date.
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
- **Node.js**, for the BrightScript compile gate `deploy.ps1` runs before it builds
  anything. Restore it with `npm ci` (the compiler version is pinned in `package.json`).
- **Python**, for the node-reference check that resolves `findNode` / `observeField` /
  `onChange` names the compiler cannot see.

## Configuration
Copy `config.example.json` to `config.json` and fill in your URLs:
```json
{
  "playlistUrl": "https://HOST/path/TOKEN/playlist.m3u8",
  "epgUrl": "https://raw.githubusercontent.com/DimaKarma/iptv-roku/epg-data/epg.json",
  "extraPlaylists": [
    { "url": "https://iptv-org.github.io/iptv/categories/sports.m3u", "category": "Sport2" }
  ]
}
```
`config.json` holds a subscription token in `playlistUrl`, so it is **gitignored** and never
committed. The playlist and EPG URLs can also be changed on the TV in Settings.

**Prefer `https`.** The token is a path segment, so over plain `http` it — and the whole
playlist, including every stream URL — crosses the network in the clear on every launch,
readable by anyone on the path. The app fetches `https` over verified TLS with no change
needed; whether your provider serves it is worth checking before settling for `http`.

## Install via the deploy script (Windows)
1. Enable Developer Mode on the Roku TV: `Home x3, Up x2, Right, Left, Right, Left, Right`.
2. Set a password and note the TV's IP address.
3. Tell the script which television to use, and the password -- **never put either in a
   file**. The address is mandatory: there is no default and no discovery.
   ```powershell
   $env:ROKU_PASS = "<your dev password>"
   $env:ROKU_IP = "<TV_IP>"        # or pass -RokuIp <TV_IP>
   .\deploy.ps1
   ```
   (`-RokuPass <password>` works too.) The script has no default password either and
   refuses to run without one, so the password stays out of the repository.
4. Create `tools/expected-device.txt` (gitignored) holding your TV's serial number, as
   `tools/expected-device.example.txt` describes. Before it touches the TV the script reads
   the device's serial from `http://<TV_IP>:8060/query/device-info` and stops if it differs
   or if the file is missing; neither serial is printed.
5. It compile-checks the sources, checks the device identity, backs up your favorites off
   the TV, builds the ZIP archive and uploads it (the password goes to `curl` on stdin,
   not on its command line).

## Install manually
1. Build a ZIP from the `manifest` and `config.json` files and the `source`, `components`,
   and `images` folders (`manifest` must sit at the archive root, not inside a folder).

   > **The archive must be a real ZIP with forward slashes.** On Windows, GNU `tar` (the
   > one in Git Bash) writes a *tar* file under a `.zip` name, and PowerShell's
   > `Compress-Archive` writes backslash paths — Roku rejects both, and a rejected install
   > can clear the channel's stored data. Use the bundled `C:\Windows\System32\tar.exe`,
   > then check that the first two bytes are `PK` and that `unzip -t` passes.
2. Open a browser on your PC and go to `http://<ROKU_IP>`.
3. Enter the username `rokudev` and your Developer Mode password.
4. Click **Upload**, select the ZIP, then click **Install**.

## Before you push
This repository is public, so a push is checked first. Install the hook once per clone:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-hooks.ps1
```
For every ref you push, the hook runs `tools/check_secrets.py` over exactly the objects the
push would upload (the whole tree of every commit, not just the diff, plus annotated tag
objects) and refuses the push on any non-zero exit. The scan looks for the subscription
token and playlist URL taken from your local `config.json`, for the strings listed in your
gitignored `tools/secret-needles.txt` (copy `tools/secret-needles.example.txt`), in file
contents, file names and commit and tag metadata; for forbidden files (`config.json`,
`source/restore.json`, `build.zip`, any `.jpg` or `.jpeg`, because a TV screenshot can show
the token); and for Cyrillic text outside the few files that legitimately carry provider
data. If it cannot run (no `config.json`, no needles file) it refuses rather than passing.
`tools\install-hooks.ps1 -Uninstall` disables the hook by renaming it.

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
