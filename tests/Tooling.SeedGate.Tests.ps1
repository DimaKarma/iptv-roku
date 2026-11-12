# The seed gate: Test-RokuPackageSeed (tools/RokuPackage.ps1) compares the favourites
# count of the packaged source/restore.json with the store captured from the TV.
#
# Every fixture lives under $TestDrive. Nothing here reads, writes or moves the real
# config.json or source/restore.json (hazard 1 in .agent-memory/test-run-hazards.md).
$projectRoot = Split-Path -Parent $PSScriptRoot
$packageTools = Join-Path $projectRoot 'tools\RokuPackage.ps1'

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

# A package holding only a seed entry; $seedText $null means "no seed entry at all".
function New-SeedPackage([string] $path, [string] $seedText) {
    $archive = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('manifest')
        $w = New-Object System.IO.StreamWriter($entry.Open())
        try { $w.Write('m') } finally { $w.Dispose() }
        if ($null -ne $seedText) {
            $entry = $archive.CreateEntry('source/restore.json')
            $w = New-Object System.IO.StreamWriter($entry.Open())
            try { $w.Write($seedText) } finally { $w.Dispose() }
        }
    } finally {
        $archive.Dispose()
    }
}

function New-CaptureFile([string] $path, [string] $favoritesJson) {
    $text = '{"capturedAt": "2026-01-01T00:00:00", "rokuIp": "x", "favorites": ' + $favoritesJson + ', "recents": []}'
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ThrownMessage([scriptblock] $block) {
    try { & $block } catch { return $_.Exception.Message }
    return $null
}

# Run a block, keep its output values apart from the Write-Host text (information stream).
function Invoke-WithNotice([scriptblock] $block) {
    $all = @(& $block 6>&1)
    $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
    $values = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
    $text = (@($info | ForEach-Object { [string]$_.MessageData }) -join "`n")
    $last = $null
    if ($values.Count -gt 0) { $last = $values[$values.Count - 1] }
    return [pscustomobject]@{ Result = $last; Notice = $text }
}

Describe 'Seed gate against the captured store' {
    BeforeEach {
        . $packageTools
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root | Out-Null
        $zip = Join-Path $root 'seed.zip'
        $capture = Join-Path $root 'store.json'
    }

    It 'passes when the packaged favourites count equals the capture' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": ["A","B"], "recents": []}'
        New-CaptureFile $capture '["A","B"]'
        (Test-RokuPackageSeed -Path $zip -Required -StorePath $capture) | Should Be $true
    }

    It 'refuses a seed whose count differs from the capture' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": ["A"], "recents": []}'
        New-CaptureFile $capture '["A","B"]'
        $msg = Get-ThrownMessage { Test-RokuPackageSeed -Path $zip -Required -StorePath $capture }
        $msg | Should Match 'has 1 favourites but the store'
    }

    It 'refuses a seed with the same count but different content' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": ["A","C"], "recents": []}'
        New-CaptureFile $capture '["A","B"]'
        $msg = Get-ThrownMessage { Test-RokuPackageSeed -Path $zip -Required -StorePath $capture }
        $msg | Should Match 'differs from it at position 2'
        $msg | Should Not Match '"C"'
    }

    It 'refuses a seed holding the same favourites in another order' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": ["B","A"], "recents": []}'
        New-CaptureFile $capture '["A","B"]'
        $msg = Get-ThrownMessage { Test-RokuPackageSeed -Path $zip -Required -StorePath $capture }
        $msg | Should Match 'differs from it at position 1'
    }

    It 'only warns about a differing list when the seed is not required' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": ["B","A"], "recents": []}'
        New-CaptureFile $capture '["A","B"]'
        (Test-RokuPackageSeed -Path $zip -StorePath $capture) | Should Be $false
    }

    It 'passes a kept non-empty seed when the capture is empty, with a notice saying so' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": ["A"], "recents": []}'
        New-CaptureFile $capture '[]'
        $r = Invoke-WithNotice { Test-RokuPackageSeed -Path $zip -Required -StorePath $capture }
        $r.Result | Should Be $true
        $r.Notice | Should Match 'TV reports no favourites'
        $r.Notice | Should Match 'carries 1 favourites'
        $r.Notice | Should Match 'kept on purpose'
    }

    It 'passes an empty seed built from an empty capture, with a notice saying so' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": [], "recents": []}'
        New-CaptureFile $capture '[]'
        $r = Invoke-WithNotice { Test-RokuPackageSeed -Path $zip -Required -StorePath $capture }
        $r.Result | Should Be $true
        $r.Notice | Should Match 'seed is empty: nothing to restore'
    }

    It 'still refuses a non-array seed favorites when the capture is empty' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": "A", "recents": []}'
        New-CaptureFile $capture '[]'
        $msg = Get-ThrownMessage { Test-RokuPackageSeed -Path $zip -Required -StorePath $capture }
        $msg | Should Match 'malformed favorites list'
    }

    It 'reports a seed without a favorites key instead of dereferencing null' {
        New-SeedPackage $zip '{"capturedAt": "t", "recents": []}'
        New-CaptureFile $capture '["A"]'
        $msg = Get-ThrownMessage { Test-RokuPackageSeed -Path $zip -Required -StorePath $capture }
        $msg | Should Match 'malformed favorites list'
        $msg | Should Match 'missing or null'
        $msg | Should Not Match 'null-valued'
    }

    It 'refuses a bare string where the favorites array belongs' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": "A", "recents": []}'
        New-CaptureFile $capture '["A"]'
        $msg = Get-ThrownMessage { Test-RokuPackageSeed -Path $zip -Required -StorePath $capture }
        $msg | Should Match 'malformed favorites list'
    }

    It 'throws when the capture file named by StorePath is missing' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": ["A"], "recents": []}'
        $msg = Get-ThrownMessage { Test-RokuPackageSeed -Path $zip -StorePath (Join-Path $root 'nope.json') }
        $msg | Should Match 'Captured store file not found'
    }

    It 'keeps the old rule as a warning when no StorePath is given' {
        New-SeedPackage $zip '{"capturedAt": "t", "favorites": [], "recents": []}'
        $result = $null
        $threw = $false
        try { $result = Test-RokuPackageSeed -Path $zip -Required } catch { $threw = $true }
        $threw | Should Be $false
        $result | Should Be $false
    }
}
