$projectRoot = Split-Path -Parent $PSScriptRoot
$packageTools = Join-Path $projectRoot 'tools\RokuPackage.ps1'
$deployScript = Join-Path $projectRoot 'deploy.ps1'

function New-TestRokuPackage([string] $path, [string[]] $entries) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
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

    It 'accepts a package with all required Roku roots' {
        $archivePath = Join-Path $testRoot 'valid.zip'
        New-TestRokuPackage -path $archivePath -entries @('manifest', 'config.json', 'source/main.brs', 'components/MainScene.xml', 'images/splash.png')

        Test-RokuPackage -Path $archivePath | Should Be $true
    }
}

Describe 'Roku deploy failure handling' {
    BeforeEach {
        Copy-Item (Join-Path $projectRoot 'config.example.json') (Join-Path $projectRoot 'config.json')
    }

    AfterEach {
        Remove-Item (Join-Path $projectRoot 'config.json') -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $projectRoot 'build.zip') -ErrorAction SilentlyContinue
    }

    It 'fails without claiming success when the Roku upload cannot connect' {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deployScript -RokuIp '127.0.0.1' -RokuPass 'test-password' 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should Be 1
        ($output -join [Environment]::NewLine) | Should Not Match 'Deploy successful!'
    }
}
