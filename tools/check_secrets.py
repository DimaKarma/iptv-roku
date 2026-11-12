# Pre-push secret scan. Scans the TREE of every commit that would be published,
# not the cumulative diff: a secret added in one commit and redacted in a later
# one shows up as nothing in the net diff while still sitting in the objects
# that a push uploads.
#
# Every needle is a plain substring, deliberately: a regex engine that rejects
# a pattern can print a fatal and still exit 0, and the loop then reports
# "clean" for every input. No pattern here can be rejected.
#
# Scope notes: `--branches` does not cover tags (name them, or use `--all`), and every
# GIT_* variable is removed from the subprocess environment so a hook's inherited
# GIT_DIR / GIT_INDEX_FILE cannot steer the scan at another repository.
#
# Pre-push HOOK USAGE (documentation; this script is not itself a hook). A hook
# must pass the RAW local sha taken from stdin, NOT a peeled form such as
# `<sha>^{}` or `<sha>^{commit}`: the point is that a ref may name a tag object,
# a tree or a blob, and peeling it would hide exactly the thing being pushed.
# Call it once per stdin line, as
#     <local sha> --not --remotes=<remote>
# and skip lines whose local sha is all zeros (a branch deletion publishes
# nothing). Allowed rev arguments are validated below; anything else exits 3.
import json, os, re, subprocess, sys, io
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# ---- arguments ---------------------------------------------------------------
# --repo <path>         git repository whose objects are scanned
#                       (default: the repository root containing this script)
# --secrets-dir <path>  directory holding config.json and tools/secret-needles.txt
#                       (default: the same root)
# Everything else is passed to `git rev-list` untouched, as separate arguments
# (e.g. `--all`, or `<sha> --not --remotes`). Parsed by hand, not argparse, so
# that `--not` and `--remotes` can never be swallowed as unknown options.
SCRIPT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = SCRIPT_ROOT
SECRETS_DIR = None
REV_ARGS = []
_argv = sys.argv[1:]
_i = 0
while _i < len(_argv):
    _a = _argv[_i]
    if _a in ("--repo", "--secrets-dir"):
        if _i + 1 >= len(_argv):
            print("MISSING VALUE for " + _a)
            sys.exit(3)
        if _a == "--repo":
            REPO = _argv[_i + 1]
        else:
            SECRETS_DIR = _argv[_i + 1]
        _i += 2
        continue
    REV_ARGS.append(_a)
    _i += 1
if SECRETS_DIR is None:
    SECRETS_DIR = SCRIPT_ROOT
if not REV_ARGS:
    REV_ARGS = ["origin/main..HEAD"]
REV_LABEL = " ".join(REV_ARGS)

# Rev-argument ALLOWLIST (M1). An option that narrows the walk (-n0,
# --max-count, --since, a `-- path` limiter, --end-of-options, a negated
# ref-set such as `--not --all`) can make a non-empty push look EMPTY, and an
# empty range is reported as "nothing to scan, exit 0". So only these are
# accepted:
#   * plain revisions, including A..B, A...B, ^A, A^!
#   * `--not` (toggles negation)
#   * POSITIVE ref-set options: --all --tags --branches --remotes --glob=<x>
#     (--tags/--branches/--remotes may also carry =<x>)
#   * AFTER --not only plain revisions and --remotes / --remotes=<x>
# Everything else exits 3 with the argument named.
REFSET_OPTS = ("--all", "--tags", "--branches", "--remotes", "--glob")
SCAN_ALL = False       # positive --all
REFSET = False         # any positive ref-set option
REFSET_ARGS = []       # the positive ref-set options as given
POSITIVE_REVS = []     # positive rev arguments (non-options)
_neg = False
for _a in REV_ARGS:
    if _a == "--not":
        _neg = not _neg
        continue
    if _a.startswith("-"):
        _base, _eq, _val = _a.partition("=")
        if _base not in REFSET_OPTS:
            print("REFUSING: rev argument not allowed: " + _a +
                  " (only plain revisions, --not and positive ref-set options)")
            sys.exit(3)
        if _base == "--all" and _eq:
            print("REFUSING: rev argument not allowed: " + _a)
            sys.exit(3)
        if _base == "--glob" and not _val:
            print("REFUSING: --glob needs a value (--glob=<pattern>): " + _a)
            sys.exit(3)
        if _neg:
            if _base != "--remotes":
                print("REFUSING: negated ref-set option not allowed: --not " + _a +
                      " (it can make a non-empty push look empty)")
                sys.exit(3)
            continue
        REFSET = True
        REFSET_ARGS.append(_a)
        if _a == "--all":
            SCAN_ALL = True
        continue
    if not _a:
        print("REFUSING: empty rev argument")
        sys.exit(3)
    if _neg or _a.startswith("^"):
        continue
    if "..." in _a:
        POSITIVE_REVS.extend([x for x in _a.split("...", 1) if x])
    elif ".." in _a:
        _r = _a.split("..", 1)[1]
        if _r:
            POSITIVE_REVS.append(_r)
    elif _a.endswith("^!"):
        POSITIVE_REVS.append(_a[:-2])
    else:
        POSITIVE_REVS.append(_a)

# R2: drop EVERY inherited GIT_* variable (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE,
# GIT_OBJECT_DIRECTORY, GIT_CONFIG_*, ...) so the subprocesses cannot be steered
# to another repository or another object store, then pin replace-refs off.
GIT_ENV = {k: v for k, v in os.environ.items() if not k.upper().startswith("GIT_")}
GIT_ENV["GIT_NO_REPLACE_OBJECTS"] = "1"

def git_try(*args):
    r = subprocess.run(["git", "-C", REPO] + list(args),
                       capture_output=True, env=GIT_ENV)
    return r.returncode, r.stdout, r.stderr

def git(*args):
    rc, out, err = git_try(*args)
    if rc != 0:
        print("GIT FAILED:", args, err.decode("utf-8", "replace"))
        sys.exit(3)
    return out

# ---- repository integrity: history that is not what it seems -----------------
# Replace refs, grafts and a shallow clone all let `git rev-list` report a
# history different from the real objects. Refuse rather than scan a view.
if git("for-each-ref", "refs/replace").strip():
    print("REFUSING: repository has refs/replace/* refs - the scanned history "
          "could differ from the objects a push uploads")
    sys.exit(3)
_gp = git("rev-parse", "--git-path", "info/grafts").decode().strip()
_gp = _gp if os.path.isabs(_gp) else os.path.join(REPO, _gp)
if os.path.isfile(_gp) and os.path.getsize(_gp) > 0:
    print("REFUSING: repository has a non-empty info/grafts file")
    sys.exit(3)
if git("rev-parse", "--is-shallow-repository").decode().strip() == "true":
    print("REFUSING: repository is shallow (--is-shallow-repository is true)")
    sys.exit(3)

# ---- build the needle list -------------------------------------------------
needles = {}

cfg_path = SECRETS_DIR + "/config.json"
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
# A path segment becomes a needle only if it looks like a token: no dot AND
# (length >= 16, OR length >= 8 with at least one digit). Every qualifying
# segment is its own needle ("url segment 1", "url segment 2", ... numbered in
# order among QUALIFYING segments). Why: a plain alphabetic word of 8-15
# characters (a generic path component) is not a secret, and as a needle it
# produced false hits in ordinary source files and commit messages; the real
# token is a long alphanumeric string. If NO segment qualifies the scanner
# cannot protect the token, so it fails closed (exit 3).
_segs = [s_ for s_ in url.split("//", 1)[-1].split("/")[1:] if s_ != ""]
_segn = 0
for seg in _segs:
    if "." not in seg and (len(seg) >= 16 or
                           (len(seg) >= 8 and any(c.isdigit() for c in seg))):
        _segn += 1
        needles["url segment " + str(_segn)] = seg
print("url path segments: " + str(len(_segs)) + ", qualified as token: " +
      str(_segn) + ", skipped as generic: " + str(len(_segs) - _segn))
if _segn == 0:
    print("playlistUrl yields no token-like path segment - the scan cannot "
          "protect the token. Aborting.")
    sys.exit(3)

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
NEEDLE_FILE = SECRETS_DIR + "/tools/secret-needles.txt"
try:
    with open(NEEDLE_FILE, encoding="utf-8-sig") as fh:
        extra = 0
        _names_seen = set()
        for _lineno, raw_line in enumerate(fh, 1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                # Line NUMBER only: the line itself may be a secret.
                print("BAD LINE in secret-needles.txt: line " + str(_lineno))
                sys.exit(3)
            name, value = line.split("=", 1)
            name, value = name.strip(), value.strip()
            # A duplicate NAME would overwrite a needle and the scan would look
            # for fewer things than the file lists. Name only, never the value.
            if name in _names_seen or name in needles:
                print("DUPLICATE needle name in secret-needles.txt: " + name +
                      " (line " + str(_lineno) + ") - refusing to proceed with fewer needles")
                sys.exit(3)
            _names_seen.add(name)
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
# A TV screenshot can show the subscription token as pixels, which no text needle can
# see. Any added file with one of these suffixes (case-insensitive) is refused outright.
FORBIDDEN_SUFFIXES = (".jpg", ".jpeg")

# (path, needle name) -> why it is acceptable. These are REPORTED, not silenced:
# a scan that hides things teaches you to trust a number you cannot audit.
ALLOWED = {
    ("deploy.ps1", "tv lan ip"):
        "RFC1918 default for -RokuIp. Not routable from outside the house, and "
        "useless to anyone not already on the LAN, where ECP on 8060 is "
        "unauthenticated anyway. Published since July.",
    ("deploy.ps1", "tv lan prefix"):
        "Same published default as above, matched by the /24 prefix needle that "
        "tools/secret-needles.txt carries since 2026-11-12. Only history can hold it: "
        "the current deploy.ps1 has no default address. Needed so the prefix needle "
        "does not block the old published address.",
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
    "epg.json":
        "The generated guide on the epg-data branch: provider programme titles and "
        "channel names, written by the Action. Same class as epg/channels.txt. "
        "It only appears in a --all scan, never in a push range, because that "
        "branch is not an ancestor of main. Until 2026-09-10 it was ~464 blocking "
        "hits, one per bot commit; the branch now holds a single rootless commit, "
        "so it is one. A tool that cries wolf 464 times is a tool nobody reads.",
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

# 4. The metadata matcher must fire on a synthetic author line carrying a needle
#    and must stay silent on a line that carries none.
def match_needles(text, nd):
    t = text.lower()
    return [name for name, n in nd.items() if n.lower() in t]

def needle_ci(name, n):
    """Blob/path rule: case-insensitive for needles containing '@' (emails) and
    for the provider HOST (DNS names are case-insensitive), exact otherwise."""
    return "@" in n or name == "provider host"

def fold(t):
    # length-preserving lower-casing, so match offsets stay valid. str.lower() is
    # length-preserving for every character except U+0130, which expands; take the
    # fast path when the whole string came back the same length and fall back to the
    # per-character loop only otherwise.
    low = t.lower()
    if len(low) == len(t):
        return low
    return "".join(c.lower() if len(c.lower()) == 1 else c for c in t)

def needle_in(name, n, text):
    return fold(n) in fold(text) if needle_ci(name, n) else n in text

def mask_path(path):
    """Never print a needle value back: replace the UNION of all needle match
    spans (one pass, case rule per needle) so overlapping needles cannot leak a
    partial value."""
    spans = []
    fp = fold(path)
    for name, n in needles.items():
        hay, nd = (fp, fold(n)) if needle_ci(name, n) else (path, n)
        i = hay.find(nd)
        while i != -1:
            spans.append((i, i + len(nd)))
            i = hay.find(nd, i + 1)
    spans.sort()
    out, pos = [], 0
    for a, b in spans:
        if b <= pos:
            continue
        out.append(path[pos:max(a, pos)])
        if a >= pos:
            out.append("<needle>")
        pos = b
    out.append(path[pos:])
    return "".join(out)

def esc(t):
    """N5: a file name must not be able to forge a report line."""
    o = []
    for c in t:
        k = ord(c)
        if (k < 0x20 or 0x7f <= k <= 0x9f or k in (0x2028, 0x2029) or
                0x202a <= k <= 0x202e or 0x2066 <= k <= 0x2069):
            # C0/C1 controls, line separators and bidi controls: a file name must not be
            # able to forge a report line or reorder the text a reader sees.
            o.append("\\x%02x" % k if k <= 0xff else "\\u%04x" % k)
        else:
            o.append(c)
    return "".join(o)

def disp(path):
    """Every printed path: masked, then escaped."""
    return esc(mask_path(path))

# N6: needles as UTF-16LE/BE byte strings (BOM-less; a BOM does not matter to a
# substring search). Case variants for the case-insensitive needles.
U16 = []
for _nm, _nv in needles.items():
    _forms = {_nv}
    if needle_ci(_nm, _nv):
        _forms |= {_nv.lower(), _nv.upper()}
    for _f in sorted(_forms):
        for _enc in ("utf-16-le", "utf-16-be"):
            U16.append((_nm, _f.encode(_enc)))
if not U16:
    print("POSITIVE CONTROL FAILED: UTF-16 needle table is empty")
    sys.exit(3)
_hn = needles["provider host"]
if not needle_in("provider host", _hn, _hn.upper()):
    print("POSITIVE CONTROL FAILED: provider host is not matched case-insensitively")
    sys.exit(3)

def meta_matches(text):
    return match_needles(text, needles)

_probe_name = sorted(needles)[0]
if _probe_name not in meta_matches("author x <" + needles[_probe_name] + ">"):
    print("POSITIVE CONTROL FAILED: metadata matcher is blind")
    sys.exit(3)
if meta_matches("author x <x@users.noreply.github.com>"):
    print("NEGATIVE CONTROL FAILED: metadata matcher fires on a clean line")
    sys.exit(3)
if _probe_name not in meta_matches("author x <" + needles[_probe_name].upper() + ">"):
    print("POSITIVE CONTROL FAILED: metadata matcher is case-sensitive")
    sys.exit(3)
print("metadata matcher control: OK")

# ---- what gets published ---------------------------------------------------
# `rev-list --objects` with the SAME arguments lists everything a push would
# upload: commits, trees, blobs and tag objects, including blobs and trees that
# a ref or tag names DIRECTLY and no commit reaches.
rng = REV_LABEL

def fail(msg):
    print(msg)
    sys.exit(3)

OBJ_INFO = {}    # sha -> (type, size), from cat-file --batch-check

def batch_types(shas):
    """N2: exactly one answer per input, none `missing`, else exit 3."""
    shas = list(shas)
    if not shas:
        return {}
    r = subprocess.run(["git", "-C", REPO, "cat-file",
                        "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
                       input=("\n".join(shas) + "\n").encode(),
                       capture_output=True, env=GIT_ENV)
    if r.returncode != 0:
        fail("GIT FAILED: cat-file --batch-check " + r.stderr.decode("utf-8", "replace"))
    lines = r.stdout.decode("utf-8", "replace").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) != len(shas):
        fail("GIT FAILED: cat-file --batch-check answered " + str(len(lines)) +
             " line(s) for " + str(len(shas)) + " object(s) - refusing to report clean")
    types = {}
    for sha, ln in zip(shas, lines):
        parts = ln.split(" ")
        if len(parts) != 3 or parts[0] != sha or parts[1] == "missing" or not parts[2].isdigit():
            fail("GIT FAILED: missing or untypable object " + sha[:12])
        types[sha] = parts[1]
        OBJ_INFO[sha] = (parts[1], int(parts[2]))
    return types

def prefetch(shas):
    todo = [x for x in dict.fromkeys(shas) if x not in OBJ_INFO]
    if todo:
        batch_types(todo)

obj_names = {}   # sha -> name ("" when unnamed), listing order kept
# R1: the "--" terminator means no argument can be read as a path limiter; a file
# name given where a revision belongs is then an error (exit 3), not a filter.
for ln in git("-c", "core.quotePath=false", "rev-list", "--objects",
              *(REV_ARGS + ["--"])).decode("utf-8", "replace").split("\n"):
    if not ln:
        continue
    _sha, _, _nm = ln.partition(" ")
    if _sha not in obj_names or (not obj_names[_sha] and _nm):
        obj_names[_sha] = _nm
obj_types = batch_types(list(obj_names))
# (rev-list prints "<sha> <name>"; split on LF only, so CR / U+2028 / \\x1c in a
# path cannot break a line)
commits = [x for x in obj_names if obj_types[x] == "commit"]

# Tag objects, and blobs/trees named directly by a ref or a positive rev.
tag_ids = []
direct = []
def _note(sha, otype):
    if otype == "tag" and sha not in tag_ids:
        tag_ids.append(sha)
    elif otype in ("blob", "tree") and sha not in direct:
        direct.append(sha)
NAMED = []   # object ids the positive ref-set options name (unpeeled)
if REFSET:
    # R4: ask git what THESE options name; tag objects come back unpeeled.
    NAMED = [x for x in git("rev-parse", *REFSET_ARGS).decode().split("\n") if x]
    _nt = batch_types(list(dict.fromkeys(NAMED)))
    for sha in NAMED:
        _note(sha, _nt[sha])
# N8: tag objects the push lists itself
for _x, _t in obj_types.items():
    if _t == "tag":
        _note(_x, "tag")
for _rev in POSITIVE_REVS:
    rc, out, _e = git_try("cat-file", "-t", _rev)
    if rc == 0:
        _note(git("rev-parse", _rev).decode().strip(), out.decode().strip())

if REFSET and not NAMED and not obj_names:
    # N9/R4: a ref-set option that names nothing (and no revision lists any
    # object) is an empty or wrong repository, not a clean one.
    print(" ".join(REFSET_ARGS) + " found ZERO objects in " + REPO +
          " - refusing to report clean")
    sys.exit(3)
if not obj_names and not tag_ids and not direct:
    # The one legitimate empty case: an explicit range with nothing in it
    # (nothing to push) and no tag object named. Defined as clean so a
    # pre-push hook does not fail.
    print("NOTHING TO SCAN: '" + rng + "' lists no objects (nothing to push)")
    sys.exit(0)

# Peel every tag object to its final NON-tag target. A blob or tree target is
# scanned; a commit target is covered by the commit pass if it is in range.
extra_targets = list(direct)
for tid in tag_ids:
    rc, out, err = git_try("rev-parse", tid + "^{}")
    if rc != 0:
        fail("GIT FAILED: cannot peel tag object " + tid[:7])
    tgt = out.decode().strip()
    rc, out, err = git_try("cat-file", "-t", tgt)
    if rc != 0:
        fail("GIT FAILED: cannot type tag target " + tgt[:7])
    if out.decode().strip() in ("blob", "tree") and tgt not in extra_targets:
        extra_targets.append(tgt)

_cnt = {}
for _t in obj_types.values():
    _cnt[_t] = _cnt.get(_t, 0) + 1
print("objects to publish: " + str(len(obj_names)) + " (" +
      ", ".join(k + " " + str(_cnt[k]) for k in sorted(_cnt)) + ")  (" + rng + ")")
print("commits to publish: " + str(len(commits)))
if not commits:
    print("no commits in range, but " + str(len(obj_names)) + " object(s) / " +
          str(len(tag_ids)) + " tag object(s) named: scanning those")

hits = []
cyr = []
total_blobs = 0
seen_blobs = set()
seen_paths = set()
blobs_via_commits = 0

def check_forbidden(cid, path):
    for fp in FORBIDDEN_PATHS:
        if path == fp:
            hits.append((cid, path, "FORBIDDEN PATH: " + fp))
    if path.lower().endswith(FORBIDDEN_SUFFIXES):
        hits.append((cid, path, "forbidden image suffix [class forbidden]"))

def check_path(cid, path):
    """M2: a file NAME can carry a needle too. Same matcher as blobs. Hits keep
    the REAL path (allowlist lookups); it is masked only when printed."""
    if path in seen_paths:
        return
    seen_paths.add(path)
    for name, n in needles.items():
        if needle_in(name, n, path):
            hits.append((cid, path, name + " [class path]"))

def scan_blob(cid, path, sha):
    global total_blobs
    if sha in seen_blobs:
        return
    seen_blobs.add(sha)
    total_blobs += 1
    prefetch([sha])
    raw = git("cat-file", "blob", sha)
    # N3: the bytes read must be exactly as long as batch-check said.
    if OBJ_INFO[sha][0] != "blob" or len(raw) != OBJ_INFO[sha][1]:
        fail("SIZE MISMATCH: blob " + sha[:12] + " read " + str(len(raw)) +
             " byte(s), batch-check said " + str(OBJ_INFO[sha][1]) +
             " - refusing to report clean")
    # N6: UTF-16 forms, on the raw bytes of EVERY blob (BOM or not).
    u16 = set()
    for name, nb in U16:
        if nb in raw:
            u16.add(name)
    for name in sorted(u16):
        hits.append((cid, path, name + " (utf-16)"))
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        # Binary. Search the bytes for the ASCII needles rather than
        # skipping it: a skipped file and a clean file must never read
        # the same.
        raw_l = raw.lower()
        for name, n in needles.items():
            if needle_ci(name, n):
                found = n.lower().encode("utf-8") in raw_l
            else:
                found = n.encode("utf-8") in raw
            if found:
                hits.append((cid, path, name + " (in binary)"))
        return
    for name, n in needles.items():
        if needle_in(name, n, text):
            hits.append((cid, path, name))
    if has_cyrillic(text):
        cyr.append((cid, path))

def tree_entries(tree):
    out = git("-c", "core.quotePath=false", "ls-tree", "-r", "-z", tree)
    for ent in out.split(b"\0"):
        if not ent:
            continue
        meta, path = ent.decode("utf-8", "replace").split("\t", 1)
        mode, otype, sha = meta.split()
        yield otype, sha, path

for c in commits:
    paths_here = 0
    _ents = list(tree_entries(c))
    prefetch([e[1] for e in _ents if e[0] == "blob"])
    for otype, sha, path in _ents:
        paths_here += 1
        if otype != "blob":
            continue    # gitlink (submodule): no object to read
        check_forbidden(c[:7], path)
        check_path(c[:7], path)
        scan_blob(c[:7], path, sha)
    print("  " + c[:7] + ": " + str(paths_here) + " paths in tree")
blobs_via_commits = total_blobs

# Everything else the push uploads: names of listed objects (trees included),
# blobs no commit tree reached, and the targets of tags/refs.
for sha, nm in obj_names.items():
    if nm:
        check_path(sha[:7], nm)
    if obj_types[sha] == "blob" and sha not in seen_blobs:
        if nm:
            check_forbidden(sha[:7], nm)
        scan_blob(sha[:7], nm or "(unnamed object)", sha)
for tgt in extra_targets:
    ttype = batch_types([tgt])[tgt]
    if ttype == "blob":
        nm = obj_names.get(tgt, "")
        if nm:
            check_path(tgt[:7], nm)
        scan_blob(tgt[:7], nm or "(unnamed object)", tgt)
    else:
        for otype, sha, path in tree_entries(tgt):
            if otype != "blob":
                continue
            check_forbidden(tgt[:7], path)
            check_path(tgt[:7], path)
            scan_blob(tgt[:7], path, sha)
print("blobs read via commit trees: " + str(blobs_via_commits) +
      "; additional blobs via rev-list --objects / tag and ref targets: " +
      str(total_blobs - blobs_via_commits))

# 5. Coverage floor: this repo has far more than 30 files. A scan that read
#    almost nothing must not be able to report clean.
print("distinct blobs read: " + str(total_blobs))
if commits and total_blobs < 30:
    print("COVERAGE TOO LOW - refusing to report clean")
    sys.exit(3)

# ---- metadata pass -----------------------------------------------------------
# Author email, committer email and the full message of every commit in the set;
# with --all also tagger email and message of every annotated tag. Plain
# substring match against the same needles. Hits are keyed (field, needle name).
# Starts empty: an entry needs a needle that provably matches it.
ALLOWED_META = {
}

meta_hits = []   # (short id, field, needle name)

def classify_hits(raw, prefixes):
    """Match the WHOLE raw object text; report each hit by the header line it
    sits on (prefixes: {"author ": "author", ...}) or message-or-header."""
    out = []
    for name in match_needles(raw, needles):
        fields = set()
        head, sep, body = raw.partition("\n\n")
        for hl in head.split("\n"):
            if name in match_needles(hl, needles):
                for pre, fld in prefixes.items():
                    if hl.startswith(pre):
                        fields.add(fld)
                        break
                else:
                    fields.add("message-or-header")
        if name in match_needles(body, needles):
            fields.add("message-or-header")
        if not fields:
            fields.add("message-or-header")
        for f in sorted(fields):
            out.append((f, name))
    return out

def has_header(raw, prefix):
    head = raw.partition("\n\n")[0]
    return any(l.startswith(prefix) for l in head.split("\n"))

def author_email(raw):
    for _l in raw.partition("\n\n")[0].split("\n"):
        if _l.startswith("author "):
            _lt, _gt = _l.rfind("<"), _l.rfind(">")
            if _lt != -1 and _gt > _lt + 1:
                return _l[_lt + 1:_gt]
            return ""
    return ""

meta_commits = 0
first_raw = None
for c in commits:
    raw = git("cat-file", "commit", c).decode("utf-8", "replace")
    if not raw.strip() or not has_header(raw, "author ") or not has_header(raw, "committer "):
        print("METADATA COVERAGE FAILED: raw commit text of " + c[:7] +
              " is empty or lacks an author/committer line - refusing to report clean")
        sys.exit(3)
    if first_raw is None and author_email(raw):
        first_raw = raw
    meta_commits += 1
    for field, name in classify_hits(raw, {"author ": "author", "committer ": "committer"}):
        meta_hits.append((c[:7], field, name))

# Real-data positive control: the matcher must find the first scanned commit's
# own author email inside that commit's raw git output.
# (N10: the first scanned commit WITH a non-empty author email is used; if no
# commit has one, the control has nothing real to test and the scan refuses.)
if commits and first_raw is None:
    print("POSITIVE CONTROL FAILED: no scanned commit has an author email to "
          "run the real-data control on - refusing to report clean")
    sys.exit(3)
if first_raw is not None:
    _m = author_email(first_raw)
    if not _m or match_needles(first_raw, {"probe": _m}) != ["probe"]:
        print("POSITIVE CONTROL FAILED: matcher cannot find the first commit's "
              "author email in its raw git output")
        sys.exit(3)
    # Case folding on REAL git output: an UPPER-CASED copy of the same email
    # must still be found, or the control above proves nothing about case. (If
    # the email is already upper case, as in a commit written with an upper-case
    # address, the lower-cased copy is used instead: the folding is the same.)
    _probe = _m.upper() if _m.upper() != _m else _m.lower()
    if _probe == _m or match_needles(first_raw, {"probe": _probe}) != ["probe"]:
        print("POSITIVE CONTROL FAILED: matcher cannot find a case-changed copy of "
              "the first commit's author email in its raw git output (case folding "
              "broken, or the email has no letters to fold)")
        sys.exit(3)

meta_tags = 0
_seen_tag_objs = set()
for tid in tag_ids:
    cur = tid
    depth = 0
    while cur and cur not in _seen_tag_objs and depth < 50:
        _seen_tag_objs.add(cur)
        depth += 1
        raw = git("cat-file", "tag", cur).decode("utf-8", "replace")
        if not raw.strip():
            print("METADATA COVERAGE FAILED: empty tag object " + cur[:7])
            sys.exit(3)
        meta_tags += 1
        for field, name in classify_hits(raw, {"tagger ": "tagger"}):
            meta_hits.append((cur[:7], field, name))
        head = raw.partition("\n\n")[0]
        _t = _o = ""
        for hl in head.split("\n"):
            if hl.startswith("type "):
                _t = hl[5:].strip()
            elif hl.startswith("object "):
                _o = hl[7:].strip()
        cur = _o if _t == "tag" else ""

print("metadata examined: " + str(meta_commits) + " commits, " + str(meta_tags) + " tag objects")
if meta_commits != len(commits):
    print("METADATA COVERAGE TOO LOW - refusing to report clean")
    sys.exit(3)

print("")
meta_block = [h for h in meta_hits if (h[1], h[2]) not in ALLOWED_META]
meta_expl = [h for h in meta_hits if (h[1], h[2]) in ALLOWED_META]
if meta_block:
    print("METADATA HITS - DO NOT PUSH: " + str(len(meta_block)) +
          "  (distinct commits: " + str(len(set(h[0] for h in meta_block if h[0] in set(x[:7] for x in commits)))) +
          ", distinct tag objects: " + str(len(set(h[0] for h in meta_block if h[0] in set(x[:7] for x in _seen_tag_objs)))) + ")")
    for cid, field, name in meta_block:
        print("  metadata  " + cid + "  " + field + "  <- " + name)
else:
    print("METADATA: clean (author, committer, messages, tags carry no needle)")
for key in sorted(set((f, n) for _, f, n in meta_expl)):
    cnt = sum(1 for _, f, n in meta_expl if (f, n) == key)
    print("  known, allowed metadata: " + key[0] + " <- " + key[1] + " (" + str(cnt) + ")")
    print("      " + ALLOWED_META[key])
print("")
if not commits:
    print("(no commits in range: only directly reached objects were examined)")
blocking = [h for h in hits if (h[1], h[2]) not in ALLOWED]
explained = [h for h in hits if (h[1], h[2]) in ALLOWED]

if blocking:
    print("SECRET HITS - DO NOT PUSH: " + str(len(blocking)))
    for c, p, name in blocking:
        print("  " + c + "  " + disp(p) + "  <- " + name)
else:
    print("SECRETS: clean (token, playlist URL and provider host in zero blobs)")

seen_expl = set()
for c, p, name in explained:
    if (p, name) in seen_expl:
        continue
    seen_expl.add((p, name))
    n = sum(1 for _, pp, nn in explained if (pp, nn) == (p, name))
    where = " (in " + str(n) + " commits)" if n > 1 else ""
    print("  known, allowed: " + disp(p) + " <- " + name + where)
    print("      " + ALLOWED[(p, name)])

cyr_block = [x for x in cyr if x[1] not in ALLOWED_CYRILLIC]
if cyr_block:
    print("CYRILLIC - DO NOT PUSH: " + str(len(cyr_block)) + " file(s)")
    for c, p in cyr_block:
        print("  " + c + "  " + disp(p))
else:
    print("CYRILLIC: clean (only provider data, each entry justified below)")
for p in sorted(set(p for _, p in cyr)):
    if p in ALLOWED_CYRILLIC:
        n = sum(1 for _, pp in cyr if pp == p)
        where = " (in " + str(n) + " commits)" if n > 1 else ""
        print("  known, allowed: " + disp(p) + where)
        print("      " + ALLOWED_CYRILLIC[p])

# A stale allowlist is a silent hole: the file moved, the entry stopped
# matching, and nothing said so.
if SCAN_ALL:
    matched_paths = set(p for _, p, _ in hits)
    for (p, name) in ALLOWED:
        if p not in matched_paths:
            print("STALE ALLOWLIST ENTRY: " + p + " / " + name + " matched nothing")
    for key in ALLOWED_META:
        if key not in set((f, n) for _, f, n in meta_hits):
            print("STALE METADATA ALLOWLIST ENTRY: " + key[0] + " / " + key[1] + " matched nothing")
    seen_cyr = set(p for _, p in cyr)
    for p in ALLOWED_CYRILLIC:
        if p not in seen_cyr:
            print("STALE CYRILLIC ALLOWLIST ENTRY: " + p + " matched nothing")
else:
    print("(stale-allowlist check skipped: it is only meaningful over --all, "
          "since a push range legitimately contains few of these paths)")

sys.exit(1 if (blocking or cyr_block or meta_block) else 0)
