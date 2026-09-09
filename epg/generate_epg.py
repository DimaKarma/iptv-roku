#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Compact EPG (epg.json) generator for the Roku IPTV player.

- Streams a public XMLTV feed (epg.it999.ru).
- Matches channels from channels.txt (playlist names, no token) against XMLTV
  channels by normalized name (no tvg-id).
- Cuts a now-2h .. now+18h programme window and writes epg.json keyed by the
  EXACT channel names from channels.txt (the Roku app needs no normalization —
  a plain epg[name] lookup).

epg.json format:
{
  "generated": <utc epoch>,
  "count": <number of channels with EPG>,
  "epg": { "<channel name>": [ {"s": startEpoch, "e": stopEpoch, "t": "Title"}, ... ], ... }
}
"""
import gzip
import io
import json
import os
import re
import sys
import time
import urllib.request
from datetime import datetime, timezone

from defusedxml.ElementTree import iterparse as safe_iterparse

XMLTV_URL = "http://epg.it999.ru/epg.xml.gz"
WINDOW_BEHIND = 2 * 3600     # 2 hours back
WINDOW_AHEAD = 18 * 3600     # 18 hours ahead
HTTP_TIMEOUT = 180
# The source is reachable only over plain HTTP (its HTTPS cert is expired and 301s to
# http://epg.one). EPG is integrity-not-confidentiality data and the XML below is parsed
# defensively (defusedxml + a decompressed-size cap), so plain HTTP is accepted here.
MAX_DECOMPRESSED = 2 * 1024 * 1024 * 1024   # 2 GiB cap — guards against a gzip bomb

# Refuse to publish a degenerate guide. If the upstream feed changes shape, or
# channels.txt drifts away from the XMLTV display-names, matching collapses and this
# script would otherwise write {"count":0,"epg":{}}, exit 0, and let the Action publish
# it over the last good file. A ratio rather than an absolute floor: channels.txt has
# already changed size once (1052 -> 844 in TASK-15) and an absolute number silently
# becomes wrong when it does. Observed healthy rate is ~508/844 (~60%), so 40% leaves
# room for normal upstream churn while still catching a matcher collapse.
# Override with EPG_MIN_CHANNELS=<n> to test the guard or to handle a smaller list.
MIN_MATCH_RATIO = 0.40


class _LimitedReader:
    """Wrap a stream and abort if it yields more than `limit` bytes (decompression-bomb guard)."""
    def __init__(self, fp, limit):
        self._fp = fp
        self._limit = limit
        self._seen = 0

    def read(self, size=-1):
        chunk = self._fp.read(size)
        self._seen += len(chunk)
        if self._seen > self._limit:
            raise ValueError("XMLTV stream exceeds the %d-byte decompression cap" % self._limit)
        return chunk

    def close(self):
        return self._fp.close()


_QUALITY_RE = re.compile(r'\b(fhd|uhd|hd|sd|4k)\b')
_SHIFT_RE = re.compile(r'\+\d+')
# Keep digits, Latin and Cyrillic (RU + UA і ї є ґ) letters — functional matching literal.
_KEEP_RE = re.compile(r'[^0-9a-zа-яёіїєґ]')


def norm(s):
    """Normalize a name for matching (used only inside the generator)."""
    if not s:
        return ""
    s = s.lower()
    s = _SHIFT_RE.sub('', s)
    s = _QUALITY_RE.sub('', s)
    s = _KEEP_RE.sub('', s)
    return s


# The Roku default font has no glyph for most symbols, and an unmapped character is
# drawn as an empty box. The upstream feed prefixes live broadcasts with U+22D7 "greater
# than with dot" and sprinkles U+25B6, emoji variation selectors and the odd Hangul
# syllable through titles, all of which reach the TV as boxes -- visible on Eurosport 1
# HD as a leading square before "Велоспорт".
#
# A whitelist, not a blacklist: keep only what is known to render (Latin, Cyrillic,
# digits, ASCII punctuation, and the handful of typographic characters confirmed on a
# real screenshot), and drop the rest. A rare glyph lost is better than a box shown, and
# a blacklist would need extending every time the feed invents a new marker.
_RENDERABLE_EXTRA = set(
    "—"   # em dash        - confirmed rendering in "CHANNELS - Favorites"
    "–"   # en dash
    "…"   # ellipsis       - confirmed in truncated card titles
    "«»"  # guillemets - confirmed in "«Хокум»"
    "★"   # star           - confirmed in the rail
    "°"   # degree
    "ёЁ"                    # yo
    "іїєґІЇЄҐ"  # Ukrainian i yi ye g
)
_TITLE_MAP = {
    "№": "No ",   # numero sign
    "’": "'", "‘": "'",
    "“": '"', "”": '"', "„": '"',
    " ": " ",     # nbsp
}


def clean_title(s):
    """Strip characters the Roku font cannot draw. Returns (text, was_changed)."""
    out = []
    for ch in s:
        if ch in _TITLE_MAP:
            out.append(_TITLE_MAP[ch])
            continue
        o = ord(ch)
        if o == 0x20 or (0x21 <= o <= 0x7E):        # ASCII printable
            out.append(ch)
        elif 0x0410 <= o <= 0x044F:                 # Cyrillic А-я
            out.append(ch)
        elif ch in _RENDERABLE_EXTRA:
            out.append(ch)
        # anything else is dropped
    cleaned = " ".join("".join(out).split())
    return cleaned, cleaned != s


def parse_xmltv_time(t):
    """'20260716120000 +0300' -> utc epoch (int)."""
    t = (t or "").strip()
    if len(t) < 14:
        return None
    dt = datetime.strptime(t[:14], "%Y%m%d%H%M%S")
    epoch = int(dt.replace(tzinfo=timezone.utc).timestamp())
    # apply the timezone offset if present ('+0300' / '-0500')
    rest = t[14:].strip()
    if len(rest) >= 5 and rest[0] in '+-':
        sign = 1 if rest[0] == '+' else -1
        off = int(rest[1:3]) * 3600 + int(rest[3:5]) * 60
        epoch -= sign * off
    return epoch


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ch_path = os.path.join(here, "channels.txt")
    out_path = os.path.join(here, "epg.json")

    names = [ln.strip() for ln in open(ch_path, encoding="utf-8") if ln.strip()]
    # normalized name -> exact playlist name (first match wins)
    norm_to_name = {}
    for nm in names:
        key = norm(nm)
        if key and key not in norm_to_name:
            norm_to_name[key] = nm

    now = int(time.time())
    lo, hi = now - WINDOW_BEHIND, now + WINDOW_AHEAD

    print("Downloading %s ..." % XMLTV_URL)
    req = urllib.request.Request(XMLTV_URL, headers={"User-Agent": "epg-gen/1.0"})
    resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT)
    gz = _LimitedReader(gzip.GzipFile(fileobj=resp), MAX_DECOMPRESSED)

    chan_to_name = {}   # xmltv channel id -> exact channel name
    name_has_cid = set()  # names that already picked one feed (so +2/+4 feeds don't merge)
    epg = {}
    n_prog = 0
    n_cleaned = 0

    ctx = safe_iterparse(gz, events=("end",))
    for ev, el in ctx:
        tag = el.tag
        if tag == "channel":
            cid = el.get("id")
            for dn in el.findall("display-name"):
                key = norm(dn.text or "")
                if key in norm_to_name:
                    nm = norm_to_name[key]
                    # keep only the FIRST feed per channel (first in XMLTV order)
                    if nm not in name_has_cid:
                        chan_to_name[cid] = nm
                        name_has_cid.add(nm)
                    break
            el.clear()
        elif tag == "programme":
            cid = el.get("channel")
            nm = chan_to_name.get(cid)
            if nm is not None:
                s = parse_xmltv_time(el.get("start"))
                e = parse_xmltv_time(el.get("stop"))
                if s is not None and e is not None and e >= lo and s <= hi:
                    title_el = el.find("title")
                    title = (title_el.text if title_el is not None else "") or ""
                    title, changed = clean_title(title)
                    if changed:
                        n_cleaned += 1
                    epg.setdefault(nm, []).append({"s": s, "e": e, "t": title})
                    n_prog += 1
            el.clear()

    for nm in epg:
        epg[nm].sort(key=lambda p: p["s"])

    # Check BEFORE writing, so a rejected run leaves no partial epg.json on disk for
    # the publish step to pick up. A non-zero exit aborts the workflow job before its
    # publish step, so the last good file on the epg-data branch survives untouched.
    override = os.environ.get("EPG_MIN_CHANNELS")
    floor = int(override) if override else int(MIN_MATCH_RATIO * len(names))
    if len(epg) < floor:
        sys.stderr.write(
            "REFUSING to write epg.json: matched %d channels, need at least %d "
            "(%d names in channels.txt, %d programmes in window).\n"
            % (len(epg), floor, len(names), n_prog))
        sys.stderr.write(
            "This usually means the upstream feed changed or channels.txt drifted. "
            "The previously published epg.json is left in place.\n")
        sys.exit(1)

    out = {"generated": now, "count": len(epg), "epg": epg}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))

    size = os.path.getsize(out_path)
    print("Matched channels with EPG: %d / %d" % (len(epg), len(names)))
    print("Programmes in window: %d" % n_prog)
    print("Titles cleaned of unrenderable characters: %d" % n_cleaned)
    print("epg.json size: %.2f MB" % (size / 1024.0 / 1024.0))


if __name__ == "__main__":
    main()
