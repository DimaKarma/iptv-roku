param(
    # The television's address. MANDATORY: there is no default and no discovery, so a
    # deploy can never land on whatever device happened to hold an old address. Supply it
    # as -RokuIp <address> or through the ROKU_IP environment variable. The device must
    # also identify itself (see tools/DeviceGuard.ps1) before anything is sent to it.
    [string]$RokuIp = $env:ROKU_IP,
    [string]$RokuPass = $env:ROKU_PASS,
    # Only for the bootstrap case: the build on the TV predates the [STORE] console
    # dump, so there is nothing to capture. Write the Favorites list down by hand
    # first -- this switch disables the only safety net there is.
    [switch]$SkipStoreBackup,
    # Escape hatch for the compile gate. Named so it shows up in shell history: using it
    # means installing code that has not been syntax-checked, and a failed install is
    # what wiped the registry twice.
    [switch]$SkipCompileCheck,
    # Escape hatch for the node-reference gate, for symmetry with the other two. Using it
    # means shipping without resolving the string-named references the compiler cannot see.
    [switch]$SkipNodeRefCheck
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RokuIp)) {
    Write-Error ("Name the TV: pass -RokuIp <address> or set the ROKU_IP environment variable. " +
                 "There is deliberately no default address and no discovery.")
    exit 1
}
# host or host:port, nothing else: this string ends up in URLs and socket calls.
# \A...\z, not ^...$: in .NET `$` also matches before a trailing newline, which would let
# "host`n" through into URLs and socket calls.
if ($RokuIp -notmatch '\A[A-Za-z0-9][A-Za-z0-9.\-]*(:[0-9]{1,5})?\z') {
    Write-Error "-RokuIp / ROKU_IP must be a host name or address, optionally followed by :port."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($RokuPass)) {
    Write-Error "Set the Roku dev password via -RokuPass <pass> or the ROKU_PASS environment variable."
    exit 1
}

Set-Location $PSScriptRoot
. "$PSScriptRoot\tools\RokuPackage.ps1"
. "$PSScriptRoot\tools\StoreBackup.ps1"
. "$PSScriptRoot\tools\Check-BrightScript.ps1"
. "$PSScriptRoot\tools\DeployRecord.ps1"
. "$PSScriptRoot\tools\DeviceGuard.ps1"
$ZipName = "build.zip"
$storePath = ""

# ---------------------------------------------------------------------------------
# 1. Compile-check first. It needs no network and does not touch the TV, so a syntax
#    error costs nothing -- and a syntax error is what failed the install that cleared
#    the registry on 2026-09-09. Earliest possible failure, before the TV is contacted
#    and before a package is built around code already known to be bad.
# ---------------------------------------------------------------------------------
if ($SkipCompileCheck) {
    Write-Host "Skipping the BrightScript compile check (-SkipCompileCheck)."
} else {
    Write-Host "Compile-checking BrightScript and SceneGraph sources..."
    try {
        if (-not (Test-BrightScriptCompiles -ProjectRoot $PSScriptRoot)) {
            Write-Error "Refusing to build: the sources do not compile. The TV was not contacted."
            exit 1
        }
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

# ---------------------------------------------------------------------------------
# 1b. Resolve every string-named node reference.
#
# The gate above is green on all three of these classes -- measured, not assumed --
# because they are strings rather than identifiers: a findNode id that does not exist,
# an observeField handler that is not defined, an onChange naming a sub the component
# cannot reach. Nothing rejects them at build time; they fail on the device instead, as
# a screen that goes dead in front of the owner or an observer that silently never
# fires. The checker resolves each one against what that component can actually call.
#
# Exit 2 is its positive-control failure and is NOT the same as exit 1: it means the
# scan covered less than it expected to, so a clean verdict from it would prove nothing.
# This project has been burned by a checker reporting "clean" having examined zero of
# its own class.
# ---------------------------------------------------------------------------------
if ($SkipNodeRefCheck) {
    Write-Host "Skipping the node-reference check (-SkipNodeRefCheck)."
} else {
    Write-Host "Resolving findNode / observeField / onChange references..."
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        Write-Error ("Refusing to build: python was not found, so the node-reference check " +
                     "could not run. A check that cannot run must not pass quietly -- " +
                     "install Python, or re-run with -SkipNodeRefCheck.")
        exit 1
    }
    & $python.Source (Join-Path $PSScriptRoot 'tools\check_node_refs.py')
    $refExit = $LASTEXITCODE
    if ($refExit -eq 2) {
        Write-Error ("Refusing to build: the node-reference check failed its own positive " +
                     "control. It scanned less than it expected to, so its verdict is void.")
        exit 1
    } elseif ($refExit -ne 0) {
        Write-Error "Refusing to build: unresolved node references. The TV was not contacted."
        exit 1
    }
}

# ---------------------------------------------------------------------------------
# 1c. Prove the device is the owner's television, BEFORE anything touches it. The store
# capture below presses Home and relaunches the channel on whatever answers at the
# address, so the identity check has to come first. The expected serial lives in the
# gitignored tools/expected-device.txt; with no such file the deploy stops here, and the
# message says how to create it. Neither serial is ever printed.
# ---------------------------------------------------------------------------------
try {
    Assert-ExpectedDevice -RokuIp $RokuIp -ExpectedPath (Join-Path $PSScriptRoot 'tools\expected-device.txt')
} catch {
    Write-Error ("Refusing to deploy: " + $_.Exception.Message)
    exit 1
}

# ---------------------------------------------------------------------------------
# 2. Capture the store, and refresh the in-package seed from that capture.
#
# This runs BEFORE the package is built, and the order is the point. An install can
# clear the whole userdata registry section -- it did on 2026-09-09, taking 31
# favourites -- and source/restore.json is what replays them afterwards. Built first
# and captured second, the shipped seed was always one deploy stale, so a wipe would
# restore the favourites the user had LAST time. Capture, refresh, then package.
# ---------------------------------------------------------------------------------
if ($SkipStoreBackup) {
    Write-Host "Skipping the favorites/recents backup (-SkipStoreBackup)."
} else {
    Write-Host "Backing up favorites and recents from $RokuIp..."
    try {
        $storePath = Save-RokuStore -RokuIp $RokuIp -OutDir (Join-Path $PSScriptRoot 'backups')
        $seedOutcome = Update-RestoreSeed -StorePath $storePath -SeedPath (Join-Path $PSScriptRoot 'source\restore.json') `
            -BackupDir (Join-Path $PSScriptRoot 'backups')
        if ($seedOutcome -eq 'kept') {
            Write-Host "  (the package will carry the PREVIOUS seed; see the notice above)"
        }
    } catch {
        Write-Host "Store backup failed: $($_.Exception.Message)"
        Write-Error ("Refusing to install without a favorites backup. Write the Favorites " +
                     "list down from the TV, then re-run with -SkipStoreBackup.")
        exit 1
    }
}

Write-Host "Removing old zip..."
if (Test-Path $ZipName) { Remove-Item $ZipName -Force }

Write-Host "Zipping files (tar, forward slashes)..."
# The Windows bsdtar by ABSOLUTE path. Resolving "tar" through PATH finds GNU tar first in
# Git Bash, which silently writes a TAR under a .zip name and gets "Invalid or corrupt zip
# archive" from the TV -- the failure that wiped the registry. bsdtar reports itself as such.
$tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $tarExe -PathType Leaf)) {
    Write-Error "Windows bsdtar not found at $tarExe. The Roku was not contacted."
    exit 1
}
if ((& $tarExe --version | Out-String) -notmatch 'bsdtar') {
    Write-Error "$tarExe is not bsdtar, so it would not produce a real zip. The Roku was not contacted."
    exit 1
}
& $tarExe -a -c -f $ZipName manifest config.json source components images
if ($LASTEXITCODE -ne 0) {
    Write-Error "Package creation failed. The Roku was not contacted."
    exit 1
}

try {
    Test-RokuPackage -Path $ZipName | Out-Null
    # And prove the registry-recovery seed is actually inside the package. It is
    # gitignored and reaches the build only because the archiver reads it off disk, so
    # nothing in the repository proves it shipped -- and it is the only thing that
    # replays the owner's favourites after an install clears the registry.
    #
    # Required only when the store gate actually ran. Under -SkipStoreBackup the seed may
    # legitimately be stale or absent, and refusing there would take away the operator's
    # last escape hatch at the exact moment they reached for it.
    #
    # With a capture of 1 or more favourites the packaged seed's favourites must equal the
    # capture's as a list, in order: a seed one deploy behind, reordered, or empty when the TV
    # holds favourites, is refused. With an EMPTY capture a kept previous seed passes, with a
    # printed notice.
    $seedArgs = @{ Path = $ZipName; Required = (-not $SkipStoreBackup) }
    if ($storePath) { $seedArgs.StorePath = $storePath }
    Test-RokuPackageSeed @seedArgs | Out-Null
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

Write-Host "Deploying to $RokuIp..."
$curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path -LiteralPath $curlExe -PathType Leaf)) {
    Write-Error "curl not found at $curlExe. Nothing was uploaded."
    exit 1
}
# The password reaches curl on STDIN as a config (-K -), never on the command line, where
# it would show in the process list. ConvertTo-CurlUserConfig escapes it and refuses a line
# break; the config itself is never printed.
try {
    $curlConfig = ConvertTo-CurlUserConfig -User 'rokudev' -Password $RokuPass
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
# Piping a string to a native command encodes it with $OutputEncoding. Pin it to UTF-8
# WITHOUT a BOM for the duration of the pipe (a BOM would land inside the first config
# line), and put the old value back afterwards whatever happens.
$savedEncoding = $OutputEncoding
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
    $response = $curlConfig | & $curlExe -sS --digest -K - -F "mysubmit=Install" -F "archive=@$ZipName" "http://$RokuIp/plugin_install"
} finally {
    $OutputEncoding = $savedEncoding
}
if ($LASTEXITCODE -ne 0) {
    Write-Error "Deploy failed: Roku could not be reached or rejected the upload."
    exit 1
}

# Show what the device actually said, before deciding what it means. The branches below
# collapse every outcome into three strings, so a real diagnosis -- "Script directory
# /source does not exist", "Identical to previous version" -- was being discarded at the
# one moment it is worth having. Extract the message line only: the response is a whole
# HTML page and printing it dumps several thousand characters.
# The device emits one of these per message, and it emits SEVERAL -- the byte count and
# the verdict are separate lines -- so print them all rather than the first.
$responseText = [string]$response
foreach ($m in [regex]::Matches($responseText, '<font color="red">(.*?)</font>')) {
    Write-Host "  TV: $($m.Groups[1].Value.Trim())"
}

# Get-RokuInstallVerdict checks "Identical to previous version" FIRST: that answer means the
# package on the TV did not change, which is not a deploy whatever else the page says.
$verdict = Get-RokuInstallVerdict -Response $responseText
if ($verdict -eq 'identical') {
    Write-Host "Deploy failed: the TV answered 'Identical to previous version', so the package did not change and nothing new was installed (see the TV lines above)."
    exit 1
} elseif ($verdict -eq 'failure') {
    Write-Host "Deploy failed: Install Failure"
    exit 1
} elseif ($verdict -eq 'success') {
    Write-Host "Deploy successful!"
    Save-DeployRecord -ZipPath $ZipName -ProjectRoot $PSScriptRoot `
        -Response $responseText -StorePath $storePath
} else {
    Write-Error "Deploy failed: Roku returned an unrecognized response."
    exit 1
}
