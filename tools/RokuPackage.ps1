function Test-RokuPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Roku package was not created: $Path"
    }

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
        throw "Roku package is not a ZIP archive: $Path"
    }

    try {
        $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        $requiredFiles = @('manifest', 'config.json')
        $requiredDirectories = @('source/', 'components/', 'images/')

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
