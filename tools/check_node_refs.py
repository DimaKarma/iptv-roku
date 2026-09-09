#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Resolve every string-referenced name in the SceneGraph components.

BrightScript reaches a lot of things by STRING, and a typo in one of those is invisible
to the compiler: `brighterscript` is green on all of them (measured). They fail at
runtime instead, with `func_name_resolver failed resolving '...'` or a `Dot operator on
invalid` on the next line -- and on this project a runtime failure means a screen that
goes dead in front of the owner, or an observer that silently never fires.

Three classes are checked, all of them measured as NOT caught by the compiler:

  findNode("id")            -> the id must exist in that component's own XML
  observeField(f, "handler")-> the handler must be a sub/function reachable from that
                               component: its own .brs, or one of its <script> includes
  onChange="handler" in XML -> same rule

Rule 1 of the project memory is the reason the include list matters: functions in
source/*.brs are NOT global to components, so "reachable" means literally listed in that
component's <script> tags.

Exit code is non-zero on any unresolved name. A positive control asserts the scan
actually read something -- an empty scan and a clean scan must never look alike.
"""
import glob
import io
import os
import re
import sys
import xml.etree.ElementTree as ET

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FIND_NODE = re.compile(r'findNode\(\s*"([^"]+)"\s*\)')
# NB: `observeFieldScoped?` would match "observeFieldScope" plus an optional "d" and
# therefore never match plain observeField -- the class this checker exists for. That
# typo made it report 0 references and "clean" at the same time.
OBSERVE = re.compile(r'observeField(?:Scoped)?\(\s*"[^"]*"\s*,\s*"([^"]+)"\s*\)')
DEFINITION = re.compile(r'^\s*(?:sub|function)\s+([A-Za-z_]\w*)', re.M | re.I)


def read(path):
    return io.open(path, encoding="utf-8", errors="replace").read()


def component_files():
    """(xml_path, brs_path) for every component that has both."""
    out = []
    for pattern in ("components/*.xml", "components/tasks/*.xml"):
        for xml_path in glob.glob(os.path.join(ROOT, pattern)):
            brs_path = xml_path[:-4] + ".brs"
            if os.path.exists(brs_path):
                out.append((xml_path, brs_path))
    return sorted(out)


def script_includes(tree, xml_path):
    """Absolute paths of every <script uri="pkg:/..."> the component pulls in."""
    paths = []
    for el in tree.iter("script"):
        uri = el.get("uri") or ""
        if uri.startswith("pkg:/"):
            paths.append(os.path.join(ROOT, uri[len("pkg:/"):].replace("/", os.sep)))
    return [p for p in paths if os.path.exists(p)]


def main():
    pairs = component_files()
    print("components with both .xml and .brs: %d" % len(pairs))
    if len(pairs) < 8:
        print("POSITIVE CONTROL FAILED: too few components found; the scan read nothing")
        return 2

    problems = 0
    checked = {"findNode": 0, "observeField": 0, "onChange": 0}

    for xml_path, brs_path in pairs:
        rel = os.path.relpath(brs_path, ROOT)
        tree = ET.parse(xml_path)
        ids = {el.get("id") for el in tree.iter() if el.get("id")}

        # Every function the component can actually call by name.
        names = set()
        for src in [brs_path] + script_includes(tree, xml_path):
            names |= {m.lower() for m in DEFINITION.findall(read(src))}

        brs = read(brs_path)

        for m in FIND_NODE.finditer(brs):
            checked["findNode"] += 1
            if m.group(1) not in ids:
                line = brs[:m.start()].count("\n") + 1
                print("  %s:%d  findNode(\"%s\") - no such id in %s"
                      % (rel, line, m.group(1), os.path.basename(xml_path)))
                problems += 1

        for m in OBSERVE.finditer(brs):
            checked["observeField"] += 1
            if m.group(1).lower() not in names:
                line = brs[:m.start()].count("\n") + 1
                print("  %s:%d  observeField handler \"%s\" is not defined or included"
                      % (rel, line, m.group(1)))
                problems += 1

        for el in tree.iter():
            handler = el.get("onChange")
            if handler:
                checked["onChange"] += 1
                if handler.lower() not in names:
                    print("  %s  onChange=\"%s\" is not defined or included"
                          % (os.path.relpath(xml_path, ROOT), handler))
                    problems += 1

    print("references checked: findNode %d, observeField %d, onChange %d"
          % (checked["findNode"], checked["observeField"], checked["onChange"]))
    # Per-class floors, not a total: one large class can otherwise mask another that
    # matched nothing at all, which is how the observeField regex typo above hid.
    floors = {"findNode": 60, "observeField": 20, "onChange": 4}
    for name, floor in floors.items():
        if checked[name] < floor:
            print("POSITIVE CONTROL FAILED: only %d %s references scanned, expected >= %d"
                  % (checked[name], name, floor))
            return 2

    print("RESULT:", "clean" if problems == 0 else "PROBLEMS: %d" % problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
