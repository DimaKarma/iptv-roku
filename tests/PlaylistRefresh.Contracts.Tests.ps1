# NOTE: this file is a SOURCE LINTER, not a behavioural test -- it regex-matches the
# text of .brs/.xml sources. It cannot go red for wrong behaviour. See AUDIT A6.

$projectRoot = Split-Path -Parent $PSScriptRoot
$taskXmlPath = Join-Path $projectRoot 'components\tasks\PlaylistTask.xml'
$taskSourcePath = Join-Path $projectRoot 'components\tasks\PlaylistTask.brs'
$sceneSourcePath = Join-Path $projectRoot 'components\MainScene.brs'

Describe 'Manual playlist refresh contract' {
    It 'exposes a forceReload input on PlaylistTask' {
        [xml]$taskXml = Get-Content -Raw $taskXmlPath
        $fieldIds = @($taskXml.component.interface.field | ForEach-Object { $_.id })

        ($fieldIds -contains 'forceReload') | Should Be $true
    }

    It 'skips conditional cache headers when forceReload is true' {
        $taskSource = Get-Content -Raw $taskSourcePath

        $taskSource | Should Match '(?s)if not m\.top\.forceReload\s+and meta <> invalid.*?http\.AddHeader\("If-None-Match"'
    }

    It 'forces a reload for Refresh and for Clear cache, and for nothing else' {
        $sceneSource = Get-Content -Raw $sceneSourcePath

        # startPlaylistLoad(url, forceReload, clearCache). Clear cache implies a forced
        # reload AND asks the task to delete the cache files.
        $sceneSource | Should Match '(?s)if action = "refresh"\s+startPlaylistLoad\(m\.currentUrl, true, false\)'
        $sceneSource | Should Match '(?s)else if action = "clearCache"\s+(\x27[^\r\n]*\s+)*startPlaylistLoad\(m\.currentUrl, true, true\)'
        $sceneSource | Should Match 'sub startPlaylistLoad\(url as string, forceReload as boolean, clearCache as boolean\)'
        # No call site may still use the two-argument form.
        $sceneSource | Should Not Match 'startPlaylistLoad\([^,()]+,\s*(true|false)\)'
    }

    It 'exposes a clearCache input on PlaylistTask and runs it as the first step' {
        [xml]$taskXml = Get-Content -Raw $taskXmlPath
        $fieldIds = @($taskXml.component.interface.field | ForEach-Object { $_.id })
        ($fieldIds -contains 'clearCache') | Should Be $true

        $taskSource = Get-Content -Raw $taskSourcePath
        $taskSource | Should Match '(?s)sub runPlaylist\(\)\s+(\x27[^\r\n]*\s+)*if m\.top\.clearCache then clearCacheFiles\(\)'
        $taskSource | Should Match '\[CACHE\] cleared playlist='
    }
}

Describe 'Repeatable Settings actions contract' {
    It 'fires Settings actions off a toggle, not off the action string' {
        # A field observer only fires on CHANGE, so observing the string made every
        # repeat of the same action a silent no-op -- only the first Refresh of a
        # session did anything.
        $sceneSource = Get-Content -Raw $sceneSourcePath

        $sceneSource | Should Match 'observeField\("actionCommand", "onSettingsAction"\)'
        $sceneSource | Should Not Match 'observeField\("action", "onSettingsAction"\)'
    }

    It 'funnels every action write through sendAction' {
        # The invariant that keeps payload-before-trigger ordering in one place:
        # exactly one assignment to m.top.action in the file, inside sendAction.
        $settingsSource = Get-Content -Raw (Join-Path $projectRoot 'components\SettingsScreen.brs')

        $settingsSource | Should Match '(?s)sub sendAction\(name as string\)\s+m\.top\.action = name\s+m\.top\.actionCommand = not m\.top\.actionCommand'
        ([regex]::Matches($settingsSource, 'm\.top\.action = ')).Count | Should Be 1
        ([regex]::Matches($settingsSource, 'sendAction\("')).Count | Should Be 4
        # Four, and none of them from the Diagnostics row: opening it must not go
        # through sendAction. Two literal calls in the dispatch (refresh, clearCache) and
        # two in the keyboard save path (epgChanged, urlChanged).
        $settingsSource | Should Match 'sendAction\("refresh"\)'
        $settingsSource | Should Match 'sendAction\("clearCache"\)'
        $settingsSource | Should Match 'sendAction\("epgChanged"\)'
        $settingsSource | Should Match 'sendAction\("urlChanged"\)'
        $dispatch = [regex]::Match($settingsSource, '(?s)sub onItemSelected\(\).*?end sub').Value
        $diagBranch = [regex]::Match($dispatch, '(?s)else if act = "diagnostics"(.*?)else if act = "about"').Groups[1].Value
        $diagBranch | Should Not BeNullOrEmpty
        $diagBranch | Should Not Match 'sendAction'
        $diagBranch | Should Match 'openDiagnostics\(\)'
    }

    It 'declares actionCommand on the SettingsScreen interface' {
        [xml]$settingsXml = Get-Content -Raw (Join-Path $projectRoot 'components\SettingsScreen.xml')
        $fieldIds = @($settingsXml.component.interface.field | ForEach-Object { $_.id })

        ($fieldIds -contains 'actionCommand') | Should Be $true
        ($fieldIds -contains 'noticeCommand') | Should Be $true
    }
}
