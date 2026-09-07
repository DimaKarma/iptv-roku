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

    It 'sets forceReload only for the manual refresh action' {
        $sceneSource = Get-Content -Raw $sceneSourcePath

        $sceneSource | Should Match '(?s)if action = "refresh"\s+startPlaylistLoad\(m\.currentUrl, true\)'
        $sceneSource | Should Match '(?s)else if action = "clearCache"\s+startPlaylistLoad\(m\.currentUrl, false\)'
    }
}
