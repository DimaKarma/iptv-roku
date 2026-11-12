# Moved here unchanged from BrightScript.Lint.Tests.ps1 (2026-11-12). Source-text
# contract tests over deploy.ps1, package.json, the manifest and two components.
# They are greps, not behaviour tests.

$projectRoot = Split-Path -Parent $PSScriptRoot

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

    It 'keeps the About version in step with the manifest' {
        # The version lives in two places: the manifest, which is what ECP and the Roku
        # home screen report, and a literal in the About text, which is what the owner
        # sees. They drifted once already - the manifest went to 1.0.0 while About still
        # said v0.1 - and nothing caught it but a screenshot. roAppInfo would remove the
        # duplication, but no code here uses that object and rule 20 shows some
        # CreateObject types fault on the render thread, so the duplication stays and
        # this test is what makes it safe.
        $manifest = Get-Content -Raw (Join-Path $projectRoot 'manifest')
        $major = [regex]::Match($manifest, 'major_version=(\d+)').Groups[1].Value
        $minor = [regex]::Match($manifest, 'minor_version=(\d+)').Groups[1].Value
        # Positive control: the manifest really was read and really has those keys.
        $major | Should Not BeNullOrEmpty
        $minor | Should Not BeNullOrEmpty

        $about = Get-Content -Raw (Join-Path $projectRoot 'components\SettingsScreen.brs')
        $shown = [regex]::Match($about, 'appVersion = "(\d+\.\d+)\.\d+"').Groups[1].Value
        $shown | Should Not BeNullOrEmpty
        $shown | Should Be "$major.$minor"
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
