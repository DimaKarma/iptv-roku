$projectRoot = Split-Path -Parent $PSScriptRoot
$epgTaskPath = Join-Path $projectRoot 'components\tasks\EpgTask.brs'

Describe 'EPG cache contract' {
    It 'validates the EPG map before accepting network or cached JSON' {
        $epgTask = Get-Content -Raw $epgTaskPath

        $epgTask | Should Match 'function isUsableEpgPayload\(parsed as dynamic\) as boolean'
        ([regex]::Matches($epgTask, 'isUsableEpgPayload\(parsed\)')).Count | Should Be 2
    }

    It 'keeps valid cached EPG data available without an age cutoff' {
        $epgTask = Get-Content -Raw $epgTaskPath

        $epgTask | Should Match "' Error or timeout, try from cache[\s\S]*?if isUsableEpgPayload\(parsed\)"
        $epgTask | Should Not Match 'isEpgExpired|MAX_EPG_AGE|generated.*[<>]=?'
    }
}
