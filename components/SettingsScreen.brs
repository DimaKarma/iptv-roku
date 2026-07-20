' SettingsScreen: settings list and URL input

sub init()
    m.settingsList = m.top.findNode("settingsList")
    m.headerLabel = m.top.findNode("headerLabel")
    m.infoLabel = m.top.findNode("infoLabel")
    m.keyboardBg = m.top.findNode("keyboardBg")
    m.keyboard = m.top.findNode("keyboard")
    m.keyboardHint = m.top.findNode("keyboardHint")
    m.keyboardOk = m.top.findNode("keyboardOk")
    m.keyboardCancel = m.top.findNode("keyboardCancel")
    
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    m.toastTimer = m.top.findNode("toastTimer")
    
    m.settingsList.observeField("itemSelected", "onItemSelected")
    m.settingsList.observeField("itemFocused", "onItemFocused")
    m.keyboardOk.observeField("buttonSelected", "onKeyboardSave")
    m.keyboardCancel.observeField("buttonSelected", "onKeyboardCancel")
    m.toastTimer.observeField("fire", "hideToast")
    m.top.observeField("visible", "onVisibleChange")
    
    theme = getTheme()
    if theme <> invalid
        m.headerLabel.color = theme.colorText
        m.settingsList.color = theme.colorTextDim
        m.settingsList.focusedColor = theme.colorText
        m.infoLabel.color = theme.colorTextDim
        m.keyboardHint.color = theme.colorText
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
    end if
    
    buildList()
end sub

sub onVisibleChange()
    if m.top.visible then m.settingsList.setFocus(true)
end sub

sub onInfoChange()
    buildList()
    updateInfo()
end sub

sub buildList()
    content = CreateObject("roSGNode", "ContentNode")
    
    addItem(content, "Playlist URL")
    addItem(content, "Refresh playlist now")
    addItem(content, "URL EPG")
    addItem(content, "Clear cache")
    addItem(content, "About")
    
    m.settingsList.content = content
end sub

sub addItem(parent as object, title as string)
    item = parent.createChild("ContentNode")
    item.title = title
end sub

sub updateInfo()
    idx = m.settingsList.itemFocused
    info = m.top.info
    
    text = ""
    if idx = 0 ' URL
        if info <> invalid and info.playlistUrl <> invalid
            text = "Current URL:" + chr(10) + info.playlistUrl
        else
            text = "URL not set"
        end if
    else if idx = 1 ' Refresh
        text = "Force a full playlist reload"
    else if idx = 2 ' EPG
        if info <> invalid and info.epgUrl <> invalid and info.epgUrl <> ""
            text = "Current EPG URL:" + chr(10) + info.epgUrl
        else
            text = "EPG URL not set"
        end if
    else if idx = 3 ' Cache
        text = "Delete cached playlist data and metadata."
    else if idx = 4 ' About
        text = "IPTV Player v0.1" + chr(10)
        text = text + "Made for people. Completely free. Install and watch." + chr(10) + chr(10)
        if info <> invalid
            if info.channelCount <> invalid then text = text + "Channels: " + info.channelCount.ToStr() + chr(10)
            if info.fetchedAt <> invalid then text = text + "Updated: " + info.fetchedAt + chr(10)
            if info.source <> invalid then text = text + "Source: " + info.source + chr(10)
            if info.epgCount <> invalid and info.epgCount > 0 then
                text = text + "EPG: " + info.epgCount.ToStr() + " channels"
            else
                text = text + "EPG: not set"
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
    idx = m.settingsList.itemSelected
    
    if idx = 0 ' URL
        info = m.top.info
        if info <> invalid and info.playlistUrl <> invalid
            m.keyboard.text = info.playlistUrl
        else
            m.keyboard.text = ""
        end if
        m.editMode = "playlist"
        m.keyboardHint.text = "Enter a new playlist URL"
        m.keyboardBg.visible = true
        m.keyboard.setFocus(true)
    else if idx = 1 ' Refresh
        m.top.action = "refresh"
    else if idx = 2 ' EPG
        info = m.top.info
        if info <> invalid and info.epgUrl <> invalid
            m.keyboard.text = info.epgUrl
        else
            m.keyboard.text = ""
        end if
        m.editMode = "epg"
        m.keyboardHint.text = "Enter a new EPG URL"
        m.keyboardBg.visible = true
        m.keyboard.setFocus(true)
    else if idx = 3 ' Cache
        fs = CreateObject("roFileSystem")
        if fs.Exists("cachefs:/playlist.json")
            fs.Delete("cachefs:/playlist.json")
        end if
        if fs.Exists("cachefs:/playlist_meta.json")
            fs.Delete("cachefs:/playlist_meta.json")
        end if
        if fs.Exists("cachefs:/epg.json")
            fs.Delete("cachefs:/epg.json")
        end if
        showToast("Cache cleared")
        m.top.action = "clearCache"
    else if idx = 4 ' About
        ' Do nothing
    end if
end sub

sub onKeyboardSave()
    url = m.keyboard.text
    m.keyboardBg.visible = false
    m.settingsList.setFocus(true)
    
    sec = CreateObject("roRegistrySection", "settings")
    if m.editMode = "epg"
        sec.Write("epgUrl", url)
        sec.Flush()
        m.top.newUrl = url
        m.top.action = "epgChanged"
    else
        sec.Write("playlistUrl", url)
        sec.Flush()
        m.top.newUrl = url
        m.top.action = "urlChanged"
    end if
end sub

sub onKeyboardCancel()
    m.keyboardBg.visible = false
    m.settingsList.setFocus(true)
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false
    if press
        if m.keyboardBg.visible
            if key = "down"
                if m.keyboard.hasFocus()
                    m.keyboardOk.setFocus(true)
                    handled = true
                else if m.keyboardOk.hasFocus()
                    m.keyboardCancel.setFocus(true)
                    handled = true
                end if
            else if key = "up"
                if m.keyboardCancel.hasFocus()
                    m.keyboardOk.setFocus(true)
                    handled = true
                else if m.keyboardOk.hasFocus()
                    m.keyboard.setFocus(true)
                    handled = true
                end if
            else if key = "back"
                m.keyboardBg.visible = false
                m.settingsList.setFocus(true)
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

sub showToast(msg as string)
    m.toastLabel.text = msg
    m.toastBg.visible = true
    m.toastTimer.control = "start"
end sub

sub hideToast()
    m.toastBg.visible = false
end sub
