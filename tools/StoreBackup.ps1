# Capture the TV's favorites and recents BEFORE a sideload.
#
# Why this exists: the Roku registry survives a normal reinstall, but a CORRUPT package
# does not -- one bad zip made the TV answer "Unzip failed... Unloading" and the entire
# userdata section was gone, with no copy anywhere. cachefs is no backup either, since a
# reinstall wipes it. The debug console on port 8085 is the only way data leaves the box,
# so the app prints "[STORE] favorites=..." / "[STORE] recents=..." on every playlist
# load and this function relaunches the channel, reads those two lines, and files them.

function Save-RokuStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RokuIp,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [int]$TimeoutSeconds = 45
    )

    # RokuIp may carry a port for the install server; the ECP and console ports are fixed.
    $host_ = $RokuIp.Split(':')[0]

    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($host_, 8085, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(5000)) {
            throw "Debug console on ${host_}:8085 did not accept a connection."
        }
        $client.EndConnect($connect)
        $stream = $client.GetStream()

        # Relaunch so the app re-runs its playlist load and prints the store again.
        #
        # /launch/dev does NOT restart a channel that is already running -- it is a no-op,
        # the app never re-runs its playlist load, no [STORE] lines appear, and this
        # function then times out after $TimeoutSeconds and refuses the whole deploy. That
        # failure has nothing to do with safety, and its message points the operator at
        # -SkipStoreBackup: the one flag that disables the only backup there is. So press
        # Home first, but only when the dev channel is the thing running -- Home is
        # otherwise a pointless poke at whatever the owner was watching.
        #
        # Every step here is best-effort. This whole file runs under
        # $ErrorActionPreference = "Stop", so each ECP call needs its own try/catch or a
        # single unreachable request would abort a deploy that could still have succeeded
        # by reading a console the channel was about to write to anyway.
        try {
            $active = Invoke-WebRequest -Uri "http://${host_}:8060/query/active-app" `
                -TimeoutSec 5 -UseBasicParsing
            if ($active.Content -match 'id="dev"') {
                Write-Host "  (dev channel already running; pressing Home so the relaunch takes)"
                try {
                    Invoke-WebRequest -Uri "http://${host_}:8060/keypress/Home" -Method POST `
                        -TimeoutSec 5 -UseBasicParsing | Out-Null
                    Start-Sleep -Milliseconds 1500
                } catch {
                    Write-Host "  (Home keypress failed; launching anyway)"
                }
            }
        } catch {
            Write-Host "  (could not read active-app; launching anyway)"
        }

        try {
            Invoke-WebRequest -Uri "http://${host_}:8060/launch/dev" -Method POST `
                -TimeoutSec 10 -UseBasicParsing | Out-Null
        } catch {
            Write-Host "  (relaunch request failed; reading the console anyway)"
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $buffer = New-Object byte[] 8192
        $text = ""
        $favorites = $null
        $recents = $null

        while ((Get-Date) -lt $deadline) {
            if ($stream.DataAvailable) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -gt 0) {
                    $text += [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                }
            } else {
                Start-Sleep -Milliseconds 200
            }
            if ($null -eq $favorites) {
                $m = [regex]::Match($text, '\[STORE\] favorites=(.*)')
                if ($m.Success -and $m.Groups[1].Value -match '\]') { $favorites = $m.Groups[1].Value.Trim() }
            }
            if ($null -eq $recents) {
                $m = [regex]::Match($text, '\[STORE\] recents=(.*)')
                if ($m.Success -and $m.Groups[1].Value -match '\]') { $recents = $m.Groups[1].Value.Trim() }
            }
            if ($null -ne $favorites -and $null -ne $recents) { break }
        }

        if ($null -eq $favorites -or $null -eq $recents) {
            throw ("No [STORE] lines appeared on the console within $TimeoutSeconds s. " +
                   "Either the build currently on the TV predates the store dump, or the " +
                   "channel did not reach its playlist load, or it was already running and " +
                   "the relaunch did not restart it.")
        }

        # Parse to prove it is real JSON before calling it a backup. An unparseable
        # capture is not a backup, and saving it would be worse than failing loudly.
        $favObj = $favorites | ConvertFrom-Json
        $recObj = $recents | ConvertFrom-Json
        $favCount = @($favObj).Count
        $recCount = @($recObj).Count

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $path = Join-Path $OutDir "store-$stamp.json"

        # Compose the JSON from the device's own strings rather than round-tripping
        # through ConvertTo-Json. Two PS 5.1 traps, both seen on the first real run:
        #   * ConvertTo-Json wraps a nested array as {"value":[...],"Count":31}, so the
        #     backup could not be read back as a plain list;
        #   * Out-File -Encoding utf8 writes a BOM, and a strict UTF-8 parser rejects
        #     the file outright.
        # $favorites/$recents are already valid JSON (proved by the ConvertFrom-Json
        # above), so emitting them verbatim is both simpler and lossless.
        $json = "{`n  ""capturedAt"": ""$((Get-Date).ToString('s'))"",`n" +
                "  ""rokuIp"": ""$host_"",`n" +
                "  ""favorites"": $favorites,`n" +
                "  ""recents"": $recents`n}`n"
        [System.IO.File]::WriteAllText($path, $json,
            (New-Object System.Text.UTF8Encoding($false)))

        Write-Host "  Store backed up: $favCount favorites, $recCount recents -> $path"
        return $path
    } finally {
        $client.Close()
    }
}


# Rewrite the in-package restore seed from a freshly captured store.
#
# The seed is what ChannelStore.RestoreStoreIfEmpty() replays after an install clears the
# registry. It only helps if it is CURRENT, and it used to be refreshed by hand -- which
# in a project whose own rule is "a mechanism, not a note" was the wrong half of the
# safety net. deploy.ps1 now calls this between capturing the store and building the
# package, so what ships is always the list that was on the TV moments earlier.
function Update-RestoreSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$SeedPath
    )

    $store = Get-Content -Raw -LiteralPath $StorePath | ConvertFrom-Json
    $favorites = @($store.favorites)
    # Drop recents whose names are fragments of an http-user-agent attribute: they came
    # from the pre-fix M3U parser and can never match a channel again.
    $recents = @($store.recents | Where-Object { $_ -notmatch '"' })

    if ($favorites.Count -eq 0) {
        Write-Host "  Seed NOT updated: the captured store has no favourites."
        return $false
    }

    # Serialise with -InputObject, never through the pipeline. A PIPELINE UNROLLS the
    # array, so `@("Only") | ConvertTo-Json` emits the bare string "Only" instead of
    # ["Only"], and `@() | ConvertTo-Json` emits NOTHING AT ALL -- which produced
    # `"recents": ` with no value and a syntactically invalid seed. Both measured on
    # PS 5.1 here; -InputObject gives ["Only"] and [] respectively.
    #
    # This matters more than it looks. The one-favourite case is exactly the state after
    # a registry wipe, when the owner has re-added a single channel -- the moment the
    # seed is the only copy of anything.
    $favJson = ConvertTo-Json -InputObject @($favorites) -Compress -Depth 3
    $recJson = ConvertTo-Json -InputObject @($recents) -Compress -Depth 3

    $json = "{`n" +
            "  ""note"": ""One-shot seed. ChannelStore.RestoreStoreIfEmpty writes a list back only when that registry key is empty, so this file is inert once the store is populated."",`n" +
            "  ""capturedAt"": ""$($store.capturedAt)"",`n" +
            "  ""favorites"": $favJson,`n" +
            "  ""recents"": $recJson`n}`n"

    # Validate IN MEMORY, before anything touches the seed on disk.
    #
    # This used to write first and check afterwards, which is the wrong order for the one
    # file that cannot be regenerated from the repository: by the time the check failed,
    # the malformed seed had already replaced the good one. The operator was then told to
    # re-run with -SkipStoreBackup -- which ships whatever is lying on disk. A validator
    # that runs after the write can only tell you the file you already shipped is broken.
    try {
        $check = $json | ConvertFrom-Json
    } catch {
        throw ("Refusing to write the restore seed: the composed JSON does not parse " +
               "($($_.Exception.Message)). The seed on disk was left untouched.")
    }

    # Assert the TYPE, not merely the count. @(...).Count answers 1 for both ["A"] and
    # "A", so the old count check was structurally blind to the unrolling bug above. On
    # the device ChannelStore passes this value to SaveFavorites and calls .Count() on
    # it, and an roString implements no ifArray -- a bare string would fault inside
    # onPlaylistChange, on exactly the launch that needed recovery.
    foreach ($name in @('favorites', 'recents')) {
        $value = $check.$name
        if ($value -isnot [System.Array]) {
            $shape = if ($null -eq $value) { 'null' } else { $value.GetType().Name }
            throw ("Refusing to write the restore seed: $name serialised as $shape, " +
                   "expected a JSON array. The seed on disk was left untouched.")
        }
    }

    if ($check.favorites.Count -ne $favorites.Count -or $check.recents.Count -ne $recents.Count) {
        throw ("Refusing to write the restore seed: round-trip mismatch " +
               "(favourites $($favorites.Count) -> $($check.favorites.Count), " +
               "recents $($recents.Count) -> $($check.recents.Count)).")
    }

    # No BOM: PowerShell 5.1's Out-File -Encoding utf8 writes one and a strict UTF-8
    # parser then rejects the file.
    [System.IO.File]::WriteAllText($SeedPath, $json,
        (New-Object System.Text.UTF8Encoding($false)))

    Write-Host ("  Restore seed refreshed: $($check.favorites.Count) favourites, " +
                "$($check.recents.Count) recents -> $SeedPath")
    return $true
}
