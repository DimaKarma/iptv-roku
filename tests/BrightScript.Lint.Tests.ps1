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
    It 'seeds only when the WHOLE userdata section has no keys' {
        # RestoreStoreIfEmpty writes to the registry. The trigger is the only thing
        # stopping the shipped seed from overwriting what the user built up. It used to be
        # "this key's list is empty", which re-seeded a list the user had emptied on
        # purpose: an emptied list keeps its KEY, a wiped section has none.
        $store = Get-Content -Raw (Join-Path $projectRoot 'source\ChannelStore.brs')

        $store | Should Match '(?s)sub RestoreStoreIfEmpty\(\)'
        $body = [regex]::Match($store, '(?s)sub RestoreStoreIfEmpty\(\).*?end sub').Value
        $body | Should Not BeNullOrEmpty
        $body | Should Match 'GetKeyList\(\)'
        $body | Should Match 'keys = invalid or keys\.Count\(\) = 0'
        # The old per-key trigger must be gone.
        $body | Should Not Match 'cur = invalid or cur\.Count\(\) = 0'
    }

    It 'runs the seed before migration so the rest of the pass sees it' {
        $screen = Get-Content -Raw (Join-Path $projectRoot 'components\ChannelsScreen.brs')

        $screen | Should Match '(?s)RestoreStoreIfEmpty\(\)\s+MigrateStoreToNames'
    }
}
