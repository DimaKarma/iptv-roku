# Capture the TV's favorites and recents BEFORE a sideload.
#
# Why this exists: the Roku registry survives a normal reinstall, but a CORRUPT package
# does not -- one bad zip made the TV answer "Unzip failed... Unloading" and the entire
# userdata section was gone, with no copy anywhere. cachefs is no backup either, since a
# reinstall wipes it. The debug console on port 8085 is the only way data leaves the box,
# so the app prints "[STORE] favorites=..." / "[STORE] recents=..." on every playlist
# load and this function relaunches the channel, reads those two lines, and files them.

# Parse the [STORE] dump out of console text, relative to the channel-start fence.
#
# Roku logs `scrpt.ctx.run.enter` when a channel starts, and the console hands over its
# whole backlog the moment a socket connects, so only the text after the LAST occurrence of
# the marker belongs to the instance that was just launched (hazard 22). This function is
# the single place that rule lives. It never throws: Find-RokuStoreDump is used inside the
# read loop, where "no marker yet" just means "keep reading".
#
# -MarkerCountBefore is the number of markers already on the console BEFORE the relaunch was
# requested (the backlog of the outgoing instance). A window only exists when the text holds
# MORE markers than that: if pressing Home failed and /launch/dev did not restart a running
# channel, the last marker in the text belongs to the OLD instance and its [STORE] lines must
# not be accepted. HasFence therefore means "a marker with an ordinal greater than
# MarkerCountBefore was seen".
#
# With NO marker there is no window at all: nothing is searched, because a capture that
# cannot prove it belongs to the instance just started might be one run stale, and an
# unprovable backup is the one thing this tool must not hand over. (It used to search the
# whole text and print a warning; a warning does not stop a stale seed from shipping.)
function Find-RokuStoreDump {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [ValidateRange(0, 1000000)][int]$MarkerCountBefore = 0
    )

    $result = [pscustomobject]@{ HasFence = $false; Favorites = $null; Recents = $null; DumpCount = 0; MarkerCount = 0 }
    $markers = [regex]::Matches($Text, [regex]::Escape('scrpt.ctx.run.enter'))
    $result.MarkerCount = $markers.Count
    if ($markers.Count -le $MarkerCountBefore) { return $result }
    $result.HasFence = $true
    $window = $Text.Substring($markers[$markers.Count - 1].Index)

    $favMatches = [regex]::Matches($window, '\[STORE\] favorites=(.*)')
    $result.DumpCount = $favMatches.Count
    if ($favMatches.Count -gt 0) {
        $last = $favMatches[$favMatches.Count - 1]
        if ($last.Groups[1].Value -match '\]') { $result.Favorites = $last.Groups[1].Value.Trim() }
    }
    $recMatches = [regex]::Matches($window, '\[STORE\] recents=(.*)')
    if ($recMatches.Count -gt 0) {
        $last = $recMatches[$recMatches.Count - 1]
        if ($last.Groups[1].Value -match '\]') { $result.Recents = $last.Groups[1].Value.Trim() }
    }
    return $result
}

# The strict form, used once the read loop has finished: a missing channel-start marker
# THROWS, and so does a missing [STORE] pair.
function Get-RokuStoreFromText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [int]$TimeoutSeconds = 45,
        [ValidateRange(0, 1000000)][int]$MarkerCountBefore = 0
    )

    $found = Find-RokuStoreDump -Text $Text -MarkerCountBefore $MarkerCountBefore
    if (-not $found.HasFence -and $MarkerCountBefore -gt 0) {
        throw ("the relaunch did not restart the channel (no new start marker): the console held " +
               "$MarkerCountBefore start marker(s) from the previous instance and none appeared " +
               "within $TimeoutSeconds s after the relaunch, so the [STORE] lines on it belong to " +
               "the OLD instance. Nothing was backed up. Re-run.")
    }
    if (-not $found.HasFence) {
        throw ("No channel-start marker (scrpt.ctx.run.enter) was seen on the console within " +
               "$TimeoutSeconds s, so this capture cannot be shown to belong to the instance " +
               "just launched and may be one run stale. Nothing was backed up. Re-run.")
    }
    if ($null -eq $found.Favorites -or $null -eq $found.Recents) {
        throw ("No [STORE] lines appeared on the console within $TimeoutSeconds s. " +
               "Either the build currently on the TV predates the store dump, or the " +
               "channel did not reach its playlist load, or it was already running and " +
               "the relaunch did not restart it.")
    }
    return $found
}


# Read whatever the console already holds, until it has been quiet for $QuietMs, bounded by
# a hard cap of $CapMs. Used right after the socket connects: the console replays its whole
# backlog at once, and the markers in it are the OLD instance's. Counting them BEFORE the
# relaunch is requested is what lets a marker be recognised as new afterwards.
function Read-RokuConsoleUntilQuiet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Stream,
        [int]$QuietMs = 1500,
        [int]$CapMs = 6000
    )

    $buffer = New-Object byte[] 8192
    $sb = New-Object System.Text.StringBuilder
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $quiet = 0
    while ($clock.ElapsedMilliseconds -lt $CapMs) {
        if ($Stream.DataAvailable) {
            $read = $Stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $read))
            $quiet = 0
        } else {
            Start-Sleep -Milliseconds 100
            $quiet += 100
        }
        if ($quiet -ge $QuietMs) { break }
    }
    return $sb.ToString()
}

function Get-RokuStartMarkerCount {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    return [regex]::Matches($Text, [regex]::Escape('scrpt.ctx.run.enter')).Count
}


# Runs $Action (it must THROW on failure) up to $Attempts times, $DelayMs apart, and stops at
# the first success. Returns $true on success and $false when every attempt failed. One line
# is printed per failed attempt. Kept free of any network call so it can be unit-tested.
function Invoke-RokuLaunchWithRetry {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $Action,
        [int] $Attempts = 4,
        [int] $DelayMs = 3000
    )
    for ($n = 1; $n -le $Attempts; $n++) {
        try {
            & $Action | Out-Null
            return $true
        } catch {
            Write-Host "  (relaunch attempt $n failed; retrying)"
            if ($n -lt $Attempts -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        }
    }
    return $false
}

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

        # Drain the backlog and count the start markers in it BEFORE anything is sent to the
        # TV. A [STORE] pair is accepted only from after a marker numbered above this count,
        # i.e. one written by an instance that started after this point. Without it, a failed
        # Home press plus a /launch/dev that does not restart a running app would leave the
        # OLD instance's marker as the last one, and its stale pair would be accepted.
        $text = Read-RokuConsoleUntilQuiet -Stream $stream
        $priorMarkers = Get-RokuStartMarkerCount -Text $text
        Write-Host "  (console backlog read: $priorMarkers earlier start marker(s))"

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
                    Start-Sleep -Milliseconds 3000
                } catch {
                    Write-Host "  (Home keypress failed; launching anyway)"
                }
            }
        } catch {
            Write-Host "  (could not read active-app; launching anyway)"
        }

        # The TV can still be leaving the app when the first request arrives, so the launch
        # is tried up to 4 times, 3 s apart.
        $launched = Invoke-RokuLaunchWithRetry -Attempts 4 -DelayMs 3000 -Action {
            Invoke-WebRequest -Uri "http://${host_}:8060/launch/dev" -Method POST `
                -TimeoutSec 10 -UseBasicParsing | Out-Null
        }
        if (-not $launched) {
            Write-Host "  (relaunch request failed; reading the console anyway)"
        }

        # Take the LAST [STORE] pair in the window, never the first.
        #
        # The first one lies. Measured 2026-09-10: a single relaunch printed
        # "favorites=<32 entries>" and then "favorites=<31 entries>" for one unchanged
        # registry. The outgoing app instance flushes its own buffered console output into
        # this socket as Home + /launch/dev restart it, so the earliest lines can belong to
        # the PREVIOUS run -- and the app also dumps the store twice per launch, once for
        # the cached playlist and once for the network one. Matching the first hit wrote a
        # restore seed of 32 for a device holding 31. That direction was harmless; the same
        # mechanism can just as easily ship a seed that is BEHIND the device, which is
        # precisely the loss the seed exists to prevent.
        #
        # Waiting for quiet rather than for a fixed delay keeps this independent of how
        # long the TV takes to boot and fetch a playlist -- a number that has no business
        # being hardcoded here.
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $buffer = New-Object byte[] 8192
        $favorites = $null
        $recents = $null
        $found = $null
        $quietFor = 0
        $QUIET_MS = 3000        # no new console output for this long = the burst is over

        while ((Get-Date) -lt $deadline) {
            if ($stream.DataAvailable) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -gt 0) {
                    $text += [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                    $quietFor = 0
                }
            } else {
                Start-Sleep -Milliseconds 200
                $quietFor += 200
            }

            # Only the text after the channel-start marker counts; see Find-RokuStoreDump.
            # Waiting for quiet is not enough on its own: the backlog burst goes quiet
            # within a second or two, long before the new instance has fetched a playlist,
            # so a quiet-only rule still reads the old numbers (measured: it returned in 6s,
            # when a real load takes ~20).
            $found = Find-RokuStoreDump -Text $text -MarkerCountBefore $priorMarkers
            $favorites = $found.Favorites
            $recents = $found.Recents

            # Stop once a pair is in hand AND the console has gone quiet, so a later dump
            # in the same burst cannot be missed by breaking on the first one.
            if ($null -ne $favorites -and $null -ne $recents -and $quietFor -ge $QUIET_MS) { break }
        }

        # Strict from here on: no NEW marker, or no [STORE] pair, throws (see Get-RokuStoreFromText).
        $final = Get-RokuStoreFromText -Text $text -TimeoutSeconds $TimeoutSeconds -MarkerCountBefore $priorMarkers
        $favorites = $final.Favorites
        $recents = $final.Recents
        if ($final.DumpCount -gt 1) {
            Write-Host ("  ({0} store dumps seen after the channel started; using the last)" -f $final.DumpCount)
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


# True only for the STRING 'kept'. Update-RestoreSeed returns $true or 'kept', and in
# PowerShell `$true -eq 'kept'` is TRUE (the string is converted to bool), so a bare -eq
# cannot tell the two outcomes apart.
function Test-RestoreSeedKept {
    param($Outcome)
    return (($Outcome -is [string]) -and ($Outcome -eq 'kept'))
}

# Rewrite the in-package restore seed from a freshly captured store.
#
# The seed is what ChannelStore.RestoreStoreIfEmpty() replays after an install clears the
# registry. It only helps if it is CURRENT, and it used to be refreshed by hand -- which
# in a project whose own rule is "a mechanism, not a note" was the wrong half of the
# safety net. deploy.ps1 now calls this between capturing the store and building the
# package, so what ships is always the list that was on the TV moments earlier.
#
# Returns $true when the seed was (re)written and the string 'kept' when it was deliberately
# left alone (see below), so the caller can tell the two apart.
#
# An EMPTY capture is the dangerous case, and the owner's decision is the ORIGINAL mechanism:
# an install can wipe the registry, and the seed is what replays the favourites afterwards.
#   * capture has favourites          -> the seed is rewritten from the capture.
#   * capture empty, seed has some    -> NOTHING is written; the old seed stays in the package
#                                        and is used only if the registry is wiped (the app
#                                        seeds only when its whole store is empty).
#   * capture empty, no usable seed   -> a seed with "favorites": [] is written (nothing to
#                                        preserve); a malformed old seed is copied to
#                                        $BackupDir as restore-bad-<stamp>.json first.
function Update-RestoreSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$SeedPath,
        # Where to keep a copy of a MALFORMED previous seed before it is replaced. Optional so
        # the function stays usable without a folder.
        [string]$BackupDir = ""
    )

    $store = Get-Content -Raw -LiteralPath $StorePath | ConvertFrom-Json
    if ($null -eq $store) {
        throw "Refusing to write the restore seed: the capture $StorePath is empty or not a JSON object. The seed on disk was left untouched."
    }

    # Assert the TYPE of what was captured before reading a count from it.
    # @($null).Count is 1 and @("A").Count is 1, so counting first cannot tell a missing
    # list or a bare string from a real one-element array. A capture whose lists are not
    # arrays is not a capture of an empty store: it is damage, and the seed stays as it was.
    foreach ($name in @('favorites', 'recents')) {
        $captured = $store.$name
        if ($captured -isnot [System.Array]) {
            $shape = if ($null -eq $captured) { 'missing' } else { $captured.GetType().Name }
            throw ("Refusing to write the restore seed: the captured $name is $shape, " +
                   "expected a JSON array. The seed on disk was left untouched.")
        }
    }

    $favorites = @($store.favorites)
    # Drop recents whose names are fragments of an http-user-agent attribute: they came
    # from the pre-fix M3U parser and can never match a channel again.
    $recents = @($store.recents | Where-Object { $_ -notmatch '"' })

    # An EMPTY capture says the TV holds no favourites right now. That is not proof the owner
    # wants none: an install can wipe the registry, and the old seed is what would bring the
    # list back. So an existing seed that still holds favourites is KEPT untouched, and only
    # a seed with nothing to preserve (absent, empty, or malformed) is replaced by an empty one.
    if ($favorites.Count -eq 0 -and (Test-Path -LiteralPath $SeedPath)) {
        $old = $null
        $oldProblem = $null
        try {
            $old = [System.IO.File]::ReadAllText($SeedPath) | ConvertFrom-Json
        } catch {
            $oldProblem = 'it could not be read or parsed'
        }
        if ($null -eq $oldProblem -and ($null -eq $old -or $old.favorites -isnot [System.Array])) {
            $oldProblem = 'it has no favorites array'
        }
        if ($null -ne $oldProblem) {
            # Deliberately not echoing the parser message: it may quote the owner's list.
            Write-Host "  NOTICE: the previous restore seed is malformed ($oldProblem); it is replaced by an empty seed."
            if ($BackupDir) {
                if (-not (Test-Path -LiteralPath $BackupDir)) {
                    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
                }
                $bad = Join-Path $BackupDir ("restore-bad-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".json")
                Copy-Item -LiteralPath $SeedPath -Destination $bad
                Write-Host "  The malformed seed was copied to $bad"
            }
        } elseif ($old.favorites.Count -gt 0) {
            Write-Host ("  NOTICE: the TV reports NO favourites. The previous seed with $($old.favorites.Count) " +
                        "favourites is KEPT in the package exactly as it is (its recents are not refreshed " +
                        "from this capture either). It will be used only if the TV's registry is wiped: " +
                        "the app seeds only when its whole store is empty.")
            return 'kept'
        }
    }

    # Serialise with -InputObject, never through the pipeline. A PIPELINE UNROLLS the
    # array, so `@("Only") | ConvertTo-Json` emits the bare string "Only" instead of
    # ["Only"], and `@() | ConvertTo-Json` emits NOTHING AT ALL -- which produced
    # `"recents": ` with no value and a syntactically invalid seed. Both measured on
    # PS 5.1 here; -InputObject gives ["Only"] and [] respectively.
    #
    # (And the empty case: @() is [] only through -InputObject.)
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

    if ($favorites.Count -eq 0) {
        Write-Host ("  Restore seed written EMPTY: the TV reports no favourites and there was no previous " +
                    "seed with favourites to preserve ($($check.recents.Count) recents -> $SeedPath)")
    } else {
        Write-Host ("  Restore seed refreshed: $($check.favorites.Count) favourites, " +
                    "$($check.recents.Count) recents -> $SeedPath")
    }
    return $true
}
