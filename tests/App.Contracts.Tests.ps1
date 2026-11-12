# NOTE: this file is a SOURCE LINTER, not a behavioural test. Every assertion is a grep
# (regex or byte scan) over the text of the .brs / .xml / manifest sources. It cannot go
# red for wrong behaviour, only for the text changing; there is no BrightScript runtime on
# this machine. A green run means "the source still says what the 1.1.0 plan expects".
# Pester 3.4 syntax (Should Be / Should Match) on purpose.

$projectRoot = Split-Path -Parent $PSScriptRoot
$taskBrs = Join-Path $projectRoot 'components\tasks\PlaylistTask.brs'
$taskXml = Join-Path $projectRoot 'components\tasks\PlaylistTask.xml'
$searchXml = Join-Path $projectRoot 'components\SearchScreen.xml'
$translit = Join-Path $projectRoot 'source\Translit.brs'
$settingsBrs = Join-Path $projectRoot 'components\SettingsScreen.brs'
$playerBrs = Join-Path $projectRoot 'components\PlayerScreen.brs'
$channelsBrs = Join-Path $projectRoot 'components\ChannelsScreen.brs'
$mainBrs = Join-Path $projectRoot 'components\MainScene.brs'
$cardBrs = Join-Path $projectRoot 'components\ChannelCard.brs'
$storeBrs = Join-Path $projectRoot 'source\ChannelStore.brs'

# Source text with the BrightScript comments removed, so a comment that names a function
# cannot satisfy or break a test that is about the code.
function Get-BrsCode([string]$text) {
    return ((($text -split "`n") | ForEach-Object { ($_ -split "'")[0] }) -join "`n")
}
function Get-BrsBody([string]$text, [string]$signature) {
    return [regex]::Match($text, '(?s)' + $signature + '.*?\r?\nend (sub|function)').Value
}

Describe 'PlaylistTask contract (W1-2, W1-9)' {
    It 'checks the MAIN parse for at least one channel BEFORE merging extras' {
        $src = Get-Content -Raw $taskBrs
        $iCheck = $src.IndexOf('parsed.channels.Count() < 1')
        $iExtras = $src.IndexOf('extras = m.top.extraPlaylists')
        $iCheck | Should BeGreaterThan 0
        $iExtras | Should BeGreaterThan 0
        ($iCheck -lt $iExtras) | Should Be $true
        # and it takes the cache-fallback path rather than writing anything
        $src | Should Match '(?s)parsed\.channels\.Count\(\) < 1.*?fallbackToCache\(.*?return\s+end if'
    }

    It 'sets status = error on the 304 path when the cache cannot be loaded' {
        $src = Get-Content -Raw $taskBrs
        $branch = [regex]::Match($src, '(?s)else if respCode = 304(.*?)\r?\n    else\r?\n').Groups[1].Value
        $branch | Should Not BeNullOrEmpty
        $branch | Should Match 'if not loadFromCache\("ok"\)'
        $branch | Should Match 'm\.top\.status = "error"'
        $branch | Should Match 'm\.top\.error = '
    }

    It 'falls back to the cached channels of an extra category that failed' {
        $src = Get-Content -Raw $taskBrs
        # inside runPlaylist itself: loadFromCache has its own readCachedResult call
        $run = [regex]::Match($src, '(?s)sub runPlaylist\(\).*?\r?\nend sub').Value
        $run | Should Not BeNullOrEmpty
        $run | Should Match 'cached = readCachedResult\(\)'
        $run | Should Match 'if cch\.group = exCat'
    }

    It 'builds categories in one function and the skeletons before it' {
        $src = Get-Content -Raw $taskBrs
        ([regex]::Matches($src, 'function BuildCategoryList\(')).Count | Should Be 1
        $src | Should Match '(?s)AddSkeletons\(parsed\.channels\)\s+built = BuildCategoryList\(parsed\.channels\)'
    }
}

Describe 'Registry seed trigger (W1-3)' {
    It 'RestoreStoreIfEmpty reads GetKeyList' {
        $store = Get-Content -Raw (Join-Path $projectRoot 'source\ChannelStore.brs')
        $body = [regex]::Match($store, '(?s)sub RestoreStoreIfEmpty\(\).*?end sub').Value
        $body | Should Not BeNullOrEmpty
        $body | Should Match 'sec\.GetKeyList\(\)'
    }
}

Describe 'SettingsScreen (W1-1, Diagnostics)' {
    It 'contains no roFileSystem (rule 20: the deletion moved to PlaylistTask)' {
        $src = Get-Content -Raw $settingsBrs
        $src.Length -gt 1000 | Should Be $true     # positive control: the file was read
        $src | Should Not Match 'roFileSystem'
    }

    It 'dispatches the rows by action, never by a literal row number' {
        $src = Get-Content -Raw $settingsBrs
        $dispatch = [regex]::Match($src, '(?s)sub onItemSelected\(\).*?end sub').Value
        $dispatch | Should Not BeNullOrEmpty
        $dispatch | Should Match 'actionAt\('
        ($dispatch -match 'idx\s*=\s*\d') | Should Be $false
        $src | Should Match 'm\.settingsActions\.Push\(action\)'
    }

    It 'makes Diagnostics the LAST row' {
        $src = Get-Content -Raw $settingsBrs
        $build = [regex]::Match($src, '(?s)sub buildList\(\).*?end sub').Value
        $items = [regex]::Matches($build, 'addItem\(content, "([^"]+)", "([^"]+)"\)')
        $items.Count -ge 6 | Should Be $true
        $items[$items.Count - 1].Groups[2].Value | Should Be 'diagnostics'
    }

    It 'creates the Diagnostics screen by string, only on selection' {
        $src = Get-Content -Raw $settingsBrs
        $src | Should Match 'CreateObject\("roSGNode", "DiagnosticsScreen"\)'
        $init = [regex]::Match($src, '(?s)sub init\(\).*?\r?\nend sub').Value
        $init | Should Not Match 'DiagnosticsScreen'
        foreach ($f in Get-ChildItem -Path (Join-Path $projectRoot 'components') -Filter *.xml -Recurse) {
            (Get-Content -Raw $f.FullName) | Should Not Match '<\s*DiagnosticsScreen\b'
        }
    }
}

Describe 'Translit and Search wiring (S1)' {
    It 'is included by both PlaylistTask.xml and SearchScreen.xml' {
        (Get-Content -Raw $taskXml) | Should Match 'pkg:/source/Translit\.brs'
        (Get-Content -Raw $searchXml) | Should Match 'pkg:/source/Translit\.brs'
    }

    It 'Translit.brs contains no byte above 0x7F (no Cyrillic in the tree)' {
        $bytes = [System.IO.File]::ReadAllBytes($translit)
        $bytes.Length -gt 500 | Should Be $true    # positive control: the file was read
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
    }

    It 'defines NameSkeleton and builds the table from code points' {
        $src = Get-Content -Raw $translit
        $src | Should Match 'function NameSkeleton\(s as dynamic\) as string'
        $src | Should Match '&h410'
        $src | Should Match '&h430'
    }

    It 'the search field is not a stock Button and the hint paragraph is gone' {
        $xml = Get-Content -Raw $searchXml
        $xml | Should Not Match '<Button\b'
        $xml | Should Not Match 'id="hintLabel"'
        $xml | Should Match 'numColumns="5"'
    }
}

Describe 'No static MiniKeyboard / DynamicCustomKeyboard (rule 8 probe only)' {
    It 'no component XML declares them as a child' {
        $files = @(Get-ChildItem -Path (Join-Path $projectRoot 'components') -Filter *.xml -Recurse)
        $files.Count -ge 10 | Should Be $true      # positive control
        foreach ($f in $files) {
            (Get-Content -Raw $f.FullName) | Should Not Match '<\s*(MiniKeyboard|DynamicCustomKeyboard)\b'
        }
    }
}

Describe 'Player timers (W1-7, W1-8) and focus order (W1-6)' {
    It 'arm and disarm are named subs called from the places the plan lists' {
        $src = Get-Content -Raw $playerBrs
        foreach ($name in 'armStallWatchdog', 'disarmStallWatchdog', 'armRecentTimer', 'disarmRecentTimer') {
            ([regex]::Matches($src, "sub $name\(")).Count | Should Be 1
        }
        # playIndex arms the 20 s watchdog and re-arms nothing else
        $play = [regex]::Match($src, '(?s)sub playIndex\(idx as integer\).*?\r?\nend sub').Value
        $play | Should Match 'armStallWatchdog\(20\.0\)'
        $play | Should Match 'disarmRecentTimer\(\)'
        $play | Should Not Match 'PushRecent'
        # playing disarms the watchdog and arms the recent timer; buffering after playing re-arms at 30 s
        $state = [regex]::Match($src, '(?s)sub onVideoStateChange\(\).*?\r?\nend sub').Value
        $state | Should Match 'if m\.hasPlayed then armStallWatchdog\(30\.0\)'
        $state | Should Match '(?s)state = "playing".*?disarmStallWatchdog\(\).*?armRecentTimer\(\)'
        $state | Should Match 'state = "finished"'
        # exit stops both
        $exit = [regex]::Match($src, '(?s)sub exitPlayer\(\).*?\r?\nend sub').Value
        $exit | Should Match 'disarmStallWatchdog\(\)'
        $exit | Should Match 'disarmRecentTimer\(\)'
        # the fire handler stops the video before the dialog
        $src | Should Match '(?s)sub onStallTimeout\(\)\s+m\.video\.control = "stop"\s+failPlayback\('
        # the dialog stops the watchdog
        $dlg = [regex]::Match($src, '(?s)sub showErrorDialog\(reason as string\).*?\r?\nend sub').Value
        $dlg | Should Match 'disarmStallWatchdog\(\)'
    }

    It 'closeZapper runs BEFORE the error list takes focus' {
        $src = Get-Content -Raw $playerBrs
        $dlg = [regex]::Match($src, '(?s)sub showErrorDialog\(reason as string\).*?\r?\nend sub').Value
        # comments stripped: the explanation in the sub also names closeZapper()
        $code = (($dlg -split "`n") | ForEach-Object { ($_ -split "'")[0] }) -join "`n"
        $iClose = $code.IndexOf('closeZapper()')
        $iFocus = $code.IndexOf('m.errorOptions.setFocus(true)')
        $iClose | Should BeGreaterThan 0
        $iFocus | Should BeGreaterThan 0
        ($iClose -lt $iFocus) | Should Be $true
    }

    It 'acts on an OK release only when the press was seen here (ChannelsScreen, PlayerScreen)' {
        foreach ($name in 'ChannelsScreen', 'PlayerScreen') {
            $src = Get-Content -Raw (Join-Path $projectRoot "components\$name.brs")
            $src | Should Match 'm\.okArmed = true'
            $src | Should Match 'm\.okArmed and '
            $src | Should Match 'm\.okArmed = false'
        }
    }
}

Describe 'Player inactive guard (error dialog Back must not favourite the dead channel)' {
    It 'onOkLongPress returns before ToggleFavorite unless the player is active and no overlay is open' {
        $src = Get-Content -Raw $playerBrs
        $body = [regex]::Match($src, '(?s)sub onOkLongPress\(\).*?\r?\nend sub').Value
        $body | Should Not BeNullOrEmpty
        $iGuard = $body.IndexOf('if m.active <> true or m.errorDialog.visible or m.zapperPanel.visible then return')
        $iToggle = $body.IndexOf('ToggleFavorite(')
        $iGuard | Should BeGreaterThan 0
        $iToggle | Should BeGreaterThan 0
        ($iGuard -lt $iToggle) | Should Be $true
    }

    It 'onKeyEvent does not arm okTimer on an OK press while the player is not active' {
        $src = Get-Content -Raw $playerBrs
        $iGuard = $src.IndexOf('if m.active <> true then return true')
        $iArm = $src.IndexOf('m.okArmed = true')
        $iGuard | Should BeGreaterThan 0
        $iArm | Should BeGreaterThan 0
        ($iGuard -lt $iArm) | Should Be $true
        # the guard sits inside onKeyEvent, not in some earlier sub
        $iKey = $src.IndexOf('function onKeyEvent(')
        ($iKey -lt $iGuard) | Should Be $true
    }

    It 'm.active is set true in playIndex (retry and zap go through it) and false in exitPlayer' {
        $src = Get-Content -Raw $playerBrs
        $play = [regex]::Match($src, '(?s)sub playIndex\(idx as integer\).*?\r?\nend sub').Value
        $exit = [regex]::Match($src, '(?s)sub exitPlayer\(\).*?\r?\nend sub').Value
        $play | Should Match 'm\.active = true'
        $exit | Should Match 'm\.active = false'
    }
}

Describe 'Version (manifest and About agree)' {
    It 'the manifest triple equals the About appVersion literal' {
        $manifest = Get-Content -Raw (Join-Path $projectRoot 'manifest')
        $major = [regex]::Match($manifest, '(?m)^major_version=(\d+)\s*$').Groups[1].Value
        $minor = [regex]::Match($manifest, '(?m)^minor_version=(\d+)\s*$').Groups[1].Value
        $build = [regex]::Match($manifest, '(?m)^build_version=(\d+)\s*$').Groups[1].Value
        # positive control: all three parts were read, so an empty read cannot match an empty read
        $major | Should Match '^\d+$'
        $minor | Should Match '^\d+$'
        $build | Should Match '^\d+$'
        $about = Get-Content -Raw $settingsBrs
        $shown = [regex]::Match($about, '(?m)^\s*appVersion = "(\d+\.\d+\.\d+)"\s*$').Groups[1].Value
        $shown | Should Match '^\d+\.\d+\.\d+$'
        $shown | Should Be ($major + '.' + $minor + '.' + $build)
    }
}

Describe 'Audit fixes B2 (skeleton cache, finished guard, OK timer, diag hide)' {
    It 'Translit caches the Cyrillic table on m.skTbl' {
        $src = Get-Content -Raw $translit
        $src | Should Match 'if m\.skTbl = invalid then m\.skTbl = skCyrillicTable\(\)'
        $src | Should Match 'tbl = m\.skTbl'
    }

    It 'PlaylistTask prints the skeleton timing' {
        $src = Get-Content -Raw $taskBrs
        $src | Should Match 'skeletons ms='
    }

    It 'the finished branch of onVideoStateChange consults m.hasPlayed' {
        $src = Get-Content -Raw $playerBrs
        $fin = [regex]::Match($src, '(?s)else if state = "finished"(.*?)\r?\n    end if').Groups[1].Value
        $fin | Should Not BeNullOrEmpty
        $fin | Should Match 'if not m\.hasPlayed then return'
    }

    It 'showErrorDialog openZapper and exitPlayer stop okTimer and clear okArmed' {
        $src = Get-Content -Raw $playerBrs
        foreach ($sig in 'sub showErrorDialog\(reason as string\)', 'sub openZapper\(\)', 'sub exitPlayer\(\)') {
            $body = [regex]::Match($src, "(?s)$sig.*?\r?\nend sub").Value
            $body | Should Not BeNullOrEmpty
            $body | Should Match 'm\.okTimer\.control = "stop"'
            $body | Should Match 'm\.okArmed = false'
        }
    }

    It 'SettingsScreen hides m.diag when the screen is shown' {
        $src = Get-Content -Raw $settingsBrs
        $body = [regex]::Match($src, '(?s)sub onVisibleChange\(\).*?\r?\nend sub').Value
        $body | Should Match 'if m\.diag <> invalid then m\.diag\.visible = false'
    }
}

Describe 'Palette contract (teal and signal-orange recolour)' {
    $themeFile = Join-Path $projectRoot 'source\Theme.brs'
    $manifestFile = Join-Path $projectRoot 'manifest'
    $oldLiterals = @('0E1310', '18211C', '212C26', '2A362F', '4FB03A', '74D45B', '08130A',
        'ECF2EE', '8A968E', 'D9584F', '57C140', '5FD345',
        '2F6E4E', '3C6E86', '6E7D3A', '7A5C3E', '4E6E6E', '5B4E7A', '6E3E4E', '3E7A66')

    It 'Theme.brs carries the eleven new palette values and the colorInfo key' {
        $src = Get-Content -Raw $themeFile
        $expected = [ordered]@{
            colorBg = '020B13'; colorSurface = '062230'; colorSurfaceHi = '0E3442'
            colorLine = '1D4551'; colorFocus = 'D5401A'; colorFocusBright = 'FF5A2B'
            colorOnAccent = 'FFFFFF'; colorInfo = '60BBD2'; colorText = 'DCE9EE'
            colorTextDim = '86A6B1'; colorError = 'FBA60B'
        }
        foreach ($k in $expected.Keys) {
            $src | Should Match ('(?m)^\s*' + $k + ':\s*"0x' + $expected[$k] + 'FF",')
        }
    }

    It 'no file under components or Theme.brs still contains an old palette literal' {
        $files = @(Get-ChildItem -Path (Join-Path $projectRoot 'components') -Recurse -Include *.xml, *.brs) + @(Get-Item $themeFile)
        $files.Count | Should BeGreaterThan 10
        $hits = @()
        foreach ($f in $files) {
            $txt = Get-Content -Raw $f.FullName
            foreach ($lit in $oldLiterals) {
                if ($txt.IndexOf($lit, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits += ($f.Name + ' ' + $lit) }
            }
        }
        ($hits -join '; ') | Should Be ''
    }

    It 'every focusBitmapBlendColor is one of the two new blend values' {
        $n = 0
        foreach ($f in Get-ChildItem -Path (Join-Path $projectRoot 'components') -Recurse -Include *.xml) {
            $txt = Get-Content -Raw $f.FullName
            foreach ($m in [regex]::Matches($txt, 'focusBitmapBlendColor="([^"]*)"')) {
                $n++
                ($m.Groups[1].Value -eq '0xEB461DFF' -or $m.Groups[1].Value -eq '0xFF4D1FFF') | Should Be $true
            }
        }
        $n | Should BeGreaterThan 5
    }

    It 'manifest splash_color is the new background' {
        (Get-Content -Raw $manifestFile) | Should Match '(?m)^splash_color=#020B13\s*$'
    }
}

Describe 'Resume last channel (1.2.0)' {
    It 'writes the resume channel from exactly one place: onRecentTimer, with m.recentName' {
        $files = @(Get-ChildItem -Path (Join-Path $projectRoot 'components') -Filter *.brs -Recurse)
        $files.Count -ge 10 | Should Be $true      # positive control: the sources were read
        $calls = @()
        foreach ($f in $files) {
            $code = Get-BrsCode (Get-Content -Raw $f.FullName)
            foreach ($m in [regex]::Matches($code, 'SaveLastChannel\(([^)]*)\)')) {
                $calls += ($f.Name + '|' + $m.Groups[1].Value.Trim())
            }
        }
        @($calls).Count | Should Be 1
        $calls[0] | Should Be 'PlayerScreen.brs|m.recentName'
        $timer = Get-BrsCode (Get-BrsBody (Get-Content -Raw $playerBrs) 'sub onRecentTimer\(\)')
        $timer | Should Match 'SaveLastChannel\(m\.recentName\)'
    }

    It 'playIndex clears the resume channel inside its IsAdultGroup branch, and only there' {
        $play = Get-BrsCode (Get-BrsBody (Get-Content -Raw $playerBrs) 'sub playIndex\(idx as integer\)')
        $play | Should Not BeNullOrEmpty
        $branch = [regex]::Match($play, '(?s)if IsAdultGroup\(channel\.group\)(.*?)\r?\n\s*else\b').Groups[1].Value
        $branch | Should Match 'ClearLastChannel\(\)'
        ([regex]::Matches($play, 'ClearLastChannel\(\)')).Count | Should Be 1
    }

    It 'PurgeAdultFromRecents clears a stored adult name before its early return' {
        $store = Get-Content -Raw $storeBrs
        $body = Get-BrsCode (Get-BrsBody $store 'function PurgeAdultFromRecents\(channels as object\) as integer')
        $body | Should Not BeNullOrEmpty
        $iClear = $body.IndexOf('ClearLastChannel()')
        $early = [regex]::Match($body, 'recents\.Count\(\)\s*=\s*0\s+then\s+return')
        $early.Success | Should Be $true
        $iClear | Should BeGreaterThan 0
        ($iClear -lt $early.Index) | Should Be $true
    }

    It 'onPlaylistChange only computes: no playRequest in it or in computeResume' {
        $src = Get-Content -Raw $channelsBrs
        $change = Get-BrsCode (Get-BrsBody $src 'sub onPlaylistChange\(\)')
        $compute = Get-BrsCode (Get-BrsBody $src 'sub computeResume\(\)')
        $change.Length -gt 300 | Should Be $true      # positive controls: both bodies were found
        $compute.Length -gt 200 | Should Be $true
        $change | Should Not Match 'playRequest'
        $compute | Should Not Match 'playRequest'
    }

    It 'MainScene toggles resumeCommand after showChannels( and only under m.launchLoad' {
        $src = Get-Content -Raw $mainBrs
        $status = Get-BrsCode (Get-BrsBody $src 'sub onPlaylistStatus\(\)')
        $iShow = [regex]::Match($status, 'showChannels\(').Index
        $iToggle = [regex]::Match($status, 'resumeCommand\s*=\s*not').Index
        $iShow | Should BeGreaterThan 0
        $iToggle | Should BeGreaterThan 0
        ($iShow -lt $iToggle) | Should Be $true
        $status | Should Match '(?s)if m\.launchLoad\s+m\.launchLoad = false\s+m\.channelsScreen\.resumeCommand = not'
        ([regex]::Matches((Get-BrsCode $src), 'resumeCommand = not')).Count | Should Be 1
        # every load started from Settings clears the flag first, before any of them starts
        $act = Get-BrsCode (Get-BrsBody $src 'sub onSettingsAction\(\)')
        $iClear = $act.IndexOf('m.launchLoad = false')
        $iFirstLoad = $act.IndexOf('startPlaylistLoad(')
        $iClear | Should BeGreaterThan 0
        $iFirstLoad | Should BeGreaterThan 0
        ($iClear -lt $iFirstLoad) | Should Be $true
    }

    It 'onResumeCommand gates the indexed entry on IsAdultGroup between the lookup and playRequest' {
        $body = Get-BrsCode (Get-BrsBody (Get-Content -Raw $channelsBrs) 'sub onResumeCommand\(\)')
        $body.Length -gt 300 | Should Be $true
        $iLookup = [regex]::Match($body, '\.name\s*=\s*r\.name').Index
        $iGate = [regex]::Match($body, 'IsAdultGroup\(\s*ch\.group\s*\)').Index
        $iPlay = $body.IndexOf('m.top.playRequest')
        $iLookup | Should BeGreaterThan 0
        $iGate | Should BeGreaterThan 0
        $iPlay | Should BeGreaterThan 0
        ($iLookup -lt $iGate) | Should Be $true
        ($iGate -lt $iPlay) | Should Be $true
        ([regex]::Matches($body, 'playRequest')).Count | Should Be 1
    }

    It 'computes resume only when the adult count is above zero (fail closed)' {
        $src = Get-Content -Raw $channelsBrs
        $change = Get-BrsCode (Get-BrsBody $src 'sub onPlaylistChange\(\)')
        $change | Should Match 'adultCount = PurgeAdultFromRecents\('
        $change | Should Match '(?s)if adultCount < 1\s+ClearLastChannel\(\)\s.*?disabled: adult classifier matched 0.*?\r?\n\s*else\s+computeResume\(\)'
        ([regex]::Matches($change, 'computeResume\(\)')).Count | Should Be 1
    }

    It 'the Settings row sits before Diagnostics, which is the last addItem' {
        $src = Get-Content -Raw $settingsBrs
        $build = Get-BrsCode (Get-BrsBody $src 'sub buildList\(\)')
        $actions = @([regex]::Matches($build, 'addItem\(content,.*,\s*"([a-z]+)"\)') | ForEach-Object { $_.Groups[1].Value })
        $actions[$actions.Count - 1] | Should Be 'diagnostics'
        $iResume = $build.IndexOf('"resume")')
        $iDiag = $build.IndexOf('"diagnostics")')
        $iResume | Should BeGreaterThan 0
        ($iResume -lt $iDiag) | Should Be $true
        $src | Should Match 'Resume last channel: On'
        $src | Should Match 'Resume last channel: Off'
    }
}

Describe 'Recent grid lag (1.2.0)' {
    It 'ChannelCard no longer reads the guide or observes epgReady' {
        $src = Get-Content -Raw $cardBrs
        $src.Length -gt 500 | Should Be $true          # positive control: the file was read
        $src | Should Match 'm\.global\.theme'
        $src | Should Not Match 'm\.global\.epg'
        $src | Should Not Match 'EpgFind'
        $src | Should Not Match 'epgReady'
    }

    It 'ChannelsScreen reads playlistResult once into m.res and times the build' {
        $src = Get-BrsCode (Get-Content -Raw $channelsBrs)
        ([regex]::Matches($src, 'm\.top\.playlistResult')).Count | Should Be 1
        $src | Should Match 'm\.res = res'
        $src | Should Match '\[GRID\] build idx='
        # the guide is read once per build, not once per card
        $build = Get-BrsBody $src 'function buildGridForCategory\(idx as integer\) as object'
        ([regex]::Matches($build, 'm\.global\.epg')).Count | Should Be 1
    }

    It 'ChannelContent declares epgNow' {
        (Get-Content -Raw (Join-Path $projectRoot 'components\ChannelContent.xml')) | Should Match '<field id="epgNow" type="string" />'
    }
}

Describe 'Resume and grid refresh hardening (1.2.0 audit round)' {
    It 'ChannelsScreen init attaches no global observer; onPlaylistChange attaches them once, guarded' {
        $src = Get-Content -Raw $channelsBrs
        $init = Get-BrsCode (Get-BrsBody $src 'sub init\(\)')
        $init.Length -gt 500 | Should Be $true         # positive control: the body was found
        $init | Should Not Match 'm\.global\.observeField'
        $change = Get-BrsCode (Get-BrsBody $src 'sub onPlaylistChange\(\)')
        $change | Should Match '(?s)if not m\.globalObserved\s+m\.globalObserved = true\s+m\.global\.observeField\("epgReady", "onEpgReady"\)\s+m\.global\.observeField\("nowSec", "onNowTick"\)'
    }

    It 'refreshGridEpg reads the guide once, outside the node loop, and prints its cost' {
        $body = Get-BrsCode (Get-BrsBody (Get-Content -Raw $channelsBrs) 'sub refreshGridEpg\(key as string\)')
        $body.Length -gt 200 | Should Be $true
        ([regex]::Matches($body, 'm\.global\.epg')).Count | Should Be 1
        $iRead = $body.IndexOf('m.global.epg')
        $iLoop = $body.IndexOf('for i = 0')
        $iRead | Should BeGreaterThan 0
        $iLoop | Should BeGreaterThan 0
        ($iRead -lt $iLoop) | Should Be $true
        $body | Should Match '\[GRID\] epg refresh key='
    }

    It 'onEpgReady refreshes only the shown grid and marks the others stale' {
        $body = Get-BrsCode (Get-BrsBody (Get-Content -Raw $channelsBrs) 'sub onEpgReady\(\)')
        $body.Length -gt 150 | Should Be $true
        $body | Should Not Match 'getChild\('
        $body | Should Match 'm\.gridStamp\[key\]\s*=\s*0'
        ([regex]::Matches($body, 'refreshGridEpg\(')).Count | Should Be 1
    }

    It 'a stale cached grid is refreshed when shown, and the tick works only while visible' {
        $src = Get-Content -Raw $channelsBrs
        $show = Get-BrsCode (Get-BrsBody $src 'sub updateGridForCategory\(idx as integer\)')
        $show | Should Match 'if not isFreshStamp\(key\) then refreshGridEpg\(key\)'
        $fresh = Get-BrsCode (Get-BrsBody $src 'function isFreshStamp\(key as string\) as boolean')
        $fresh | Should Match '<=\s*300\b'
        $tick = Get-BrsCode (Get-BrsBody $src 'sub onNowTick\(\)')
        $iVis = [regex]::Match($tick, 'if not m\.top\.visible then return').Index
        $iRef = $tick.IndexOf('refreshGridEpg(')
        $tick | Should Match 'if not m\.top\.visible then return'
        $iRef | Should BeGreaterThan 0
        ($iVis -lt $iRef) | Should Be $true
    }

    It 'resume is computed only for the launch load: spent flag set in onResumeCommand, honoured by computeResume' {
        $src = Get-Content -Raw $channelsBrs
        $cmd = Get-BrsCode (Get-BrsBody $src 'sub onResumeCommand\(\)')
        $cmd | Should Match 'm\.resumeSpent = true'
        $cmd.IndexOf('m.resumeSpent = true') | Should BeLessThan $cmd.IndexOf('flushPendingGrid()')
        $compute = Get-BrsCode (Get-BrsBody $src 'sub computeResume\(\)')
        $compute | Should Match 'if m\.resumeSpent then return'
    }

    It 'computeResume refuses and clears when ANY channel of that name is in the adult group' {
        $compute = Get-BrsCode (Get-BrsBody (Get-Content -Raw $channelsBrs) 'sub computeResume\(\)')
        $compute | Should Match '(?s)for each c in m\.res\.channels\s+if c\.name = name and IsAdultGroup\(c\.group\)\s+ClearLastChannel\(\)\s+return'
    }

    It 'ClearLastChannel falls back to blanking the value when Delete or Flush fails' {
        $body = Get-BrsCode (Get-BrsBody (Get-Content -Raw $storeBrs) 'sub ClearLastChannel\(\)')
        $body.Length -gt 200 | Should Be $true
        $iDel = $body.IndexOf('.Delete("lastChannel")')
        $iBlank = $body.IndexOf('.Write("lastChannel", "")')
        $iFail = $body.IndexOf('[RESUME] clear failed')
        $iDel | Should BeGreaterThan 0
        ($iDel -lt $iBlank) | Should Be $true
        ($iBlank -lt $iFail) | Should Be $true
    }

    It 'm.byName is case-sensitive before it is filled' {
        $change = Get-BrsCode (Get-BrsBody (Get-Content -Raw $channelsBrs) 'sub onPlaylistChange\(\)')
        $iMode = $change.IndexOf('m.byName.SetModeCaseSensitive()')
        $iFill = $change.IndexOf('m.byName[')
        $iMode | Should BeGreaterThan 0
        $iFill | Should BeGreaterThan 0
        ($iMode -lt $iFill) | Should Be $true
    }

    It 'toggleResume re-asserts list focus and shows the info of the row it toggled' {
        $src = Get-Content -Raw $settingsBrs
        $body = Get-BrsCode (Get-BrsBody $src 'sub toggleResume\(\)')
        $body.Length -gt 150 | Should Be $true
        $iJump = $body.IndexOf('jumpToItem')
        $iFocus = $body.IndexOf('m.settingsList.setFocus(true)')
        $iInfo = $body.IndexOf('updateInfo()')
        $iJump | Should BeGreaterThan 0
        ($iJump -lt $iFocus) | Should Be $true
        $body | Should Match 'm\.forceInfoRow = row'
        ($iFocus -lt $iInfo) | Should Be $true
        (Get-BrsCode (Get-BrsBody $src 'sub updateInfo\(\)')) | Should Match 'idx = m\.forceInfoRow'
    }
}
