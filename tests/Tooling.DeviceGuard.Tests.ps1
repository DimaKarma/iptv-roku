# tools/DeviceGuard.ps1: the deploy refuses a television whose serial is not the expected
# one. Pure comparison plus one read against a port that is provably closed (127.0.0.1:9);
# no real device is contacted.
$projectRoot = Split-Path -Parent $PSScriptRoot
$guardTools = Join-Path $projectRoot 'tools\DeviceGuard.ps1'

function Get-ThrownMessage([scriptblock] $block) {
    try { & $block } catch { return $_.Exception.Message }
    return $null
}

Describe 'Device identity guard' {
    BeforeEach {
        . $guardTools
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root | Out-Null
        $info = '<?xml version="1.0" encoding="UTF-8" ?><device-info><serial-number>SER12345</serial-number></device-info>'
    }

    It 'matches the serial the device reports' {
        (Test-DeviceSerialMatches -InfoXml $info -ExpectedSerial 'SER12345') | Should Be $true
        (Test-DeviceSerialMatches -InfoXml $info -ExpectedSerial '  SER12345 ') | Should Be $true
    }

    It 'does not match a different serial' {
        (Test-DeviceSerialMatches -InfoXml $info -ExpectedSerial 'OTHER999') | Should Be $false
    }

    It 'cannot identify a device that reports no serial' {
        $msg = Get-ThrownMessage { Test-DeviceSerialMatches -InfoXml '<device-info></device-info>' -ExpectedSerial 'SER12345' }
        $msg | Should Match 'did not report a serial-number'
    }

    It 'throws with the instructions when the expected-device file is missing' {
        $msg = Get-ThrownMessage { Get-ExpectedDeviceSerial -Path (Join-Path $root 'expected-device.txt') }
        $msg | Should Match 'expected-device file is missing'
        $msg | Should Match 'expected-device.example.txt'
    }

    It 'reads the first non-comment line of the expected-device file' {
        $file = Join-Path $root 'expected-device.txt'
        [System.IO.File]::WriteAllText($file, "# a comment`r`n`r`nSER12345`r`n")
        (Get-ExpectedDeviceSerial -Path $file) | Should Be 'SER12345'
    }

    It 'refuses an expected-device file that holds only comments' {
        $file = Join-Path $root 'expected-device.txt'
        [System.IO.File]::WriteAllText($file, "# nothing here`n")
        $msg = Get-ThrownMessage { Get-ExpectedDeviceSerial -Path $file }
        $msg | Should Match 'has no serial'
    }

    It 'throws when the device cannot be read' {
        $file = Join-Path $root 'expected-device.txt'
        [System.IO.File]::WriteAllText($file, "SER12345`n")
        $msg = Get-ThrownMessage { Assert-ExpectedDevice -RokuIp '127.0.0.1' -ExpectedPath $file -EcpPort 9 -TimeoutSec 3 }
        $msg | Should Match 'Could not read /query/device-info'
    }

    It 'never prints the serial it was given' {
        $file = Join-Path $root 'expected-device.txt'
        [System.IO.File]::WriteAllText($file, "SECRETSERIAL777`n")
        $msg = Get-ThrownMessage { Assert-ExpectedDevice -RokuIp '127.0.0.1' -ExpectedPath $file -EcpPort 9 -TimeoutSec 3 }
        $msg | Should Not Match 'SECRETSERIAL777'
    }
}
