# Compile-check the BrightScript and SceneGraph sources before they can be packaged.
#
# Until 2026-09-09 the only BrightScript compiler in this project was the Roku itself, so
# a syntax error was discovered by a FAILED INSTALL -- and a failed install is what wiped
# the device registry twice, taking the owner's favourites with it. `brighterscript` runs
# the same class of check locally in well under a second.
#
# READ THIS BEFORE TRUSTING A GREEN RUN. bsc is a second implementation of the grammar,
# not Roku's firmware compiler. Only one direction is sound:
#     bsc red   -> do not install.
#     bsc green -> says NOTHING about whether the Roku will accept the package.
# This project has been burned by exactly that inference before: twenty green linters, a
# clean XML parse and a 93-call findNode check were all green on code that would not
# compile. Treat this as one more filter, not as proof.
#
# What it demonstrably catches (mutation-proven on this tree): reserved words used as
# identifiers -- `pos = 0`, the bug that failed the 2026-09-09 install.
# What it does NOT catch: anything referenced by string, such as an observeField handler
# name or an XML onChange, and anything behavioural.

function Test-BrightScriptCompiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [int]$MinFiles = 25
    )

    $config = Join-Path $ProjectRoot 'bsconfig.json'
    if (-not (Test-Path -LiteralPath $config)) {
        throw "bsconfig.json not found at $config."
    }

    # Fail closed when the tool is absent. A check that silently passes because it could
    # not run is the anti-pattern this project keeps being bitten by, and auto-installing
    # is not the fix either: that would be a network fetch on the machine holding the dev
    # password and the subscription token.
    $bsc = Join-Path $ProjectRoot 'node_modules\brighterscript\dist\cli.js'
    if (-not (Test-Path -LiteralPath $bsc)) {
        throw ("The BrightScript compiler is not installed. Run 'npm ci' in " +
               "$ProjectRoot, or pass -SkipCompileCheck to deploy without it.")
    }
    $node = (Get-Command node -ErrorAction SilentlyContinue)
    if ($null -eq $node) {
        throw "node is not on PATH; the compile check cannot run. Install Node, or pass -SkipCompileCheck."
    }

    # Positive control. bsc exits 0 when its file globs match nothing, so a config typo
    # would read as a clean project. Count the files ourselves first.
    $counted = @(
        Get-ChildItem -Path (Join-Path $ProjectRoot 'source') -Filter *.brs -Recurse -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $ProjectRoot 'components') -Filter *.brs -Recurse -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $ProjectRoot 'components') -Filter *.xml -Recurse -ErrorAction SilentlyContinue
    ).Count
    if ($counted -lt $MinFiles) {
        throw ("Compile check aborted: found only $counted source files, expected at least " +
               "$MinFiles. The file set is wrong, so a clean result would mean nothing.")
    }

    Push-Location $ProjectRoot
    try {
        $output = & node $bsc --project bsconfig.json 2>&1 | ForEach-Object { $_.ToString() }
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    # Drop bsc's own timestamped progress lines; keep diagnostics.
    $diagnostics = $output | Where-Object { $_ -notmatch '^\[' -and $_.Trim() -ne '' }

    if ($code -ne 0) {
        Write-Host "  Compile check FAILED over $counted files:"
        $diagnostics | ForEach-Object { Write-Host "    $_" }
        return $false
    }

    Write-Host "  Compile check passed over $counted files (bsc reports no errors)."
    return $true
}
