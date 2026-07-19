' Main scene logic for handling UI and initializing tasks
sub init()
    m.background = m.top.findNode("background")
    m.spinner = m.top.findNode("spinner")
    m.statusLabel = m.top.findNode("statusLabel")
    m.errorLabel = m.top.findNode("errorLabel")
    m.errorHintLabel = m.top.findNode("errorHintLabel")
    
    m.channelsScreen = m.top.findNode("channelsScreen")
    m.playerScreen = m.top.findNode("playerScreen")
    m.searchScreen = m.top.findNode("searchScreen")
    m.settingsScreen = m.top.findNode("settingsScreen")
    
    m.onboardingGroup = m.top.findNode("onboardingGroup")
    m.onboardingKeyboard = m.top.findNode("onboardingKeyboard")
    m.onboardingOk = m.top.findNode("onboardingOk")
    
    m.channelsScreen.observeField("playRequest", "onPlayRequest")
    m.channelsScreen.observeField("openSearch", "onOpenSearch")
    m.channelsScreen.observeField("openSettings", "onOpenSettings")
    
    m.playerScreen.observeField("exitRequested", "onPlayerExit")
    
    m.searchScreen.observeField("exitRequested", "onChildScreenExit")
    m.searchScreen.observeField("playRequest", "onPlayRequest")
    
    m.settingsScreen.observeField("exitRequested", "onChildScreenExit")
    m.settingsScreen.observeField("action", "onSettingsAction")
    
    m.onboardingOk.observeField("buttonSelected", "onOnboardingSave")
    
    m.epgRefreshTimer = m.top.findNode("epgRefreshTimer")
    m.epgRefreshTimer.observeField("fire", "onEpgRefresh")
    
    m.top.findNode("nowTimer").observeField("fire", "onNowTick")
    m.top.findNode("nowTimer").control = "start"
    
    theme = getTheme()
    if theme <> invalid
        m.background.color = theme.colorBg
        m.statusLabel.color = theme.colorTextDim
        m.errorLabel.color = theme.colorText
        m.errorHintLabel.color = theme.colorTextDim
    end if
    
    m.top.setFocus(true)
    
    m.playlistResultCache = invalid
    
    if m.global.epg = invalid then m.global.addField("epg", "assocarray", false)
    if m.global.epgReady = invalid then m.global.addField("epgReady", "boolean", false)
    if m.global.theme = invalid then m.global.addField("theme", "assocarray", false)
    m.global.theme = getTheme()
    if m.global.nowSec = invalid then m.global.addField("nowSec", "integer", false)
    m.global.nowSec = CreateObject("roDateTime").AsSeconds()

    runConfigTask()
end sub

sub runConfigTask()
    m.configTask = CreateObject("roSGNode", "ConfigTask")
    m.configTask.observeField("config", "onConfigLoaded")
    m.configTask.observeField("error", "onConfigError")
    m.configTask.control = "RUN"
end sub

sub onConfigLoaded()
    config = m.configTask.config
    m.configCache = config
    
    url = ""
    sec = CreateObject("roRegistrySection", "settings")
    if sec.Exists("playlistUrl")
        url = sec.Read("playlistUrl")
    end if
    
    if url = "" and config <> invalid and config.playlistUrl <> invalid and config.playlistUrl <> ""
        url = config.playlistUrl
    end if
    
    if url <> ""
        startPlaylistLoad(url)
    else
        showOnboarding()
    end if
end sub

sub startPlaylistLoad(url as string)
    showLoading("Loading playlist…")
    m.currentUrl = url
    m.playlistTask = CreateObject("roSGNode", "PlaylistTask")
    m.playlistTask.playlistUrl = url
    m.playlistTask.observeField("status", "onPlaylistStatus")
    if m.configCache <> invalid and m.configCache.extraPlaylists <> invalid
        m.playlistTask.extraPlaylists = m.configCache.extraPlaylists
    end if
    m.playlistTask.control = "RUN"
end sub

sub onPlaylistStatus()
    status = m.playlistTask.status
    
    if status = "ok" or status = "cache"
        res = m.playlistTask.result
        if res <> invalid
            m.playlistResultCache = res
            showChannels(res)
            
            epgUrl = ""
            sec = CreateObject("roRegistrySection", "settings")
            if sec.Exists("epgUrl")
                epgUrl = sec.Read("epgUrl")
            else if m.configCache <> invalid and m.configCache.epgUrl <> invalid
                epgUrl = m.configCache.epgUrl
            end if
            
            if epgUrl <> ""
                startEpgLoad(epgUrl)
            end if
        end if
    else if status = "error"
        err = m.playlistTask.error
        if err = invalid then err = "Unknown error"
        showError(err)
    end if
end sub

sub onConfigError()
    showError("config.json not found")
end sub

sub hideAllScreens()
    m.spinner.visible = false
    m.spinner.control = "stop"
    m.statusLabel.visible = false
    m.errorLabel.visible = false
    m.errorHintLabel.visible = false
    
    m.channelsScreen.visible = false
    m.playerScreen.visible = false
    m.searchScreen.visible = false
    m.settingsScreen.visible = false
    m.onboardingGroup.visible = false
end sub

sub showLoading(text as string)
    hideAllScreens()
    m.spinner.visible = true
    m.spinner.control = "start"
    m.statusLabel.visible = true
    m.statusLabel.text = text
end sub

sub showError(errText as string)
    hideAllScreens()
    m.errorLabel.visible = true
    m.errorLabel.text = errText
    m.errorHintLabel.visible = true
end sub

sub showOnboarding()
    hideAllScreens()
    m.onboardingGroup.visible = true
    m.onboardingKeyboard.setFocus(true)
end sub

sub onOnboardingSave()
    url = m.onboardingKeyboard.text
    if url <> ""
        sec = CreateObject("roRegistrySection", "settings")
        sec.Write("playlistUrl", url)
        sec.Flush()
        startPlaylistLoad(url)
    end if
end sub

sub showChannels(res as object)
    hideAllScreens()
    m.channelsScreen.visible = true
    m.channelsScreen.playlistResult = res
    m.channelsScreen.setFocus(true)
end sub

sub onPlayRequest(event as object)
    req = event.getData()
    if req <> invalid and req.channels <> invalid
        hideAllScreens()
        m.playerScreen.visible = true
        
        m.playerScreen.playlist = req.channels
        m.playerScreen.startIndex = req.index
        m.playerScreen.playCommand = not m.playerScreen.playCommand
        
        m.playerScreen.setFocus(true)
    end if
end sub

sub onPlayerExit()
    hideAllScreens()
    m.channelsScreen.visible = true
    m.channelsScreen.restoreFocus = not m.channelsScreen.restoreFocus
end sub

sub onOpenSearch()
    if m.playlistResultCache <> invalid
        m.searchScreen.channels = m.playlistResultCache.channels
    end if
    hideAllScreens()
    m.searchScreen.visible = true
end sub

sub onOpenSettings()
    info = {
        playlistUrl: m.currentUrl,
        channelCount: 0,
        fetchedAt: "",
        source: "",
        epgUrl: ""
    }
    if m.playlistResultCache <> invalid
        if m.playlistResultCache.channels <> invalid
            info.channelCount = m.playlistResultCache.channels.Count()
        end if
        info.fetchedAt = fmtEpochLocal(m.playlistResultCache.fetchedAt)
        info.source = m.playlistResultCache.source
    end if
    if m.currentEpgUrl <> invalid then info.epgUrl = m.currentEpgUrl
    if m.epgCount <> invalid then info.epgCount = m.epgCount
    
    m.settingsScreen.info = info
    hideAllScreens()
    m.settingsScreen.visible = true
end sub

sub onChildScreenExit()
    hideAllScreens()
    m.channelsScreen.visible = true
    m.channelsScreen.restoreFocus = not m.channelsScreen.restoreFocus
end sub

sub onSettingsAction()
    action = m.settingsScreen.action
    if action = "refresh" or action = "clearCache"
        startPlaylistLoad(m.currentUrl)
    else if action = "urlChanged"
        startPlaylistLoad(m.settingsScreen.newUrl)
    else if action = "epgChanged"
        startEpgLoad(m.settingsScreen.newUrl)
    end if
end sub

sub startEpgLoad(url as string)
    m.currentEpgUrl = url
    m.epgTask = CreateObject("roSGNode", "EpgTask")
    m.epgTask.epgUrl = url
    m.epgTask.observeField("status", "onEpgStatus")
    m.epgTask.control = "RUN"
    
    m.epgRefreshTimer.control = "start"
end sub

sub onEpgStatus()
    status = m.epgTask.status
    if status = "ok" or status = "cache"
        res = m.epgTask.result
        if res <> invalid
            if m.global.epg = invalid then m.global.addField("epg", "assocarray", false)
            if m.global.epgReady = invalid then m.global.addField("epgReady", "boolean", false)
            m.global.epg = res.epg
            m.global.epgReady = not m.global.epgReady
            
            m.epgCount = res.count
            m.epgGenerated = res.generated
        end if
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false
    if press
        if m.onboardingGroup.visible
            if key = "down"
                if m.onboardingKeyboard.hasFocus()
                    m.onboardingOk.setFocus(true)
                    handled = true
                end if
            else if key = "up"
                if m.onboardingOk.hasFocus()
                    m.onboardingKeyboard.setFocus(true)
                    handled = true
                end if
            end if
        else if key = "back"
            handled = false
        else if key = "OK"
            if m.errorLabel.visible
                if m.currentUrl <> invalid and m.currentUrl <> ""
                    startPlaylistLoad(m.currentUrl)
                    handled = true
                else
                    runConfigTask()
                    handled = true
                end if
            end if
        end if
    end if
    return handled
end function

' epoch (int/float/string) -> "YYYY-MM-DD HH:MM" in local time; otherwise ""
function fmtEpochLocal(v as dynamic) as string
    if v = invalid then return ""
    if GetInterface(v, "ifString") <> invalid then return v
    sec = 0
    if GetInterface(v, "ifInt") <> invalid
        sec = v
    else if GetInterface(v, "ifFloat") <> invalid or GetInterface(v, "ifDouble") <> invalid
        sec = Int(v)
    else
        return ""
    end if
    dt = CreateObject("roDateTime")
    dt.FromSeconds(sec)
    dt.ToLocalTime()
    y = dt.GetYear().ToStr()
    mo = dt.GetMonth().ToStr()
    if mo.Len() = 1 then mo = "0" + mo
    d = dt.GetDayOfMonth().ToStr()
    if d.Len() = 1 then d = "0" + d
    h = dt.GetHours().ToStr()
    if h.Len() = 1 then h = "0" + h
    mn = dt.GetMinutes().ToStr()
    if mn.Len() = 1 then mn = "0" + mn
    return y + "-" + mo + "-" + d + " " + h + ":" + mn
end function

sub onEpgRefresh()
    if m.currentEpgUrl <> invalid and m.currentEpgUrl <> ""
        startEpgLoad(m.currentEpgUrl)
    end if
end sub

sub onNowTick()
    m.global.nowSec = CreateObject("roDateTime").AsSeconds()
end sub
