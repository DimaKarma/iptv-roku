# epg — compact EPG for the Roku IPTV player

EPG (electronic program guide) generator for the home IPTV app on a Hisense Roku TV.
It lives in this monorepo alongside the app; the generated data is published to the
separate `epg-data` branch so `main` stays free of automated data commits.

## Why
The provider playlist has no `url-tvg` or `tvg-id`, and a full XMLTV feed (tens of MB
gzipped, hundreds of MB unpacked) is something a Roku TV can neither unzip nor parse.
So the conversion runs in GitHub Actions and the TV is served a compact `epg.json`.

## How it works
1. `generate_epg.py` streams the public XMLTV feed `http://epg.it999.ru/epg.xml.gz`.
2. It matches channels from `channels.txt` (playlist names only, no tokens/subscription)
   against XMLTV channels by normalized name (~99% match).
3. It cuts a `now-2h .. now+18h` window and writes `epg.json`, keyed by the EXACT
   channel name from the playlist.
4. The workflow `.github/workflows/epg.yml` runs the generator on a schedule (every 2
   hours) and publishes a fresh `epg.json` to the `epg-data` branch.

## Use in the app
Set the EPG URL in the IPTV player settings (or `config.json` `epgUrl`):
```
https://raw.githubusercontent.com/DimaKarma/iptv-roku/epg-data/epg.json
```
The app fetches the small JSON and shows "now/next" by channel name.

## epg.json format
```json
{
  "generated": 1721140000,
  "count": 1045,
  "epg": {
    "Channel Name FHD": [ {"s": 1721140000, "e": 1721143600, "t": "Programme title"} ]
  }
}
```
`s`/`e` are Unix (UTC) start/stop times of a programme, `t` is the title.

## Privacy
Only public data lives here: channel names and the generated EPG. The subscription token
and the playlist URL are NOT stored.

## Manual run
**Actions → Generate EPG → Run workflow**, or locally: `python generate_epg.py`
(standard library only; downloads ~46 MB from epg.it999.ru).

## EPG source
`epg.it999.ru` — a public XMLTV feed for Russian-language channels. To change the source,
edit `XMLTV_URL` in `generate_epg.py`.
