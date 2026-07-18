param(
    [string]$RokuIp = "192.168.5.49",
    [string]$RokuPass = "REDACTED"
)

Set-Location $PSScriptRoot
$ZipName = "build.zip"

Write-Host "Removing old zip..."
if (Test-Path $ZipName) { Remove-Item $ZipName -Force }

Write-Host "Zipping files (tar, forward slashes)..."
tar.exe -a -c -f $ZipName manifest config.json source components images

Write-Host "Deploying to $RokuIp..."
$response = curl.exe -sS --digest -u "rokudev:$RokuPass" -F "mysubmit=Install" -F "archive=@$ZipName" "http://$RokuIp/plugin_install"

if ($response -match "Install Failure") {
    Write-Host "Deploy failed: Install Failure"
    exit 1
} else {
    Write-Host "Deploy successful!"
}
