param(
    [string]$RokuIp = "192.168.5.49",
    [string]$RokuPass = $env:ROKU_PASS,
    # Only for the bootstrap case: the build on the TV predates the [STORE] console
    # dump, so there is nothing to capture. Write the Favorites list down by hand
    # first -- this switch disables the only safety net there is.
    [switch]$SkipStoreBackup,
    # Escape hatch for the compile gate. Named so it shows up in shell history: using it
    # means installing code that has not been syntax-checked, and a failed install is
    # what wiped the registry twice.
    [switch]$SkipCompileCheck
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RokuPass)) {
    Write-Error "Set the Roku dev password via -RokuPass <pass> or the ROKU_PASS environment variable."
    exit 1
}

Set-Location $PSScriptRoot
. "$PSScriptRoot\tools\RokuPackage.ps1"
. "$PSScriptRoot\tools\StoreBackup.ps1"
. "$PSScriptRoot\tools\Check-BrightScript.ps1"
$ZipName = "build.zip"

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
        Update-RestoreSeed -StorePath $storePath -SeedPath (Join-Path $PSScriptRoot 'source\restore.json') | Out-Null
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
tar.exe -a -c -f $ZipName manifest config.json source components images
if ($LASTEXITCODE -ne 0) {
    Write-Error "Package creation failed. The Roku was not contacted."
    exit 1
}

try {
    Test-RokuPackage -Path $ZipName | Out-Null
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

Write-Host "Deploying to $RokuIp..."
$response = curl.exe -sS --digest -u "rokudev:$RokuPass" -F "mysubmit=Install" -F "archive=@$ZipName" "http://$RokuIp/plugin_install"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Deploy failed: Roku could not be reached or rejected the upload."
    exit 1
}

if ($response -match "Install Failure") {
    Write-Host "Deploy failed: Install Failure"
    exit 1
} elseif ($response -match "Install Success") {
    Write-Host "Deploy successful!"
} else {
    Write-Error "Deploy failed: Roku returned an unrecognized response."
    exit 1
}
