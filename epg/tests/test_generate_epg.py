# Unit tests for epg/generate_epg.py. Standard library unittest, no network and no real
# feed: the pipeline test feeds main() a tiny gzipped XMLTV document through a patched
# urlopen and a temporary channels.txt. This file is ASCII only; non-ASCII characters are
# written as escapes.
import gzip
import io
import json
import os
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import generate_epg as g  # noqa: E402


def reset_counters():
    for k in g.PARSE_FAILURES:
        g.PARSE_FAILURES[k] = 0
    for k in g.BOUND_DROPS:
        g.BOUND_DROPS[k] = 0


class ParseXmltvTime(unittest.TestCase):
    def setUp(self):
        reset_counters()

    def test_utc_and_offsets(self):
        base = g.parse_xmltv_time("20260716120000 +0000")
        self.assertEqual(g.parse_xmltv_time("20260716150000 +0300"), base)
        self.assertEqual(g.parse_xmltv_time("20260716070000 -0500"), base)
        # no offset at all is read as UTC
        self.assertEqual(g.parse_xmltv_time("20260716120000"), base)

    def test_absent_malformed_and_exception_are_counted_separately(self):
        self.assertIsNone(g.parse_xmltv_time(None))
        self.assertIsNone(g.parse_xmltv_time("   "))
        self.assertIsNone(g.parse_xmltv_time("2026071612"))
        self.assertIsNone(g.parse_xmltv_time("2026ab16120000 +0000"))
        self.assertEqual(g.PARSE_FAILURES, {"absent": 2, "malformed": 1, "exception": 1})


class CleanTitle(unittest.TestCase):
    def test_drops_unrenderable_and_keeps_cyrillic(self):
        cyr = "\u0412\u0435\u0441\u0442\u0438"          # four Cyrillic letters
        text, changed = g.clean_title("\u22d7 " + cyr + " \u25b6 live")
        self.assertEqual(text, cyr + " live")
        self.assertTrue(changed)

    def test_unchanged_text_reports_unchanged(self):
        text, changed = g.clean_title("News at 9")
        self.assertEqual(text, "News at 9")
        self.assertFalse(changed)

    def test_maps_typographic_characters_and_collapses_whitespace(self):
        text, changed = g.clean_title("\u2116 5   \u201cQuoted\u201d\u00a0x")
        self.assertEqual(text, 'No 5 "Quoted" x')
        self.assertTrue(changed)


class Bounds(unittest.TestCase):
    def setUp(self):
        reset_counters()

    def test_title_truncated_in_characters(self):
        self.assertEqual(g.truncate_title("a" * 120), "a" * 120)
        self.assertEqual(g.BOUND_DROPS["title_truncated"], 0)
        cyr = "\u0436" * 200                          # 200 characters, 400 bytes
        out = g.truncate_title(cyr)
        self.assertEqual(len(out), 120)
        self.assertEqual(g.BOUND_DROPS["title_truncated"], 1)

    def test_span_rules(self):
        self.assertTrue(g.span_ok(1000, 1001))
        self.assertTrue(g.span_ok(1000, 1000 + 86400))
        self.assertFalse(g.span_ok(1000, 1000 + 86401))
        self.assertFalse(g.span_ok(1000, 1000))
        self.assertFalse(g.span_ok(1000, 999))
        self.assertEqual(g.BOUND_DROPS["bad_span"], 3)

    def test_cap_keeps_the_earliest_eighty(self):
        epg = {"A": [{"s": i, "e": i + 10, "t": "x"} for i in reversed(range(85))],
               "B": [{"s": 1, "e": 2, "t": "y"}]}
        g.cap_programmes(epg)
        self.assertEqual([p["s"] for p in epg["A"]], list(range(80)))
        self.assertEqual(len(epg["B"]), 1)
        self.assertEqual(g.BOUND_DROPS["over_cap"], 5)


def xmltv_time(epoch):
    return time.strftime("%Y%m%d%H%M%S", time.gmtime(epoch)) + " +0000"


class Pipeline(unittest.TestCase):
    """main() end to end on a synthetic feed: proves the bounds are wired in, not only
    defined."""

    def setUp(self):
        reset_counters()

    def test_main_applies_every_bound(self):
        now = int(time.time())
        rows = []
        # 90 ordinary 30-minute programmes inside the window
        for i in range(90):
            s = now + i * 60
            rows.append((s, s + 1800, "Show %d" % i))
        rows.append((now + 100, now + 100, "zero length"))
        rows.append((now + 200, now + 150, "negative length"))
        rows.append((now, now + 25 * 3600, "too long"))
        rows.append((now + 300, now + 400, "T" * 300))
        parts = ['<?xml version="1.0" encoding="UTF-8"?><tv>',
                 '<channel id="c1"><display-name>Alpha</display-name></channel>']
        for s, e, t in rows:
            parts.append('<programme channel="c1" start="%s" stop="%s"><title>%s</title></programme>'
                         % (xmltv_time(s), xmltv_time(e), t))
        parts.append("</tv>")
        feed = gzip.compress("".join(parts).encode("utf-8"))

        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "channels.txt"), "w", encoding="utf-8") as fh:
                fh.write("Alpha\n")
            with mock.patch.object(g.urllib.request, "urlopen",
                                   return_value=io.BytesIO(feed)), \
                    mock.patch.dict(os.environ, {"EPG_MIN_CHANNELS": "1"}), \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                g.main(base_dir=tmp)
            with open(os.path.join(tmp, "epg.json"), encoding="utf-8") as fh:
                data = json.load(fh)

        progs = data["epg"]["Alpha"]
        self.assertEqual(data["count"], 1)
        self.assertEqual(len(progs), 80)
        self.assertEqual(progs, sorted(progs, key=lambda p: p["s"]))
        titles = [p["t"] for p in progs]
        self.assertNotIn("zero length", titles)
        self.assertNotIn("negative length", titles)
        self.assertNotIn("too long", titles)
        for p in progs:
            self.assertGreater(p["e"], p["s"])
            self.assertLessEqual(p["e"] - p["s"], 86400)
            self.assertLessEqual(len(p["t"]), 120)
        self.assertEqual(g.BOUND_DROPS["bad_span"], 3)
        self.assertEqual(g.BOUND_DROPS["over_cap"], 91 - 80)   # 90 + the long title row, minus 80
        self.assertEqual(g.BOUND_DROPS["title_truncated"], 1)
        report = out.getvalue()
        self.assertIn("bad span", report)
        self.assertIn("truncated", report)
        self.assertIn("per-channel cap", report)


if __name__ == "__main__":
    unittest.main()
