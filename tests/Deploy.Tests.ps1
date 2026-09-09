$projectRoot = Split-Path -Parent $PSScriptRoot
$packageTools = Join-Path $projectRoot 'tools\RokuPackage.ps1'

# Two assemblies, not one: ZipFile lives in System.IO.Compression.FileSystem, but
# ZipArchiveMode lives in System.IO.Compression. Loading only the first leaves
# [System.IO.Compression.ZipArchiveMode] unresolvable and every packaging test red.
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

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
