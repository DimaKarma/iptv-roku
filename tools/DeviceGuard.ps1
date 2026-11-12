# Refuse to install on a television that is not the one the owner named.
#
# deploy.ps1 has no default address and does no discovery, so the address it is given is
# whatever the operator typed or whatever ROKU_IP held. An address can be right and the
# device behind it wrong (a DHCP lease changed hands, a second Roku joined the network),
# and an install is the one operation here that can wipe a registry. So the device must
# also prove WHICH television it is: its serial number, read from ECP, has to equal the
# content of the gitignored file tools/expected-device.txt.
#
# The serial is deliberately never printed -- not the expected one, not the one the device
# reported -- so a deploy log pasted into a bug report does not carry it.

function Get-ExpectedDeviceSerial {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("The expected-device file is missing: $Path`n" +
               "Create it so a deploy can prove it is talking to YOUR television: put the TV's " +
               "serial number in it on a single line (it is shown under Settings > System > About, " +
               "and ECP reports it as serial-number in http://<tv>:8060/query/device-info). " +
               "tools/expected-device.example.txt shows the format; the real file is gitignored. " +
               "Nothing was sent to the TV.")
    }
    # First line that is neither blank nor a # comment.
    $serial = ""
    foreach ($line in ([System.IO.File]::ReadAllText($Path) -split "`r?`n")) {
        $t = $line.Trim([char]0xFEFF, ' ', "`t")
        if ($t -and -not $t.StartsWith('#')) { $serial = $t; break }
    }
    if ([string]::IsNullOrWhiteSpace($serial)) {
        throw ("The expected-device file has no serial in it: $Path -- put the TV's serial " +
               "number on a line of its own (see tools/expected-device.example.txt). Nothing was sent to the TV.")
    }
    return $serial
}

# Pure comparison, so it can be tested without a television. $InfoXml is the body of
# /query/device-info.
function Test-DeviceSerialMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$InfoXml,
        [Parameter(Mandatory = $true)][string]$ExpectedSerial
    )

    try {
        $doc = [xml]$InfoXml
    } catch {
        throw "The device answered /query/device-info with something that is not XML."
    }
    $node = $doc.SelectSingleNode('/device-info/serial-number')
    if ($null -eq $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) {
        throw "The device did not report a serial-number in /query/device-info, so it cannot be identified."
    }
    return ($node.InnerText.Trim() -eq $ExpectedSerial.Trim())
}

function Assert-ExpectedDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RokuIp,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [int]$TimeoutSec = 5,
        # ECP is always on 8060 on a real television; the parameter exists so a test can
        # point the read at a port that is provably closed.
        [int]$EcpPort = 8060
    )

    $expected = Get-ExpectedDeviceSerial -Path $ExpectedPath
    # RokuIp may carry a port for the install server; ECP is always on 8060.
    $hostPart = $RokuIp.Split(':')[0]
    try {
        $response = Invoke-WebRequest -Uri "http://${hostPart}:${EcpPort}/query/device-info" `
            -TimeoutSec $TimeoutSec -UseBasicParsing
    } catch {
        throw "Could not read /query/device-info from ${hostPart}:${EcpPort} ($($_.Exception.Message)). Nothing was installed."
    }
    if (-not (Test-DeviceSerialMatches -InfoXml $response.Content -ExpectedSerial $expected)) {
        throw ("The device at $hostPart is NOT the television named in tools/expected-device.txt " +
               "(its serial number differs). Nothing was sent to it. Check the address; if the " +
               "file is out of date, correct it.")
    }
    Write-Host "  Device identity confirmed (serial matches tools/expected-device.txt)."
}
