#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Check how M3uParser.brs splits an #EXTINF line into attributes and channel name.

There is no BrightScript runtime on this machine, so the parsing rule is verified by
porting it and running the port over the real playlists. The port below mirrors the
BrightScript deliberately: it walks by INDEX with a start offset (Instr) and never
slices, because on the target device Left is byte-based while Mid is not, and mixing
them splits Cyrillic characters. A green run here is evidence about the rule, not
proof about the BrightScript -- only a sideload is that.

Usage:
    python tools/check_m3u_names.py                # unit cases only, no network
    python tools/check_m3u_names.py --playlists    # also fetch and check real data

--playlists reads config.json for the provider URL. That URL contains a subscription
token, so it is never printed; only channel names are.
"""
import argparse
import io
import json
import os
import sys
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTRA_PLAYLIST = "https://iptv-org.github.io/iptv/categories/sports.m3u"


def first_unquoted_comma(line):
    """Port of FirstUnquotedComma in source/M3uParser.brs (0-based, -1 if none)."""
    in_quote = False
    scan_at = 0
    while True:
        q = line.find('"', scan_at)
        c = line.find(",", scan_at)
        if c < 0:
            return -1
        if q < 0 or c < q:
            if not in_quote:
                return c
            scan_at = c + 1
        else:
            in_quote = not in_quote
            scan_at = q + 1


def channel_name(line):
    i = first_unquoted_comma(line)
    return line[i + 1:].strip() if i >= 0 else None


# Each case encodes a rule that the real playlists cannot currently exercise.
CASES = [
    ('#EXTINF:0 tvg-rec="7",Первый канал FHD', "Первый канал FHD"),
    ('#EXTINF:-1 ua="Mozilla (KHTML, like Gecko) X" group-title="Sports",5Sport (1080p)',
     "5Sport (1080p)"),
    # A name may itself contain a comma: everything after the separator is the name.
    ('#EXTINF:-1 tvg-id="x",Sport, Live', "Sport, Live"),
    ('#EXTINF:-1 ua="a,b",News, Weather', "News, Weather"),
    ('#EXTINF:-1,Plain', "Plain"),
    ('#EXTINF:-1 no-comma-at-all', None),
    ('#EXTINF:-1 a="unclosed,Name', None),
]


def run_unit():
    bad = 0
    for line, want in CASES:
        got = channel_name(line)
        if got != want:
            bad += 1
            print("FAIL %-58s -> %r (want %r)" % (line[:56], got, want))
    print("unit cases: %d, failures: %d" % (len(CASES), bad))
    return bad


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "check-m3u/1.0"})
    return urllib.request.urlopen(req, timeout=120).read().decode("utf-8", "replace")


def run_playlists():
    cfg_path = os.path.join(HERE, "config.json")
    if not os.path.exists(cfg_path):
        print("config.json not found - skipping the provider playlist")
        sources = [("extra", EXTRA_PLAYLIST)]
    else:
        cfg = json.load(io.open(cfg_path, encoding="utf-8"))
        sources = [("provider", cfg["playlistUrl"]), ("extra", EXTRA_PLAYLIST)]

    bad = 0
    for label, url in sources:
        lines = [l.strip() for l in fetch(url).splitlines()
                 if l.strip().startswith("#EXTINF:")]
        if not lines:
            print("%s: NO #EXTINF lines - the check would be blind" % label)
            bad += 1
            continue
        names = [channel_name(l) for l in lines]
        # A name that still contains a quote is an attribute fragment, not a name.
        suspicious = [n for n in names if n and '"' in n]
        print("%-9s channels=%4d  names containing a quote: %d"
              % (label, len(lines), len(suspicious)))
        for n in suspicious[:3]:
            print("    %s" % n[:80])
        bad += len(suspicious)
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--playlists", action="store_true",
                    help="also fetch the real playlists and check every name")
    args = ap.parse_args()

    problems = run_unit()
    if args.playlists:
        problems += run_playlists()
    print("RESULT:", "clean" if problems == 0 else "PROBLEMS: %d" % problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
