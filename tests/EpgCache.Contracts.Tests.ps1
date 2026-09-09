# NOTE: this file is a SOURCE LINTER, not a behavioural test. It regex-matches the
# text of EpgTask.brs. It can go red for reformatting and it can NOT go red for wrong
# behaviour -- there is no BrightScript runtime here. A green run means "the source
# still says what we expect", never "the EPG path works". See AUDIT-2026-09-09.md A6.

$projectRoot = Split-Path -Parent $PSScriptRoot
$epgTaskPath = Join-Path $projectRoot 'components\tasks\EpgTask.brs'

Describe 'EPG cache contract' {
    It 'validates the EPG map before accepting network or cached JSON' {
        $epgTask = Get-Content -Raw $epgTaskPath

        $epgTask | Should Match 'function isUsableEpgPayload\(parsed as dynamic\) as boolean'
        ([regex]::Matches($epgTask, 'isUsableEpgPayload\(parsed\)')).Count | Should Be 2
    }

    It 'rejects a structurally valid but empty guide' {
        # A degenerate publish ({"count":0,"epg":{}}) passes every type check, and
        # without this it would overwrite a good cache with nothing.
        $epgTask = Get-Content -Raw $epgTaskPath

        $epgTask | Should Match 'parsed\.epg\.Count\(\) > 0'
    }

    It 'still falls back to the cache when the network path fails' {
        $epgTask = Get-Content -Raw $epgTaskPath

        $epgTask | Should Match "(?s)Fall back to the cache.*?if isUsableEpgPayload\(parsed\)"
    }

    It 'reports a reason on every failure path' {
        # EpgTask must populate `error` before `status`, because `status` is the field
        # MainScene observes -- see failEpg().
        $epgTask = Get-Content -Raw $epgTaskPath

        $epgTask | Should Match '(?s)sub failEpg\(reason as string\)\s+m\.top\.error = reason\s+m\.top\.status = "error"'
        ([regex]::Matches($epgTask, 'failEpg\(')).Count -ge 4 | Should Be $true
    }
}

# The old suite asserted `Should Not Match 'isEpgExpired|MAX_EPG_AGE|generated.*[<>]=?'`,
# forbidding any EPG staleness handling in this file. Removed deliberately:
#   * it was an architectural prohibition with no justification anywhere in the repo;
#   * its regex was far wider than that intent -- `generated.*[<>]=?` also fires on
#     merely reading the field defensively, e.g. `parsed.generated <> invalid`;
#   * a discard-on-age cutoff is genuinely the wrong fix (the generator's now-2h..+18h
#     window means a stale guide already renders blank), but the right fix -- showing
#     the guide's age -- would have tripped the same rule. Leaving a trap that the
#     current design only avoids by luck is worse than removing it on purpose.
# Guide age is now surfaced in MainScene.onEpgStatus / SettingsScreen About instead.
