# Keep the bytes that were installed, and a record of what they were.
#
# Two gaps this closes. First, deploy.ps1 deletes the old package before building the new
# one, so there has never been a rollback target on this machine: at the time this was
# written the only zip on disk was two months old, from a build that is not what the TV is
# running. Second, nothing recorded WHICH build went to the device -- the manifest reports
# 0.1.1 for every build ever made, so the version string cannot answer it and the only
# value that exists on both the host and the box is the package md5, which the device
# reports back in its install response and nobody was reading.
#
# Everything here is best-effort by design. An archiving convenience must never turn a
# successful install into a failed deploy, so the whole body is wrapped and any failure is
# a warning.

function Save-DeployRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$Response = "",
        [string]$StorePath = ""
    )

    try {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')

        $localMd5 = (Get-FileHash -Algorithm MD5 -LiteralPath $ZipPath).Hash.ToLower()
        $size = (Get-Item -LiteralPath $ZipPath).Length

        # What the device says it stored. This is the only value measurable on both sides,
        # which is exactly why it is recorded and NOT gated on: identical bytes produce an
        # identical md5, so a mismatch check would pass by construction in the no-op case
        # it would exist to catch -- and one press of "Convert to squashfs" on the device's
        # own web UI would make it fail permanently with a wrong diagnosis.
        $deviceMd5 = ""
        $deviceSize = ""
        if ($Response) {
            $m = [regex]::Match($Response, '"md5"\s*:\s*"([0-9a-fA-F]{32})"')
            if ($m.Success) { $deviceMd5 = $m.Groups[1].Value.ToLower() }
            $s = [regex]::Match($Response, '"size"\s*:\s*"(\d+)"')
            if ($s.Success) { $deviceSize = $s.Groups[1].Value }
        }

        # The commit alone is not enough: this tree is packaged from DISK, not from git,
        # so a dirty tree means the installed bytes are not the commit's bytes.
        $head = ""
        $dirty = $true
        try {
            $head = (& git -C $ProjectRoot rev-parse HEAD).Trim()
            $porcelain = & git -C $ProjectRoot status --porcelain
            $dirty = -not [string]::IsNullOrWhiteSpace(($porcelain -join ""))
        } catch {
            $head = "unavailable"
        }

        $shortSha = if ($head.Length -ge 7) { $head.Substring(0, 7) } else { "nogit" }

        # Archive the package INSIDE the success path only. Copying it before the build
        # would stamp the previous deploy's bytes with this deploy's commit, and would
        # also preserve packages the device REJECTED -- the opposite of a rollback target.
        $buildsDir = Join-Path $ProjectRoot 'builds'
        if (-not (Test-Path -LiteralPath $buildsDir)) {
            New-Item -ItemType Directory -Path $buildsDir -Force | Out-Null
        }
        $archived = Join-Path $buildsDir "build-$stamp-$shortSha-$($localMd5.Substring(0,8)).zip"
        Copy-Item -LiteralPath $ZipPath -Destination $archived -Force

        # Keep the last five. Names begin with a UTC stamp, so lexical order is chronological.
        $kept = @(Get-ChildItem -LiteralPath $buildsDir -Filter 'build-*.zip' |
                  Sort-Object Name -Descending)
        if ($kept.Count -gt 5) {
            $kept[5..($kept.Count - 1)] | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
        }

        $storeName = ""
        if ($StorePath -and (Test-Path -LiteralPath $StorePath)) {
            $storeName = Split-Path $StorePath -Leaf
        }

        # Gate verdicts are deliberately NOT recorded: every gate exits 1 on failure, so a
        # record can only ever exist with all of them passed. A field that cannot vary is
        # not evidence.
        $record = [ordered]@{
            installedAt   = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
            package       = Split-Path $archived -Leaf
            localMd5      = $localMd5
            deviceMd5     = $deviceMd5
            localSize     = $size
            deviceSize    = $deviceSize
            gitHead       = $head
            gitTreeDirty  = $dirty
            storeCapture  = $storeName
        }

        $backupsDir = Join-Path $ProjectRoot 'backups'
        if (-not (Test-Path -LiteralPath $backupsDir)) {
            New-Item -ItemType Directory -Path $backupsDir -Force | Out-Null
        }
        $recordPath = Join-Path $backupsDir "deploy-$stamp.json"
        $json = ($record | ConvertTo-Json -Depth 3)
        # No BOM: PS 5.1's Out-File -Encoding utf8 writes one and a strict parser rejects it.
        [System.IO.File]::WriteAllText($recordPath, $json,
            (New-Object System.Text.UTF8Encoding($false)))

        Write-Host "  Archived package: $(Split-Path $archived -Leaf)"
        if ($deviceMd5 -and $deviceMd5 -ne $localMd5) {
            Write-Host "  NOTE: the device reports a different md5 ($deviceMd5) than the file sent."
        }
        if ($dirty) {
            Write-Host "  NOTE: the working tree was dirty, so these bytes are not $shortSha's bytes."
        }
    } catch {
        Write-Host "  (deploy record not written: $($_.Exception.Message))"
    }
}
