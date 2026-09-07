param(
    [string]$RokuIp = "192.168.5.49",
    [string]$RokuPass = $env:ROKU_PASS
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RokuPass)) {
    Write-Error "Set the Roku dev password via -RokuPass <pass> or the ROKU_PASS environment variable."
    exit 1
}

Set-Location $PSScriptRoot
. "$PSScriptRoot\tools\RokuPackage.ps1"
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

Write-Host "Deploying to $RokuIp..."
$response = curl.exe -sS --digest -u "rokudev:$RokuPass" -F "mysubmit=Install" -F "archive=@$ZipName" "http://$RokuIp/plugin_install"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Deploy failed: Roku could not be reached or rejected the upload."
    exit 1
}

if ($response -match "Install Failure") {
    Write-Host "Deploy failed: Install Failure"
    exit 1
} else if ($response -match "Install Success") {
    Write-Host "Deploy successful!"
} else {
    Write-Error "Deploy failed: Roku returned an unrecognized response."
    exit 1
}
