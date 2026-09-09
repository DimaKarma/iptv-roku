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
# -Required reflects whether the store gate actually ran. With -SkipStoreBackup the seed
# may legitimately be stale or absent, and refusing the install would take away the
# operator's last escape hatch at the exact moment they reached for it.
function Test-RokuPackageSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Required
    )

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
        $message = ("Packaged restore seed has a malformed favorites list: expected a " +
                    "JSON array, got $($seed.favorites.GetType().Name).")
        if ($Required) { throw $message }
        Write-Host "  WARNING: $message"
        return $false
    }

    if ($seed.favorites.Count -lt 1) {
        $message = "Packaged restore seed carries no favourites."
        if ($Required) { throw $message }
        Write-Host "  WARNING: $message"
        return $false
    }

    Write-Host ("  Packaged seed: $($seed.favorites.Count) favourites, captured " +
                "$($seed.capturedAt)")
    return $true
}
