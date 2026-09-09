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
