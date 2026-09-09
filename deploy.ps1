param(
    [string]$RokuIp = "192.168.5.49",
    [string]$RokuPass = $env:ROKU_PASS,
    # Only for the bootstrap case: the build on the TV predates the [STORE] console
    # dump, so there is nothing to capture. Write the Favorites list down by hand
    # first -- this switch disables the only safety net there is.
    [switch]$SkipStoreBackup
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RokuPass)) {
    Write-Error "Set the Roku dev password via -RokuPass <pass> or the ROKU_PASS environment variable."
    exit 1
}

Set-Location $PSScriptRoot
. "$PSScriptRoot\tools\RokuPackage.ps1"
. "$PSScriptRoot\tools\StoreBackup.ps1"
$ZipName = "build.zip"

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

# Back up favorites/recents BEFORE touching the TV. A failed install can take the
# registry with it, and there is no other copy of that data anywhere.
if ($SkipStoreBackup) {
    Write-Host "Skipping the favorites/recents backup (-SkipStoreBackup)."
} else {
    Write-Host "Backing up favorites and recents from $RokuIp..."
    try {
        Save-RokuStore -RokuIp $RokuIp -OutDir (Join-Path $PSScriptRoot 'backups') | Out-Null
    } catch {
        Write-Host "Store backup failed: $($_.Exception.Message)"
        Write-Error ("Refusing to install without a favorites backup. Write the Favorites " +
                     "list down from the TV, then re-run with -SkipStoreBackup.")
        exit 1
    }
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
