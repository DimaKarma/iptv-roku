$projectRoot = Split-Path -Parent $PSScriptRoot
$packageTools = Join-Path $projectRoot 'tools\RokuPackage.ps1'

# Two assemblies, not one: ZipFile lives in System.IO.Compression.FileSystem, but
# ZipArchiveMode lives in System.IO.Compression. Loading only the first leaves
# [System.IO.Compression.ZipArchiveMode] unresolvable and every packaging test red.
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

function Get-ThrownMessage([scriptblock] $block) {
    try { & $block } catch { return $_.Exception.Message }
    return $null
}

function New-TestRokuPackage([string] $path, [string[]] $entries) {
    $archive = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entryName in $entries) {
            $entry = $archive.CreateEntry($entryName)
            $writer = [System.IO.StreamWriter]::new($entry.Open())
            try {
                $writer.Write('test')
            } finally {
                $writer.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
}

Describe 'Roku package validation' {
    BeforeEach {
        . $packageTools
        $testRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $testRoot | Out-Null
    }

    It 'rejects a payload that is not a ZIP archive' {
        $archivePath = Join-Path $testRoot 'broken.zip'
        [System.IO.File]::WriteAllBytes($archivePath, [byte[]](0x6d, 0x61, 0x6e, 0x69))

        $errorRecord = $null
        try {
            Test-RokuPackage -Path $archivePath
        } catch {
            $errorRecord = $_
        }

        $errorRecord | Should Not BeNullOrEmpty
        $errorRecord.Exception.Message | Should Match 'not a ZIP archive'
    }

    It 'rejects a ZIP without every Roku package root' {
        $archivePath = Join-Path $testRoot 'incomplete.zip'
        New-TestRokuPackage -path $archivePath -entries @('manifest', 'config.json', 'source/main.brs')

        $errorRecord = $null
        try {
            Test-RokuPackage -Path $archivePath
        } catch {
            $errorRecord = $_
        }

        $errorRecord | Should Not BeNullOrEmpty
        $errorRecord.Exception.Message | Should Match 'missing required entry'
    }

    It 'accepts a package given a RELATIVE path from another directory' {
        # Regression: Set-Location moves PowerShell's location but not the process
        # working directory, so a relative path resolved fine by Test-Path and then
        # failed inside [System.IO.File]::OpenRead. It only shows up when the caller's
        # process CWD differs from the script's directory -- which is exactly what a
        # real deploy does, and what every earlier test here happened not to do.
        $archivePath = Join-Path $testRoot 'relative.zip'
        New-TestRokuPackage -path $archivePath -entries @('manifest', 'config.json', 'source/main.brs', 'components/MainScene.xml', 'images/splash.png')

        $originalCwd = [System.IO.Directory]::GetCurrentDirectory()
        Push-Location $testRoot
        try {
            [System.IO.Directory]::SetCurrentDirectory($env:TEMP)   # process CWD elsewhere
            Test-RokuPackage -Path 'relative.zip' | Should Be $true
        } finally {
            Pop-Location
            # Restore the ORIGINAL process CWD, and only after Pop-Location: leaving it
            # inside TestDrive keeps a handle open and Pester cannot clean the drive up.
            [System.IO.Directory]::SetCurrentDirectory($originalCwd)
        }
    }

    It 'rejects a package whose entry names use backslash separators' {
        # Compress-Archive on PowerShell 5.1 and GNU tar write backslashes. The Roku then
        # answers "Script directory /source does not exist", and a failed install is what
        # cleared the registry twice. The entries are read verbatim, so this must be caught.
        $archivePath = Join-Path $testRoot 'backslash.zip'
        New-TestRokuPackage -path $archivePath -entries @('manifest', 'config.json', 'source\main.brs', 'components\MainScene.xml', 'images\splash.png')

        $errorRecord = $null
        try {
            Test-RokuPackage -Path $archivePath
        } catch {
            $errorRecord = $_
        }

        $errorRecord | Should Not BeNullOrEmpty
        $errorRecord.Exception.Message | Should Match 'Windows path separators'
    }

    It 'accepts a package with all required Roku roots' {
        $archivePath = Join-Path $testRoot 'valid.zip'
        New-TestRokuPackage -path $archivePath -entries @('manifest', 'config.json', 'source/main.brs', 'components/MainScene.xml', 'images/splash.png')

        Test-RokuPackage -Path $archivePath | Should Be $true
    }
}

# NOTE: a 'Roku deploy failure handling' suite used to live here. It was removed, not
# ported, for two reasons:
#
#   1. It copied config.example.json over the project's real config.json and then
#      deleted it in AfterEach. config.json is gitignored, holds the subscription
#      token and exists in one copy with no backup -- one test run destroyed it.
#   2. It asserted only "exit code 1 and no 'Deploy successful!'", which a script that
#      fails to PARSE satisfies. It was green while deploy.ps1 was dead at parse time,
#      so it could not tell a correct failure from a broken script.
#
# A replacement must run deploy.ps1 against a copy of the tree under $TestDrive (never
# the working tree) and assert positive evidence: the output contains 'Deploy failed:'
# and build.zip was produced and validated before the upload was attempted.

# deploy.ps1 itself is run here only from a COPY of it under $TestDrive, never from the
# working tree: the copy has no config.json, no source/ and no TV behind it, so there is
# nothing real to damage (see hazard 1 in .agent-memory/test-run-hazards.md). Both tests
# assert positive evidence -- a specific message -- not merely a non-zero exit code, which
# a script that fails to parse would also produce.
Describe 'deploy.ps1 refuses before it touches a television' {
    BeforeEach {
        $copyRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $copyRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot 'deploy.ps1') -Destination $copyRoot
        Copy-Item -LiteralPath (Join-Path $projectRoot 'tools') -Destination $copyRoot -Recurse
        # a copy must not carry the real needles or any expected-device file
        Remove-Item -LiteralPath (Join-Path $copyRoot 'tools\secret-needles.txt') -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $copyRoot 'tools\expected-device.txt') -ErrorAction SilentlyContinue
        $savedIp = $env:ROKU_IP
        $env:ROKU_IP = $null
    }
    AfterEach {
        $env:ROKU_IP = $savedIp
    }

    It 'stops with a clear message when no address is given' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copyRoot 'deploy.ps1') -RokuPass 'x' 2>&1 | Out-String
        $out | Should Match 'Name the TV'
        $out | Should Match 'ROKU_IP'
        $out | Should Not Match 'Compile-checking'
    }

    It 'rejects an address with a trailing newline' {
        # In .NET `$` also matches before a final newline, so ^...$ lets "host`n" through.
        $env:ROKU_IP = "127.0.0.1`n"
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copyRoot 'deploy.ps1') -RokuPass 'x' -SkipCompileCheck -SkipNodeRefCheck 2>&1 | Out-String
        $out | Should Match 'must be a host name or address'
        $out | Should Not Match 'Refusing to deploy'
        $out | Should Not Match 'Backing up favorites'
    }

    It 'stops at the identity gate when the expected-device file is missing' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copyRoot 'deploy.ps1') -RokuIp '127.0.0.1' -RokuPass 'x' -SkipCompileCheck -SkipNodeRefCheck 2>&1 | Out-String
        $out | Should Match 'expected-device file is missing'
        $out | Should Match 'Refusing to deploy'
        # nothing after the gate ran: no store capture, no package
        $out | Should Not Match 'Backing up favorites'
        (Test-Path -LiteralPath (Join-Path $copyRoot 'build.zip')) | Should Be $false
    }
}

Describe 'Install response verdict' {
    BeforeEach { . $packageTools }

    It 'reads Install Success as success' {
        (Get-RokuInstallVerdict -Response '<font color="red">Install Success.</font>') | Should Be 'success'
    }

    It 'reads Install Failure as failure' {
        (Get-RokuInstallVerdict -Response '<font color="red">Install Failure: Script directory /source does not exist</font>') | Should Be 'failure'
    }

    It 'reads Identical to previous version as identical' {
        (Get-RokuInstallVerdict -Response '<font color="red">Identical to previous version -- not replacing.</font>') | Should Be 'identical'
    }

    It 'reads anything else, an empty answer included, as unrecognized' {
        (Get-RokuInstallVerdict -Response '<html>hello</html>') | Should Be 'unrecognized'
        (Get-RokuInstallVerdict -Response '') | Should Be 'unrecognized'
    }

    It 'lets Identical win when the page also says Install Success' {
        $page = '<font color="red">Install Success.</font> <font color="red">Identical to previous version</font>'
        (Get-RokuInstallVerdict -Response $page) | Should Be 'identical'
    }

    It 'lets Identical win over Install Failure too, and Failure win over Success' {
        (Get-RokuInstallVerdict -Response 'Install Failure. Identical to previous version') | Should Be 'identical'
        (Get-RokuInstallVerdict -Response 'Install Success. Install Failure') | Should Be 'failure'
    }
}

Describe 'curl config line for the digest credentials' {
    BeforeEach { . $packageTools }

    It 'wraps a plain password in the user option' {
        (ConvertTo-CurlUserConfig -User 'rokudev' -Password 'plain') | Should Be 'user = "rokudev:plain"'
    }

    It 'escapes a double quote' {
        (ConvertTo-CurlUserConfig -User 'rokudev' -Password 'p"q') | Should Be 'user = "rokudev:p\"q"'
    }

    It 'escapes a backslash' {
        (ConvertTo-CurlUserConfig -User 'rokudev' -Password 'p\q') | Should Be 'user = "rokudev:p\\q"'
    }

    It 'escapes a backslash before a quote as two separate escapes' {
        (ConvertTo-CurlUserConfig -User 'rokudev' -Password 'a\"b') | Should Be 'user = "rokudev:a\\\"b"'
    }

    It 'leaves hash, space, dollar and percent literal' {
        (ConvertTo-CurlUserConfig -User 'rokudev' -Password 'a#b c$d%e') | Should Be 'user = "rokudev:a#b c$d%e"'
    }

    It 'refuses a line feed or a carriage return' {
        (Get-ThrownMessage { ConvertTo-CurlUserConfig -User 'rokudev' -Password "a`nb" }) | Should Match 'line break'
        (Get-ThrownMessage { ConvertTo-CurlUserConfig -User 'rokudev' -Password "a`rb" }) | Should Match 'line break'
    }
}

# Text-order and shape contracts over deploy.ps1. They are greps: they pin what the script
# says, not what it does, and stay red only for the shape they name.
Describe 'deploy.ps1 order and shape' {
    BeforeEach {
        $deployText = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'deploy.ps1')
    }

    It 'proves the device identity before the store capture touches the TV' {
        $iGate = $deployText.IndexOf('Assert-ExpectedDevice -RokuIp')
        $iSave = $deployText.IndexOf('Save-RokuStore -RokuIp')
        ($iGate -gt 0) | Should Be $true
        ($iSave -gt 0) | Should Be $true
        ($iGate -lt $iSave) | Should Be $true
    }

    It 'takes the install verdict and the curl config from the tested functions' {
        $deployText | Should Match 'Get-RokuInstallVerdict -Response'
        $deployText | Should Match 'ConvertTo-CurlUserConfig -User'
    }

    It 'restores the output encoding in a finally block around the piped config' {
        $deployText | Should Match '(?s)\$savedEncoding = \$OutputEncoding.*?UTF8Encoding\(\$false\).*?try \{.*?\} finally \{\s*\$OutputEncoding = \$savedEncoding'
    }
}
