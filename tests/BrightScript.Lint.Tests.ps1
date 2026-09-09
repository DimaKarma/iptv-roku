# A SOURCE LINTER for the one class of defect nothing else here can see.
#
# There is no BrightScript compiler on this machine: a syntax error is invisible until
# the Roku rejects the package at install time. On 2026-09-09 a deploy failed with
#   Syntax Error. Builtin function call expected. (compile error &h9d)
# because a local variable was named `pos`.
#
# The reserved set is exactly TWO names, not "all builtins". `Pos()` and `Tab()` are the
# print-statement positioning functions, so the parser expects an opening parenthesis
# after them and `pos = 0` cannot parse. Ordinary builtins are fine as variable names --
# `source\ChannelStore.brs` assigns to `val` and has been running on the TV for months.
# Keeping the list at two is deliberate: a broader list would flag `val` and cry wolf.

$projectRoot = Split-Path -Parent $PSScriptRoot
$brsFiles = @(
    Get-ChildItem -Path (Join-Path $projectRoot 'source') -Filter *.brs -Recurse
    Get-ChildItem -Path (Join-Path $projectRoot 'components') -Filter *.brs -Recurse
)

Describe 'BrightScript reserved-name lint' {
    It 'scans every .brs in the package' {
        # Without this the next test would pass by reading nothing at all.
        $brsFiles.Count -ge 12 | Should Be $true
    }

    It 'never assigns to pos or tab' {
        $offences = @()
        foreach ($f in $brsFiles) {
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                $n++
                $code = ($line -split "'")[0]
                if ($code -match '^\s*(pos|tab)\s*=[^=]') {
                    $offences += ("{0}:{1}" -f $f.Name, $n)
                }
            }
        }
        ($offences -join ', ') | Should BeNullOrEmpty
    }
}

Describe 'Registry seed contract' {
    It 'seeds a key only when that key is empty' {
        # RestoreStoreIfEmpty writes to the registry. The emptiness guard is the only
        # thing stopping the shipped seed from overwriting a list the user built up.
        $store = Get-Content -Raw (Join-Path $projectRoot 'source\ChannelStore.brs')

        $store | Should Match '(?s)sub RestoreStoreIfEmpty\(\)'
        ([regex]::Matches($store, 'if cur = invalid or cur\.Count\(\) = 0')).Count | Should Be 2
    }

    It 'runs the seed before migration so the rest of the pass sees it' {
        $screen = Get-Content -Raw (Join-Path $projectRoot 'components\ChannelsScreen.brs')

        $screen | Should Match '(?s)RestoreStoreIfEmpty\(\)\s+MigrateStoreToNames'
    }
}

Describe 'Deploy gates contract' {
    # These assert the SHAPE of deploy.ps1, because a gate that is quietly deleted leaves
    # a green suite behind it. Cheap insurance on the two checks that stand between a
    # syntax error and a wiped registry.
    It 'compile-checks before it packages or contacts the TV' {
        $deploy = Get-Content -Raw (Join-Path $projectRoot 'deploy.ps1')

        $deploy | Should Match 'Test-BrightScriptCompiles'
        # Order matters: the compile check must come before tar.exe and before curl.
        $iCompile = $deploy.IndexOf('Test-BrightScriptCompiles')
        $iTar = $deploy.IndexOf('tar.exe')
        $iCurl = $deploy.IndexOf('curl.exe')
        ($iCompile -lt $iTar -and $iCompile -lt $iCurl) | Should Be $true
    }

    It 'captures the store and refreshes the seed BEFORE packaging' {
        # Built first and captured second, the shipped source/restore.json was always one
        # deploy stale, so a registry wipe restored last time's favourites.
        $deploy = Get-Content -Raw (Join-Path $projectRoot 'deploy.ps1')

        $iSave = $deploy.IndexOf('Save-RokuStore')
        $iSeed = $deploy.IndexOf('Update-RestoreSeed')
        $iTar = $deploy.IndexOf('tar.exe')
        ($iSave -gt 0 -and $iSeed -gt $iSave -and $iSeed -lt $iTar) | Should Be $true
    }

    It 'pins the compiler version rather than floating it' {
        $pkg = Get-Content -Raw (Join-Path $projectRoot 'package.json') | ConvertFrom-Json
        $pkg.devDependencies.brighterscript | Should Match '^\d+\.\d+\.\d+$'
    }

    It 'dispatches the error menu by action, never by a hardcoded index' {
        # The error dialog's menu is VARIABLE LENGTH -- the favourite row is built only for
        # a channel that already is one. An index-based dispatch therefore moves "Back"
        # from 3 to 2 whenever that row is absent: Back stops working and index 2 toggles
        # favourites on a channel that has none.
        #
        # What this test can and cannot do: it greps the source, so it goes red only if
        # someone reintroduces the literal-index shape. It proves nothing about runtime
        # behaviour, and a reformat could evade it. It exists because this defect is
        # invisible in a screenshot and expensive to reach on the device -- it needs a dead
        # stream that is also a favourite.
        $player = Get-Content -Raw (Join-Path $projectRoot 'components\PlayerScreen.brs')

        $player | Should Match 'm\.errorActions'
        # Positive control: the file really was read and the matcher really can hit.
        $player | Should Match 'sub onErrorOptionSelected'

        $dispatch = $player.Substring($player.IndexOf('sub onErrorOptionSelected'))
        $dispatch = $dispatch.Substring(0, $dispatch.IndexOf('end sub'))
        ($dispatch -match 'idx\s*=\s*\d') | Should Be $false
    }
}
