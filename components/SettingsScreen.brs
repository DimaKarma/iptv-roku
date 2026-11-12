' SettingsScreen: settings list and URL input

sub init()
    m.settingsList = m.top.findNode("settingsList")
    m.headerLabel = m.top.findNode("headerLabel")
    m.infoLabel = m.top.findNode("infoLabel")
    m.keyboardBg = m.top.findNode("keyboardBg")
    m.keyboard = m.top.findNode("keyboard")
    m.keyboardHint = m.top.findNode("keyboardHint")
    m.saveCancelList = m.top.findNode("saveCancelList")
    ' The Diagnostics screen is created on first use (never a static child, no probe code
    ' in any init) and then reused.
    m.diag = invalid
    m.forceInfoRow = -1
    
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    m.toastTimer = m.top.findNode("toastTimer")
    
    m.settingsList.observeField("itemSelected", "onItemSelected")
    m.settingsList.observeField("itemFocused", "onItemFocused")
    m.saveCancelList.observeField("itemSelected", "onSaveCancelSelected")
    m.toastTimer.observeField("fire", "hideToast")
    m.top.observeField("visible", "onVisibleChange")
    m.top.observeField("noticeCommand", "onNotice")

    theme = getTheme()
    if theme <> invalid
        m.headerLabel.color = theme.colorText
        m.settingsList.color = theme.colorTextDim
        m.settingsList.focusedColor = theme.colorOnAccent
        m.infoLabel.color = theme.colorTextDim
        m.keyboardHint.color = theme.colorText
        m.saveCancelList.color = theme.colorTextDim
        m.saveCancelList.focusedColor = theme.colorOnAccent
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
    end if
    
    buildSaveCancel()
    CenterKeyboard(m.keyboard, 200)
    buildList()
end sub

sub onVisibleChange()
    if m.top.visible
        if m.diag <> invalid then m.diag.visible = false
        m.settingsList.setFocus(true)
    end if
end sub

sub onInfoChange()
    buildList()
    updateInfo()
end sub

' ONE place builds both the titles and the actions they trigger, in parallel lists,
' like buildErrorOptions in PlayerScreen. Dispatch (onItemSelected) and the info pane
' (updateInfo) read m.settingsActions, never a literal row number, so adding or moving a
' row cannot silently re-aim another row's handler.
sub buildList()
    content = CreateObject("roSGNode", "ContentNode")
    m.settingsActions = []
    
    addItem(content, "Playlist URL", "url")
    addItem(content, "Refresh playlist now", "refresh")
    addItem(content, "URL EPG", "epg")
    addItem(content, "Clear cache", "clearCache")
    addItem(content, "About", "about")
    addItem(content, resumeRowTitle(), "resume")
    addItem(content, "Diagnostics", "diagnostics")
    
    m.settingsList.content = content
end sub

function resumeRowTitle() as string
    if IsResumeEnabled() then return "Resume last channel: On"
    return "Resume last channel: Off"
end function

sub addItem(parent as object, title as string, action as string)
    item = parent.createChild("ContentNode")
    item.title = title
    m.settingsActions.Push(action)
end sub

' Two rows, Save first. Rebuilt each time the keyboard opens so the cursor starts on Save.
sub buildSaveCancel()
    content = CreateObject("roSGNode", "ContentNode")
    addSaveCancelRow(content, "Save")
    addSaveCancelRow(content, "Cancel")
    m.saveCancelList.content = content
end sub

sub addSaveCancelRow(parent as object, title as string)
    item = parent.createChild("ContentNode")
    item.title = title
end sub

function actionAt(idx as integer) as string
    if m.settingsActions = invalid then return ""
    if idx < 0 or idx >= m.settingsActions.Count() then return ""
    return m.settingsActions[idx]
end function

sub updateInfo()
    ' Both values are bumped by hand with each release and are bound to the manifest
    ' by a test (tests/BrightScript.Lint.Tests.ps1).
    appVersion = "1.3.1"
    buildDate = "2026-11-12"
    idx = m.settingsList.itemFocused
    if m.forceInfoRow <> invalid and m.forceInfoRow >= 0
        idx = m.forceInfoRow
        m.forceInfoRow = -1
    end if
    info = m.top.info
    act = actionAt(idx)
    
    text = ""
    if act = "url"
        if info <> invalid and info.playlistUrl <> invalid
            text = "Current URL:" + chr(10) + info.playlistUrl
        else
            text = "URL not set"
        end if
    else if act = "refresh"
        text = "Force a full playlist reload"
    else if act = "epg"
        if info <> invalid and info.epgUrl <> invalid and info.epgUrl <> ""
            text = "Current EPG URL:" + chr(10) + info.epgUrl
        else
            text = "EPG URL not set"
        end if
    else if act = "clearCache"
        text = "Delete cached playlist data and metadata."
    else if act = "resume"
        text = "Play the last watched channel when the app starts."
    else if act = "diagnostics"
        text = "Probes for the keyboard and for what this device allows." + chr(10) + "Results go to the debug console."
    else if act = "about"
        ' Kept in step with the manifest by tests/BrightScript.Lint.Tests.ps1.
        ' roAppInfo would read it at runtime, but nothing in this project uses that
        ' object yet and rule 20 shows some CreateObject types fault on the render
        ' thread - which a Settings screen is. Not worth an install to find out.
        text = "IPTV Player v" + appVersion + chr(10)
        text = text + "Build " + buildDate + chr(10)
        text = text + "Made for people. Completely free. Install and watch." + chr(10) + chr(10)
        if info <> invalid
            if info.channelCount <> invalid then text = text + "Channels: " + info.channelCount.ToStr() + chr(10)
            if info.fetchedAt <> invalid then text = text + "Updated: " + info.fetchedAt + chr(10)
            if info.source <> invalid then text = text + "Source: " + info.source + chr(10)
            ' Three distinct states. The old code printed "not set" whenever epgCount
            ' was invalid, which is exactly what a FAILED load leaves behind -- so a
            ' user with a configured but broken EPG URL was told they had no EPG URL.
            if info.epgCount <> invalid and info.epgCount > 0 then
                text = text + "EPG: " + info.epgCount.ToStr() + " channels"
            else if info.epgFailed <> invalid and info.epgFailed = true then
                text = text + "EPG: unavailable"
            else
                text = text + "EPG: not set"
            end if
            ' Guide age. The July 2026 outage was invisible because a weeks-old guide
            ' looks exactly like "this channel has no programmes"; a timestamp here is
            ' the cheapest way to tell those apart. Shown even when the last load
            ' failed, since the stale data is what the app is actually serving.
            if info.epgGeneratedText <> invalid and info.epgGeneratedText <> "" then
                text = text + chr(10) + "Guide updated: " + info.epgGeneratedText
            end if
        end if
        text = text + chr(10) + chr(10) + "(c) 2026 DimaKarma"
    end if
    
    m.infoLabel.text = text
end sub

sub onItemFocused()
    updateInfo()
end sub

sub onItemSelected()
    act = actionAt(m.settingsList.itemSelected)
    
    if act = "url"
        info = m.top.info
        if info <> invalid and info.playlistUrl <> invalid
            m.keyboard.text = info.playlistUrl
        else
            m.keyboard.text = ""
        end if
        m.editMode = "playlist"
        showKeyboard("Enter a new playlist URL")
    else if act = "refresh"
        sendAction("refresh")
    else if act = "epg"
        info = m.top.info
        if info <> invalid and info.epgUrl <> invalid
            m.keyboard.text = info.epgUrl
        else
            m.keyboard.text = ""
        end if
        m.editMode = "epg"
        showKeyboard("Enter a new EPG URL")
    else if act = "clearCache"
        ' The deletion itself happens in PlaylistTask (clearCache), off the render thread.
        showToast("Cache cleared")
        sendAction("clearCache")
    else if act = "resume"
        toggleResume()
    else if act = "diagnostics"
        openDiagnostics()
    else if act = "about"
        ' Do nothing
    end if
end sub

' Flip the setting, then rebuild the list so the row shows the new state. Rebuilding
' resets the cursor, so put it back on the same row.
sub toggleResume()
    row = m.settingsList.itemFocused
    SetResumeEnabled(not IsResumeEnabled())
    buildList()
    m.settingsList.jumpToItem = row
    m.settingsList.setFocus(true)
    ' itemFocused may still hold the old value right after jumpToItem.
    m.forceInfoRow = row
    updateInfo()
end sub

sub showKeyboard(hint as string)
    m.keyboardHint.text = hint
    m.keyboardBg.visible = true
    ' Again here: boundingRect() can be zero before the first layout.
    CenterKeyboard(m.keyboard, 200)
    positionSaveCancel()
    buildSaveCancel()
    m.keyboard.setFocus(true)
end sub

' Under the keyboard, centred. Falls back to y=560 without a usable bounding rect.
sub positionSaveCancel()
    y = 560
    r = m.keyboard.boundingRect()
    if r <> invalid
        if r.height > 0 then y = 200 + Int(r.height) + 24
    end if
    if y > 860 then y = 860
    m.saveCancelList.translation = [760, y]
end sub

sub closeKeyboard()
    m.keyboardBg.visible = false
    m.keyboard.setFocus(false)
    m.saveCancelList.setFocus(false)
    m.settingsList.setFocus(true)
end sub

sub onSaveCancelSelected()
    idx = m.saveCancelList.itemSelected
    if idx = 0
        onKeyboardSave()
    else
        onKeyboardCancel()
    end if
end sub

sub openDiagnostics()
    if m.diag = invalid
        m.diag = CreateObject("roSGNode", "DiagnosticsScreen")
        if m.diag = invalid
            showToast("Diagnostics unavailable")
            return
        end if
        m.diag.observeField("exitRequested", "onDiagExit")
        m.top.appendChild(m.diag)
    end if
    m.diag.visible = true
    m.diag.openCommand = not m.diag.openCommand
end sub

sub onDiagExit()
    m.settingsList.setFocus(true)
end sub

sub onKeyboardSave()
    url = m.keyboard.text
    closeKeyboard()
    
    sec = CreateObject("roRegistrySection", "settings")
    if m.editMode = "epg"
        sec.Write("epgUrl", url)
        sec.Flush()
        m.top.newUrl = url
        sendAction("epgChanged")
    else
        sec.Write("playlistUrl", url)
        sec.Flush()
        m.top.newUrl = url
        sendAction("urlChanged")
    end if
end sub

sub onKeyboardCancel()
    closeKeyboard()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false
    ' While Diagnostics is up it owns the keys (it handles its own Back).
    if m.diag <> invalid
        if m.diag.visible then return false
    end if
    if press
        if m.keyboardBg.visible
            ' Rule 8: the Keyboard swallows every arrow, so the only key that reaches
            ' here from it is Back. Back from the keyboard moves to Save / Cancel; Back
            ' from that list discards.
            if key = "back"
                if m.saveCancelList.hasFocus()
                    onKeyboardCancel()
                else
                    m.keyboard.setFocus(false)
                    m.saveCancelList.jumpToItem = 0
                    m.saveCancelList.setFocus(true)
                end if
                handled = true
            end if
        else
            if key = "back"
                m.top.exitRequested = not m.top.exitRequested
                handled = true
            end if
        end if
    end if
    return handled
end function

' The only place allowed to write m.top.action. Sets the payload first, then toggles
' the trigger, so MainScene always reads a matching action. Writing m.top.action
' directly elsewhere would be dead on a repeat, which is the bug this replaces.
sub sendAction(name as string)
    m.top.action = name
    m.top.actionCommand = not m.top.actionCommand
end sub

sub onNotice()
    showToast(m.top.notice)
end sub

sub showToast(msg as string)
    m.toastLabel.text = msg
    m.toastBg.visible = true
    m.toastTimer.control = "start"
end sub

sub hideToast()
    m.toastBg.visible = false
end sub
