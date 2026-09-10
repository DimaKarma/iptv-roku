# Pre-push secret scan. Scans the TREE of every commit that would be published,
# not the cumulative diff: a secret added in one commit and redacted in a later
# one shows up as nothing in the net diff while still sitting in the objects
# that a push uploads.
#
# Every needle is a plain substring, deliberately: a regex engine that rejects
# a pattern can print a fatal and still exit 0, and the loop then reports
# "clean" for every input. No pattern here can be rejected.
import json, subprocess, sys, io
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = "P:/hisense/iptv-roku"

def git(*args):
    r = subprocess.run(["git", "-C", REPO] + list(args),
                       capture_output=True)
    if r.returncode != 0:
        print("GIT FAILED:", args, r.stderr.decode("utf-8", "replace"))
        sys.exit(3)
    return r.stdout

# ---- build the needle list -------------------------------------------------
needles = {}

cfg_path = REPO + "/config.json"
try:
    cfg = json.load(open(cfg_path, encoding="utf-8-sig"))
except Exception as e:
    print("CANNOT READ config.json:", e)
    print("The scan needs it to know what the secret IS. Aborting.")
    sys.exit(3)

url = cfg.get("playlistUrl", "")
if not url:
    print("config.json has no playlistUrl - the scan has no needle. Aborting.")
    sys.exit(3)

# The whole URL, its host, and each path segment long enough to be a token.
needles["playlist url"] = url
host = url.split("//", 1)[-1].split("/", 1)[0]
needles["provider host"] = host
for seg in url.split("//", 1)[-1].split("/")[1:]:
    if len(seg) >= 8 and "." not in seg:
        needles["url segment"] = seg

# The extra playlists are deliberately NOT needles. They are public catalogue
# URLs (iptv-org), they carry no token, and they are quoted in the README and in
# config.example.json on purpose. Including them made the scan report seven hits
# that all had to be explained by hand before a push - which is how a scan trains
# its reader to skim it.

# The remaining needles are secrets in their own right - a password, personal
# addresses - so they CANNOT live in this file: it is committed to a public
# repository, and a scanner that publishes what it hunts for is worse than no
# scanner. This one caught exactly that on its own first commit, with the dev
# password written in as a literal, four months after that same password was
# purged from this repository's history.
#
# They live in tools/secret-needles.txt, which is gitignored. See
# tools/secret-needles.example.txt for the format. If the file is missing the
# scan ABORTS - it never quietly proceeds with fewer needles, because a scan
# that looked for less than it thinks it did reports a clean tree either way.
NEEDLE_FILE = REPO + "/tools/secret-needles.txt"
try:
    with open(NEEDLE_FILE, encoding="utf-8-sig") as fh:
        extra = 0
        for raw_line in fh:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                print("BAD LINE in secret-needles.txt: " + line[:40])
                sys.exit(3)
            name, value = line.split("=", 1)
            name, value = name.strip(), value.strip()
            if not value:
                continue
            needles[name] = value
            extra += 1
except FileNotFoundError:
    print("MISSING " + NEEDLE_FILE)
    print("Copy tools/secret-needles.example.txt to it and fill in the real")
    print("values. Without them this scan cannot look for the dev password or")
    print("for personal data, so it must not report a clean tree.")
    sys.exit(3)

if extra < 1:
    print("secret-needles.txt has no usable entries - refusing to report clean")
    sys.exit(3)

FORBIDDEN_PATHS = ["config.json", "source/restore.json", "build.zip"]

# (path, needle name) -> why it is acceptable. These are REPORTED, not silenced:
# a scan that hides things teaches you to trust a number you cannot audit.
ALLOWED = {
    ("deploy.ps1", "tv lan ip"):
        "RFC1918 default for -RokuIp. Not routable from outside the house, and "
        "useless to anyone not already on the LAN, where ECP on 8060 is "
        "unauthenticated anyway. Published since July.",
}

# Cyrillic that is provider DATA rather than Russian prose. Rule 16: the app
# translates what it draws, never what the playlist supplies.
ALLOWED_CYRILLIC = {
    "epg/channels.txt":
        "352 of 844 provider channel names. Pure data, and the EPG matcher keys "
        "on them byte-for-byte.",
    "epg/generate_epg.py":
        "Cyrillic character RANGES in the name-normalisation regex. The code "
        "cannot match Cyrillic channel names without naming those characters.",
    "source/ChannelStore.brs":
        "The literal the provider uses for its adult category. IsAdultGroup "
        "compares against it byte-for-byte; the comment beside it is English.",
    "tools/check_m3u_names.py":
        "A parser fixture built from a real channel name, which is the point of "
        "the fixture.",
}

def has_cyrillic(text):
    return any(0x0400 <= ord(c) <= 0x04FF for c in text)

# ---- positive controls -----------------------------------------------------
# 1. Every needle must be non-empty, or "not found" means nothing.
for name, n in needles.items():
    if not n or len(n) < 4:
        print("NEEDLE TOO SHORT:", name, "-> refusing to report clean")
        sys.exit(3)

# 2. The needles must be findable by this matcher. Prove it on the on-disk
#    config.json, which is gitignored and therefore must NOT be in any tree.
disk_cfg = open(cfg_path, encoding="utf-8-sig").read()
for name in ("playlist url", "provider host"):
    if needles[name] not in disk_cfg:
        print("POSITIVE CONTROL FAILED: could not find", name, "in config.json")
        sys.exit(3)

# 3. The Cyrillic detector must fire on a Cyrillic string.
if not has_cyrillic(chr(0x0412) + chr(0x0437)):
    print("POSITIVE CONTROL FAILED: Cyrillic detector is blind")
    sys.exit(3)
if has_cyrillic("plain ascii"):
    print("NEGATIVE CONTROL FAILED: Cyrillic detector fires on ASCII")
    sys.exit(3)

print("positive controls: OK (" + str(len(needles)) + " needles, all findable)")

# ---- what gets published ---------------------------------------------------
rng = sys.argv[1] if len(sys.argv) > 1 else "origin/main..HEAD"
commits = git("rev-list", rng).decode().split()
if not commits:
    print("NOTHING TO PUSH in range", rng)
    sys.exit(0)
print("commits to publish: " + str(len(commits)) + "  (" + rng + ")")

hits = []
cyr = []
total_blobs = 0
seen_blobs = set()

for c in commits:
    listing = git("ls-tree", "-r", c).decode("utf-8", "replace").splitlines()
    paths_here = 0
    for line in listing:
        meta, path = line.split("\t", 1)
        mode, otype, sha = meta.split()
        paths_here += 1
        # A forbidden path must not exist in the tree at all.
        for fp in FORBIDDEN_PATHS:
            if path == fp:
                hits.append((c[:7], path, "FORBIDDEN PATH: " + fp))
        if sha in seen_blobs:
            continue
        seen_blobs.add(sha)
        total_blobs += 1
        raw = git("cat-file", "blob", sha)
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            # Binary. Search the bytes for the ASCII needles rather than
            # skipping it: a skipped file and a clean file must never read
            # the same.
            for name, n in needles.items():
                if n.encode("utf-8") in raw:
                    hits.append((c[:7], path, name + " (in binary)"))
            continue
        for name, n in needles.items():
            if n in text:
                hits.append((c[:7], path, name))
        if has_cyrillic(text):
            cyr.append((c[:7], path))
    print("  " + c[:7] + ": " + str(paths_here) + " paths in tree")

# 4. Coverage floor: this repo has far more than 30 files. A scan that read
#    almost nothing must not be able to report clean.
print("distinct blobs read: " + str(total_blobs))
if total_blobs < 30:
    print("COVERAGE TOO LOW - refusing to report clean")
    sys.exit(3)

print("")
blocking = [h for h in hits if (h[1], h[2]) not in ALLOWED]
explained = [h for h in hits if (h[1], h[2]) in ALLOWED]

if blocking:
    print("SECRET HITS - DO NOT PUSH: " + str(len(blocking)))
    for c, p, name in blocking:
        print("  " + c + "  " + p + "  <- " + name)
else:
    print("SECRETS: clean (token, playlist URL and provider host in zero blobs)")

for c, p, name in explained:
    print("  known, allowed: " + p + " <- " + name)
    print("      " + ALLOWED[(p, name)])

cyr_block = [x for x in cyr if x[1] not in ALLOWED_CYRILLIC]
if cyr_block:
    print("CYRILLIC - DO NOT PUSH: " + str(len(cyr_block)) + " file(s)")
    for c, p in cyr_block:
        print("  " + c + "  " + p)
else:
    print("CYRILLIC: clean (only provider data, each entry justified below)")
for c, p in sorted(set((c, p) for c, p in cyr)):
    if p in ALLOWED_CYRILLIC:
        print("  known, allowed: " + p)
        print("      " + ALLOWED_CYRILLIC[p])

# A stale allowlist is a silent hole: the file moved, the entry stopped
# matching, and nothing said so.
matched_paths = set(p for _, p, _ in hits)
for (p, name) in ALLOWED:
    if p not in matched_paths:
        print("STALE ALLOWLIST ENTRY: " + p + " / " + name + " matched nothing")
seen_cyr = set(p for _, p in cyr)
for p in ALLOWED_CYRILLIC:
    if p not in seen_cyr:
        print("STALE CYRILLIC ALLOWLIST ENTRY: " + p + " matched nothing")

sys.exit(1 if (blocking or cyr_block) else 0)
