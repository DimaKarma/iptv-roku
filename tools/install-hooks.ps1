# Install (or disable) the repository's pre-push secret scan.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-hooks.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-hooks.ps1 -Uninstall
#
# The hook is a POSIX sh script (Git for Windows runs it with its bundled sh). For every
# line git feeds it on stdin -- `<local ref> <local sha> <remote ref> <remote sha>` -- it
# skips an all-zero local sha (a deletion publishes nothing) and otherwise runs
#
#     python tools/check_secrets.py <local sha> --not --remotes=<remote name>
#
# from the repository root. ANY non-zero exit refuses the push, exit 3 (the scan could not
# run) included, and the refused ref is named. The raw local sha is passed, never a peeled
# form: a ref may name a tag object, and peeling it would hide the tagger and the message.
#
# The environment variable CHECK_SECRETS_DIR, when set, is forwarded to the scanner as
# --secrets-dir. It exists so tests can run the hook against FAKE secrets; unset (the
# normal case) the scanner uses the repository's own config.json and needles file. Whenever
# it is set the hook says so on stderr (never printing the value), so a push that was
# scanned against something other than the real secrets cannot look like a normal one.
# A local sha that is not exactly 40 hex characters (an all-zero deletion excepted) refuses
# the push.
#
# -Uninstall renames the hook to pre-push.disabled; nothing is deleted. A pre-push hook
# that this script did not write is never overwritten.
[CmdletBinding()]
param(
    [switch]$Uninstall,
    # Test seam: install into another working tree. Default is the repository this
    # script lives in.
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

# Default for -RepoRoot: the repository this script lives in. It is resolved HERE and not
# as a param() default because `(Split-Path -Parent $PSScriptRoot)` there failed under
# Windows PowerShell 5.1 with `-File` (empty $PSScriptRoot while the default is evaluated:
# "Cannot bind argument to parameter 'Path' because it is an empty string"). Try the
# script's own location by every route; never fall back to the current directory.
if (-not $RepoRoot) {
    $scriptPath = $null
    if ($PSScriptRoot) {
        $scriptPath = Join-Path $PSScriptRoot 'install-hooks.ps1'
    } elseif ($PSCommandPath) {
        $scriptPath = $PSCommandPath
    } elseif ($MyInvocation.MyCommand.Path) {
        $scriptPath = $MyInvocation.MyCommand.Path
    } elseif ($MyInvocation.MyCommand.Definition -and (Test-Path -LiteralPath $MyInvocation.MyCommand.Definition -PathType Leaf)) {
        $scriptPath = $MyInvocation.MyCommand.Definition
    }
    if ($scriptPath) {
        $toolsDir = Split-Path -Parent $scriptPath
        if ($toolsDir) { $candidate = Split-Path -Parent $toolsDir } else { $candidate = $null }
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $candidate '.git'))) {
            $RepoRoot = $candidate
        }
    }
    if (-not $RepoRoot) {
        throw "Cannot work out the repository root from the location of this script (expected <repo>\tools\install-hooks.ps1 inside a git working tree); pass -RepoRoot <path>."
    }
}
$marker = '# iptv-roku pre-push secret scan (installed by tools/install-hooks.ps1)'

$hookBody = @'
#!/bin/sh
# iptv-roku pre-push secret scan (installed by tools/install-hooks.ps1)
remote="$1"
root=$(git rev-parse --show-toplevel) || { echo "pre-push: cannot find the repository root"; exit 1; }
cd "$root" || { echo "pre-push: cannot enter $root"; exit 1; }

PY=""
for cand in python python3; do
    if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then
    echo "pre-push: REFUSING the push: python was not found, so the secret scan could not run."
    exit 1
fi

status=0
if [ -n "$CHECK_SECRETS_DIR" ]; then
    echo "WARNING: scanning with CHECK_SECRETS_DIR=<set> (test override)" >&2
fi
while read -r local_ref local_sha remote_ref remote_sha; do
    # An all-zero sha (any length) is a deletion: nothing is published.
    case "$local_sha" in
        *[!0]*) ;;
        *) continue ;;
    esac
    # Anything else must be exactly 40 hex characters; a malformed value would otherwise be
    # handed to the scanner as if it were a revision.
    bad_sha=0
    case "$local_sha" in
        *[!0123456789abcdefABCDEF]*) bad_sha=1 ;;
    esac
    [ "${#local_sha}" -eq 40 ] || bad_sha=1
    if [ "$bad_sha" -ne 0 ]; then
        echo "pre-push: REFUSING $local_ref -> $remote_ref (the local sha is not 40 hex characters)"
        status=1
        continue
    fi
    if [ -n "$CHECK_SECRETS_DIR" ]; then
        "$PY" tools/check_secrets.py --secrets-dir "$CHECK_SECRETS_DIR" "$local_sha" --not "--remotes=$remote"
    else
        "$PY" tools/check_secrets.py "$local_sha" --not "--remotes=$remote"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "pre-push: REFUSING $local_ref -> $remote_ref (secret scan exit $rc; 3 means the scan could not run)"
        status=1
    fi
done
exit $status
'@

# The repository's OWN hooks directory (<git dir>/hooks), deliberately not
# `git rev-parse --git-path hooks`: when core.hooksPath is set that answers with the
# shared directory, and writing there would clobber a hook that belongs to every repository.
$gitDir = (& git -C $RepoRoot rev-parse --git-dir)
if ($LASTEXITCODE -ne 0) { throw "Not a git repository: $RepoRoot" }
if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $RepoRoot $gitDir }
$gitHooks = Join-Path $gitDir 'hooks'

# core.hooksPath REPLACES <git dir>/hooks: git then runs the hook of that directory and
# never looks at this one. On the owner's machine it points at a shared shim directory
# whose pre-push shim hands over to <git dir>/hooks/pre-push, so this hook runs through the
# shim. Say so, because a hook that git never calls looks exactly like a hook that passed.
$hooksPath = (& git -C $RepoRoot config --get core.hooksPath)
if ($hooksPath) {
    Write-Host ("NOTE: core.hooksPath is set to '$hooksPath'. Git runs hooks from there, not from " +
                "$gitHooks, so this hook only runs if that directory's pre-push chains to " +
                "<git dir>/hooks/pre-push. Prove it once with a push of a throwaway tag that carries a " +
                "needle (it must be refused).")
}
$hookPath = Join-Path $gitHooks 'pre-push'
$disabledPath = Join-Path $gitHooks 'pre-push.disabled'

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $hookPath)) {
        Write-Host "No pre-push hook at $hookPath; nothing to disable."
        return
    }
    $existing = [System.IO.File]::ReadAllText($hookPath)
    if (-not $existing.Contains($marker)) {
        throw "The pre-push hook at $hookPath was not installed by this script; leaving it alone."
    }
    Move-Item -LiteralPath $hookPath -Destination $disabledPath -Force
    Write-Host "Disabled: $hookPath -> $disabledPath"
    return
}

if (Test-Path -LiteralPath $hookPath) {
    $existing = [System.IO.File]::ReadAllText($hookPath)
    if (-not $existing.Contains($marker)) {
        throw "A pre-push hook already exists at $hookPath and was not installed by this script; refusing to overwrite it."
    }
}
if (-not (Test-Path -LiteralPath $gitHooks)) { New-Item -ItemType Directory -Path $gitHooks -Force | Out-Null }

# LF endings, no BOM: sh chokes on a CR before the shebang's newline.
$text = ($hookBody -replace "`r`n", "`n") + "`n"
[System.IO.File]::WriteAllText($hookPath, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Installed: $hookPath"
