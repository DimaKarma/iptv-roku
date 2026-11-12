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

Describe 'Version 1.1 (manifest and About agree)' {
    It 'manifest says 1.1.1 and the About version starts with 1.1' {
        $manifest = Get-Content -Raw (Join-Path $projectRoot 'manifest')
        [regex]::Match($manifest, 'major_version=(\d+)').Groups[1].Value | Should Be '1'
        [regex]::Match($manifest, 'minor_version=(\d+)').Groups[1].Value | Should Be '1'
        [regex]::Match($manifest, 'build_version=(\d+)').Groups[1].Value | Should Be '1'
        $about = Get-Content -Raw $settingsBrs
        [regex]::Match($about, 'appVersion = "(\d+\.\d+)\.\d+"').Groups[1].Value | Should Be '1.1'
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
