# Update-RestoreSeed and the console-fence parsing in tools/StoreBackup.ps1.
#
# Fixtures only, all under $TestDrive: no socket is opened, and neither the real
# source/restore.json nor config.json is touched (hazard 1).
$projectRoot = Split-Path -Parent $PSScriptRoot
$storeTools = Join-Path $projectRoot 'tools\StoreBackup.ps1'

function New-CaptureFile([string] $path, [string] $favoritesJson, [string] $recentsJson) {
    $text = '{"capturedAt": "2026-01-01T00:00:00", "rokuIp": "x", "favorites": ' + $favoritesJson + ', "recents": ' + $recentsJson + '}'
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ThrownMessage([scriptblock] $block) {
    try { & $block } catch { return $_.Exception.Message }
    return $null
}

function Invoke-WithNotice([scriptblock] $block) {
    $all = @(& $block 6>&1)
    $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
    $values = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
    $text = (@($info | ForEach-Object { [string]$_.MessageData }) -join "`n")
    $last = $null
    if ($values.Count -gt 0) { $last = $values[$values.Count - 1] }
    return [pscustomobject]@{ Result = $last; Notice = $text }
}

Describe 'Update-RestoreSeed' {
    BeforeEach {
        . $storeTools
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root | Out-Null
        $capture = Join-Path $root 'store.json'
        $seed = Join-Path $root 'restore.json'
    }

    It 'keeps a single favourite an ARRAY in the written seed' {
        New-CaptureFile $capture '["Only"]' '["R1"]'
        (Update-RestoreSeed -StorePath $capture -SeedPath $seed) | Should Be $true
        $raw = [System.IO.File]::ReadAllText($seed)
        $raw | Should Match '"favorites": \["Only"\]'
        $parsed = $raw | ConvertFrom-Json
        ($parsed.favorites -is [System.Array]) | Should Be $true
        $parsed.favorites.Count | Should Be 1
        ($parsed.recents -is [System.Array]) | Should Be $true
    }

    It 'keeps an existing non-empty seed untouched when the capture is empty' {
        $before = "{`n  `"favorites`": [`"Old1`",   `"Old2`"],`n`n  `"recents`": [`"R0`"]  }"
        [System.IO.File]::WriteAllText($seed, $before)
        $bytesBefore = ([System.IO.File]::ReadAllBytes($seed) -join ',')
        New-CaptureFile $capture '[]' '["Newer"]'
        $keepDir = Join-Path $root 'kept'
        $r = Invoke-WithNotice { Update-RestoreSeed -StorePath $capture -SeedPath $seed -BackupDir $keepDir }
        $r.Result | Should Be 'kept'
        ([System.IO.File]::ReadAllBytes($seed) -join ',') | Should Be $bytesBefore
        # nothing is overwritten, so nothing is copied either
        (Test-Path -LiteralPath $keepDir) | Should Be $false
        $r.Notice | Should Match 'TV reports NO favourites'
        $r.Notice | Should Match 'previous seed with 2 favourites is KEPT'
        $r.Notice | Should Match 'only if the TV''s registry is wiped'
        $r.Notice | Should Match 'recents are not refreshed'
    }

    It 'writes an empty favourites array and the captured recents when the capture is empty and there is no seed' {
        New-CaptureFile $capture '[]' '["R1"]'
        $r = Invoke-WithNotice { Update-RestoreSeed -StorePath $capture -SeedPath $seed }
        $r.Result | Should Be $true
        $raw = [System.IO.File]::ReadAllText($seed)
        $raw | Should Match '"favorites": \[\]'
        $parsed = $raw | ConvertFrom-Json
        ($parsed.favorites -is [System.Array]) | Should Be $true
        $parsed.favorites.Count | Should Be 0
        $parsed.recents.Count | Should Be 1
        $r.Notice | Should Match 'written EMPTY'
    }

    It 'replaces an existing seed that holds no favourites by an empty one' {
        [System.IO.File]::WriteAllText($seed, '{"favorites": [], "recents": ["Stale"]}')
        New-CaptureFile $capture '[]' '["R1"]'
        (Update-RestoreSeed -StorePath $capture -SeedPath $seed) | Should Be $true
        $parsed = [System.IO.File]::ReadAllText($seed) | ConvertFrom-Json
        $parsed.favorites.Count | Should Be 0
        $parsed.recents[0] | Should Be 'R1'
    }

    It 'backs up a malformed seed, then writes an empty one, when the capture is empty' {
        $bad = '{"favorites": ["Old1", '
        [System.IO.File]::WriteAllText($seed, $bad)
        New-CaptureFile $capture '[]' '[]'
        $keepDir = Join-Path $root 'kept'
        $r = Invoke-WithNotice { Update-RestoreSeed -StorePath $capture -SeedPath $seed -BackupDir $keepDir }
        $r.Result | Should Be $true
        $copies = @(Get-ChildItem -LiteralPath $keepDir -Filter 'restore-bad-*.json')
        $copies.Count | Should Be 1
        [System.IO.File]::ReadAllText($copies[0].FullName) | Should Be $bad
        $parsed = [System.IO.File]::ReadAllText($seed) | ConvertFrom-Json
        ($parsed.favorites -is [System.Array]) | Should Be $true
        $parsed.favorites.Count | Should Be 0
        $r.Notice | Should Match 'malformed'
    }

    It 'treats a seed without a favorites array as malformed' {
        [System.IO.File]::WriteAllText($seed, '{"recents": []}')
        New-CaptureFile $capture '[]' '[]'
        $keepDir = Join-Path $root 'kept'
        (Update-RestoreSeed -StorePath $capture -SeedPath $seed -BackupDir $keepDir) | Should Be $true
        @(Get-ChildItem -LiteralPath $keepDir -Filter 'restore-bad-*.json').Count | Should Be 1
    }

    It 'rewrites the seed from a non-empty capture even when an old seed exists' {
        [System.IO.File]::WriteAllText($seed, '{"favorites": ["Old1","Old2"], "recents": []}')
        New-CaptureFile $capture '["N1","N2","N3"]' '["R1"]'
        $keepDir = Join-Path $root 'kept'
        (Update-RestoreSeed -StorePath $capture -SeedPath $seed -BackupDir $keepDir) | Should Be $true
        $parsed = [System.IO.File]::ReadAllText($seed) | ConvertFrom-Json
        ($parsed.favorites -join ',') | Should Be 'N1,N2,N3'
        (Test-Path -LiteralPath $keepDir) | Should Be $false
    }

    It 'creates no seed and changes none when the captured favorites is not an array' {
        New-CaptureFile $capture '"A"' '[]'
        $msg = Get-ThrownMessage { Update-RestoreSeed -StorePath $capture -SeedPath $seed }
        $msg | Should Match 'expected a JSON array'
        (Test-Path -LiteralPath $seed) | Should Be $false

        $original = '{"favorites": ["Keep"], "recents": []}'
        [System.IO.File]::WriteAllText($seed, $original)
        $msg2 = Get-ThrownMessage { Update-RestoreSeed -StorePath $capture -SeedPath $seed }
        $msg2 | Should Match 'left untouched'
        [System.IO.File]::ReadAllText($seed) | Should Be $original
    }

    It 'refuses a capture with no favorites key at all' {
        $text = '{"capturedAt": "t", "recents": []}'
        [System.IO.File]::WriteAllText($capture, $text)
        $msg = Get-ThrownMessage { Update-RestoreSeed -StorePath $capture -SeedPath $seed }
        $msg | Should Match 'favorites is missing'
        (Test-Path -LiteralPath $seed) | Should Be $false
    }

    It 'writes the seed without a byte order mark' {
        New-CaptureFile $capture '["A"]' '[]'
        Update-RestoreSeed -StorePath $capture -SeedPath $seed | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($seed)
        $bytes[0] | Should Be 0x7B
    }
}

Describe 'Console fence parsing' {
    BeforeEach {
        . $storeTools
        $fence = 'scrpt.ctx.run.enter'
    }

    It 'counts every start marker and reports a window only above the prior count' {
        $text = "$fence`nold`n$fence`nnew`n"
        (Get-RokuStartMarkerCount -Text $text) | Should Be 2
        (Find-RokuStoreDump -Text $text -MarkerCountBefore 2).HasFence | Should Be $false
        (Find-RokuStoreDump -Text $text -MarkerCountBefore 1).HasFence | Should Be $true
        (Find-RokuStoreDump -Text $text -MarkerCountBefore 1).MarkerCount | Should Be 2
    }

    It 'throws when only the old instance marker and its store lines are on the console' {
        # the relaunch did not restart the channel: one marker from before, nothing new
        $text = "$fence`n[STORE] favorites=[`"OLD`"]`n[STORE] recents=[]`n"
        $msg = Get-ThrownMessage { Get-RokuStoreFromText -Text $text -MarkerCountBefore 1 }
        $msg | Should Match 'the relaunch did not restart the channel \(no new start marker\)'
    }

    It 'returns the NEW pair, not the old one, after a new marker' {
        $text = "$fence`n[STORE] favorites=[`"OLD`"]`n[STORE] recents=[`"RO`"]`n$fence`n[STORE] favorites=[`"NEW`"]`n[STORE] recents=[`"RN`"]`n"
        $r = Get-RokuStoreFromText -Text $text -MarkerCountBefore 1
        $r.Favorites | Should Be '["NEW"]'
        $r.Recents | Should Be '["RN"]'
        $r.DumpCount | Should Be 1
    }

    It 'accepts the pair after the only marker when nothing was on the console before' {
        $text = "$fence`n[STORE] favorites=[`"A`"]`n[STORE] recents=[]`n"
        $r = Get-RokuStoreFromText -Text $text -MarkerCountBefore 0
        $r.Favorites | Should Be '["A"]'
    }

    It 'throws the no-[STORE] error when a new marker has no pair after it' {
        $text = "$fence`n[STORE] favorites=[`"OLD`"]`n[STORE] recents=[]`n$fence`nstarting up`n"
        $msg = Get-ThrownMessage { Get-RokuStoreFromText -Text $text -MarkerCountBefore 1 }
        $msg | Should Match 'No \[STORE\] lines appeared'
    }

    It 'throws when the text has no channel-start marker' {
        $text = "[STORE] favorites=[`"A`"]`n[STORE] recents=[]`n"
        $msg = Get-ThrownMessage { Get-RokuStoreFromText -Text $text }
        $msg | Should Match 'channel-start marker'
    }

    It 'uses the text after the LAST marker' {
        $text = "$fence`n[STORE] favorites=[`"OLD`"]`n[STORE] recents=[]`n$fence`n[STORE] favorites=[`"NEW`"]`n[STORE] recents=[`"R`"]`n"
        $r = Get-RokuStoreFromText -Text $text
        $r.Favorites | Should Be '["NEW"]'
        $r.Recents | Should Be '["R"]'
        # only the dump after the last marker counts; a window opened at the first marker
        # would also see the old dump and report two
        $r.DumpCount | Should Be 1
    }

    It 'ignores a store dump that sits before the last marker' {
        $text = "$fence`n[STORE] favorites=[`"OLD`"]`n[STORE] recents=[]`n$fence`nstarting up`n"
        $msg = Get-ThrownMessage { Get-RokuStoreFromText -Text $text }
        $msg | Should Match 'No \[STORE\] lines appeared'
    }

    It 'reports the number of dumps seen after the marker' {
        $text = "$fence`n[STORE] favorites=[`"A`"]`n[STORE] recents=[]`n[STORE] favorites=[`"A`",`"B`"]`n[STORE] recents=[]`n"
        $r = Get-RokuStoreFromText -Text $text
        $r.DumpCount | Should Be 2
        $r.Favorites | Should Be '["A","B"]'
    }
}

Describe 'Read-RokuConsoleUntilQuiet' {
    BeforeEach { . $storeTools }

    It 'keeps reading while chunks arrive and stops once the console is quiet' {
        # Loopback only: a listener on an ephemeral 127.0.0.1 port and a job that connects to
        # it. The second chunk arrives 0.6 s after the first, inside the 1.5 s quiet period,
        # so a reader that stopped at the first read would miss it.
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $job = Start-Job -ArgumentList $port -ScriptBlock {
            param($p)
            $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $p)
            $s = $c.GetStream()
            $b = [System.Text.Encoding]::UTF8.GetBytes('chunk-one scrpt.ctx.run.enter ')
            $s.Write($b, 0, $b.Length); $s.Flush()
            Start-Sleep -Milliseconds 600
            $b = [System.Text.Encoding]::UTF8.GetBytes('chunk-two')
            $s.Write($b, 0, $b.Length); $s.Flush()
            Start-Sleep -Seconds 12
            $c.Close()
        }
        $server = $null
        try {
            $until = (Get-Date).AddSeconds(30)
            while (-not $listener.Pending() -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 100 }
            $listener.Pending() | Should Be $true
            $server = $listener.AcceptTcpClient()
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $got = Read-RokuConsoleUntilQuiet -Stream $server.GetStream() -QuietMs 1500 -CapMs 9000
            $clock.Stop()
            $got | Should Match 'chunk-one'
            $got | Should Match 'chunk-two'
            # returned on quiet, well before the hard cap
            ($clock.ElapsedMilliseconds -lt 8000) | Should Be $true
        } finally {
            if ($null -ne $server) { $server.Close() }
            $listener.Stop()
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test-RestoreSeedKept' {
    BeforeEach { . $storeTools }
    It 'is true only for the string kept' {
        (Test-RestoreSeedKept 'kept') | Should Be $true
    }
    It 'is false for the boolean true (the old -eq comparison said true)' {
        (Test-RestoreSeedKept $true) | Should Be $false
    }
    It 'is false for false and for null' {
        (Test-RestoreSeedKept $false) | Should Be $false
        (Test-RestoreSeedKept $null) | Should Be $false
    }
}

Describe 'Invoke-RokuLaunchWithRetry' {
    BeforeEach { . $storeTools; $script:calls = 0 }
    It 'succeeds on the third attempt: 3 calls, returns true' {
        $r = Invoke-RokuLaunchWithRetry -Attempts 4 -DelayMs 0 -Action {
            $script:calls++
            if ($script:calls -lt 3) { throw 'no' }
        }
        $r | Should Be $true
        $script:calls | Should Be 3
    }
    It 'always fails: 4 calls, returns false' {
        $r = Invoke-RokuLaunchWithRetry -Attempts 4 -DelayMs 0 -Action { $script:calls++; throw 'no' }
        $r | Should Be $false
        $script:calls | Should Be 4
    }
    It 'first success: 1 call, returns true' {
        $r = Invoke-RokuLaunchWithRetry -Attempts 4 -DelayMs 0 -Action { $script:calls++ }
        $r | Should Be $true
        $script:calls | Should Be 1
    }
}
