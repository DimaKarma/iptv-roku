# Windows PowerShell 5.1 does not load this assembly by default. Without it
# [System.IO.Compression.ZipFile] raises TypeNotFound, which the catch below would
# report as a broken archive -- so a perfectly valid package looks corrupt. Loading
# it here, at file scope, keeps it out of the function body: type literals inside a
# function are resolved when that function is compiled, which happens before any
# statement in its body runs.
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Test-RokuPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Roku package was not created: $Path"
    }

    # Resolve to an absolute path before handing it to .NET. Set-Location changes
    # PowerShell's location but NOT the process working directory, so Test-Path above
    # (PowerShell) and [System.IO.File]::OpenRead below (.NET) resolve a relative path
    # against DIFFERENT directories -- the check passes and the open then fails with
    # "could not find file" pointing at a directory the caller never mentioned.
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 4) {
            throw "Roku package is not a ZIP archive: $Path"
        }

        $magic = New-Object byte[] 2
        [void]$stream.Read($magic, 0, $magic.Length)
        if ($magic[0] -ne 0x50 -or $magic[1] -ne 0x4b) {
            throw "Roku package is not a ZIP archive: $Path"
        }
    } finally {
        $stream.Dispose()
    }

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    } catch {
        # Keep the underlying reason: "cannot open" and "not a ZIP" are different
        # failures, and hiding one behind the other is what made this validator lie.
        throw "Roku package is not a ZIP archive: ${Path} ($($_.Exception.Message))"
    }

    try {
        # Read the entry names VERBATIM. This used to be
        # `$_.FullName.Replace('\', '/')`, which normalised Windows separators away
        # before the checks below could see them -- so a package built with backslashes
        # (what PowerShell's Compress-Archive and GNU tar produce) passed validation,
        # and the Roku then answered "Install Failure: Script directory /source does not
        # exist". A failed install is what cleared the device registry twice. The
        # launderer WAS the defect: it erased exactly the thing the validator existed to
        # catch, and it did so one line above the loop that would otherwise have caught it.
        $entries = @($archive.Entries | ForEach-Object { $_.FullName })
        $requiredFiles = @('manifest', 'config.json')
        $requiredDirectories = @('source/', 'components/', 'images/')

        # Diagnose the separator explicitly. The required-directory loop below already
        # rejects such a package on its own (no entry starts with "source/"), but it
        # would blame a missing directory that is in fact present under another name.
        $backslashed = @($entries | Where-Object { $_.Contains('\') })
        if ($backslashed.Count -gt 0) {
            throw ("Roku package uses Windows path separators (entry '" +
                   $backslashed[0] + "'); Roku answers " +
                   '"Install Failure: Script directory /source does not exist". ' +
                   "Build it with the Windows bsdtar at C:\Windows\System32\tar.exe.")
        }

        foreach ($requiredFile in $requiredFiles) {
            if ($entries -notcontains $requiredFile) {
                throw "Roku package is missing required entry: $requiredFile"
            }
        }

        foreach ($requiredDirectory in $requiredDirectories) {
            if (-not ($entries | Where-Object { $_.StartsWith($requiredDirectory) })) {
                throw "Roku package is missing required entry: $requiredDirectory"
            }
        }
    } finally {
        $archive.Dispose()
    }

    return $true
}


# Assert the registry-recovery seed is actually inside the package that is about to be
# installed.
#
# source/restore.json is the ONLY thing that replays the owner's favourites after an
# install clears the userdata registry section -- which has happened (see rule 28). It is
# gitignored and reaches the package only because tar reads it off disk, so nothing in the
# repository proves it shipped. Test-RokuPackage deliberately does NOT list it in
# $requiredFiles: that would declare a clean clone of this public repo an invalid package
# for lacking a personal file. This is the right shape instead -- a separate, explicitly
# called check whose severity the caller chooses.
#
# -StorePath is the capture file Save-RokuStore wrote moments earlier. When it is given and
# the capture holds 1 or more favourites, the packaged seed's favourites must equal the
# capture's as LISTS, element by element in order (not only by count), so a stale seed (one
# deploy behind), a reordered one or one with the same count but other content is refused.
# When the capture holds NONE, the packaged seed may hold any array: either the previous seed
# that Update-RestoreSeed deliberately kept (used only if the registry is wiped) or an empty
# one, and the gate passes with a printed notice naming which. Without -StorePath only the
# old ">= 1 favourite" check is possible, and it is a warning: a bare count of one cannot
# tell a current seed from a stale one.
#
# -Required reflects whether the store gate actually ran. With -SkipStoreBackup the seed
# may legitimately be stale or absent, and refusing the install would take away the
# operator's last escape hatch at the exact moment they reached for it.
function Test-RokuPackageSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Required,
        [string]$StorePath = ""
    )

    # Read the capture first, outside any archive handle. If a StorePath was GIVEN it is
    # not optional: an unreadable capture throws whatever -Required says, because the
    # comparison it exists for cannot be made.
    $expectedFavorites = $null
    if ($StorePath) {
        if (-not (Test-Path -LiteralPath $StorePath -PathType Leaf)) {
            throw "Captured store file not found: $StorePath"
        }
        try {
            $capture = Get-Content -Raw -LiteralPath $StorePath | ConvertFrom-Json
        } catch {
            throw "Captured store file is not valid JSON: $($_.Exception.Message)"
        }
        if ($null -eq $capture -or $capture.favorites -isnot [System.Array]) {
            throw "Captured store file has no favorites array: $StorePath"
        }
        $expectedFavorites = @($capture.favorites)
    }

    $seedEntry = 'source/restore.json'
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry($seedEntry)
        if ($null -eq $entry) {
            $message = ("Roku package has no restore seed: $seedEntry is not in the " +
                        "package -- a registry wipe would be unrecoverable.")
            if ($Required) { throw $message }
            Write-Host "  WARNING: $message"
            return $false
        }

        $stream = $entry.Open()
        try {
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally {
            $stream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }

    try {
        $seed = $text | ConvertFrom-Json
        if ($null -eq $seed) { throw "the document is empty or null" }
    } catch {
        # Deliberately do not echo $text: ConvertFrom-Json already quotes the offending
        # document in its own message, and this file is the owner's personal channel list.
        $message = "Packaged restore seed is not valid JSON: $($_.Exception.Message)"
        if ($Required) { throw $message }
        Write-Host "  WARNING: $message"
        return $false
    }

    # Assert the TYPE, not just the count. PowerShell wraps a bare string into a
    # one-element array, so @($seed.favorites).Count answers 1 for BOTH ["A"] and "A" --
    # and the device-side reader calls .Count() on it, which an roString does not have.
    if ($seed.favorites -isnot [System.Array]) {
        # A missing key gives $null, and $null has no GetType(): name it explicitly.
        $shape = if ($null -eq $seed.favorites) { 'nothing (the key is missing or null)' } else { $seed.favorites.GetType().Name }
        $message = ("Packaged restore seed has a malformed favorites list: expected a " +
                    "JSON array, got $shape.")
        if ($Required) { throw $message }
        Write-Host "  WARNING: $message"
        return $false
    }

    if ($null -ne $expectedFavorites -and $expectedFavorites.Count -ge 1) {
        $got = @($seed.favorites)
        $expectedCount = $expectedFavorites.Count
        if ($got.Count -ne $expectedCount) {
            $message = ("Packaged restore seed has $($got.Count) favourites but the store " +
                        "captured from the TV has ${expectedCount}: the seed is stale or wrong, and " +
                        "after a registry wipe it would restore the wrong list.")
            if ($Required) { throw $message }
            Write-Host "  WARNING: $message"
            return $false
        }
        for ($idx = 0; $idx -lt $got.Count; $idx++) {
            if (-not ([string]$got[$idx] -ceq [string]$expectedFavorites[$idx])) {
                # Position only, never the name: the list is the owner's personal one.
                $message = ("Packaged restore seed has the same number of favourites ($expectedCount) as the " +
                            "store captured from the TV but differs from it at position $($idx + 1): the " +
                            "seed is stale, reordered or wrong, and after a registry wipe it would " +
                            "restore the wrong list.")
                if ($Required) { throw $message }
                Write-Host "  WARNING: $message"
                return $false
            }
        }
    } elseif ($null -ne $expectedFavorites) {
        # The TV reports no favourites. Update-RestoreSeed then keeps a previous seed that
        # holds some (or writes an empty one), so any array is acceptable here -- but say
        # which case this is, because the two mean different things after a wipe.
        if ($seed.favorites.Count -ge 1) {
            Write-Host ("  NOTICE: the TV reports no favourites; the packaged seed carries $($seed.favorites.Count) " +
                        "favourites from an earlier capture (kept on purpose) and would be used only if the " +
                        "registry is wiped.")
        } else {
            Write-Host "  NOTICE: the TV reports no favourites and the packaged seed is empty: nothing to restore."
        }
        return $true
    } elseif ($seed.favorites.Count -lt 1) {
        # No capture to compare with (only under -SkipStoreBackup): all that can be said is
        # that the seed is not empty, and even that is only a warning.
        Write-Host "  WARNING: Packaged restore seed carries no favourites (no capture to compare with)."
        return $false
    }

    Write-Host ("  Packaged seed: $($seed.favorites.Count) favourites, captured " +
                "$($seed.capturedAt)")
    return $true
}


# Classify the install server's response page. ORDER MATTERS and is the whole point:
# "Identical to previous version" is checked FIRST, because a page can carry it next to text
# that looks like success, and an install that did not change the package on the TV is not a
# deploy. Then "Install Failure", then "Install Success"; anything else is unrecognised and
# must be treated as a failure by the caller. Returns success|identical|failure|unrecognized.
function Get-RokuInstallVerdict {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Response)

    if ($null -eq $Response) { return 'unrecognized' }
    if ($Response -match 'Identical to previous version') { return 'identical' }
    if ($Response -match 'Install Failure') { return 'failure' }
    if ($Response -match 'Install Success') { return 'success' }
    return 'unrecognized'
}

# The one line of a curl config (-K -) that carries the digest credentials. The password
# goes to curl on STDIN as this config, never on the command line, where it would show in
# the process list. Inside a curl config a quoted value understands \\ and \" escapes, so
# both are escaped; a line break would end the option, so it is refused. Every other
# character (# space $ % ...) is literal inside the quotes.
function ConvertTo-CurlUserConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password
    )

    if ($User -match "[`r`n]" -or $Password -match "[`r`n]") {
        throw "The Roku password must not contain a line break."
    }
    $value = ($User + ':' + $Password).Replace('\', '\\').Replace('"', '\"')
    return ('user = "' + $value + '"')
}
