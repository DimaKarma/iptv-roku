' PlayerScreen
sub init()
    m.video = m.top.findNode("video")
    m.spinner = m.top.findNode("spinner")
    m.spinnerAnim = m.top.findNode("playSpinnerAnim")
    m.loadingLabel = m.top.findNode("loadingLabel")
    
    m.overlayGroup = m.top.findNode("overlayGroup")
    m.overlayName = m.top.findNode("overlayName")
    m.overlayGroupLabel = m.top.findNode("overlayGroupLabel")
    m.overlayTime = m.top.findNode("overlayTime")
    m.overlayEpg = m.top.findNode("overlayEpg")
    
    m.miniBanner = m.top.findNode("miniBanner")
    m.miniBannerLabel = m.top.findNode("miniBannerLabel")
    
    m.errorDialog = m.top.findNode("errorDialog")
    m.errorMsg = m.top.findNode("errorMsg")
    m.errorOptions = m.top.findNode("errorOptions")
    
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    
    m.overlayTimer = m.top.findNode("overlayTimer")
    m.miniBannerTimer = m.top.findNode("miniBannerTimer")
    m.toastTimer = m.top.findNode("toastTimer")
    m.clockTimer = m.top.findNode("clockTimer")
    m.okTimer = m.top.findNode("okTimer")
    
    m.zapLine2 = m.top.findNode("zapLine2")
    m.zapUntil = m.top.findNode("zapUntil")
    m.zapProgress = m.top.findNode("zapProgress")

    m.zapperPanel = m.top.findNode("zapperPanel")
    m.zapperGrid = m.top.findNode("zapperGrid")
    m.zapperTimer = m.top.findNode("zapperTimer")
    
    m.video.observeField("state", "onVideoStateChange")
    m.overlayTimer.observeField("fire", "hideOverlay")
    m.miniBannerTimer.observeField("fire", "hideMiniBanner")
    m.toastTimer.observeField("fire", "hideToast")
    m.clockTimer.observeField("fire", "updateClock")
    m.okTimer.observeField("fire", "onOkLongPress")
    
    m.zapperGrid.observeField("itemSelected", "onZapperSelected")
    m.zapperGrid.observeField("itemFocused", "onZapperFocused")
    m.zapperTimer.observeField("fire", "closeZapper")
    
    m.okLongFired = false
    
    m.errorOptions.observeField("itemSelected", "onErrorOptionSelected")
    
    theme = getTheme()
    ' Cached here, not fetched per zap: getTheme() builds an 11-key AA on every call
    ' and showMiniBanner is on the channel-change hot path (GEMINI.md #17).
    m.theme = theme
    if theme <> invalid
        m.overlayName.color = theme.colorText
        ' The category is a fact, not an accent. It was rendering in focusBright,
        ' which made green mean four different things across the app.
        m.overlayGroupLabel.color = theme.colorTextDim
        m.overlayTime.color = theme.colorText
        m.miniBannerLabel.color = theme.colorText
        m.errorDialog.color = theme.colorSurface
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
        m.errorOptions.color = theme.colorTextDim
        m.errorOptions.focusedColor = theme.colorText
    end if
    
    m.currentIndex = -1
end sub

sub addErrorOption(parent as object, title as string)
    item = parent.createChild("ContentNode")
    item.title = title
end sub

sub onPlayCommand()
    if m.top.playlist = invalid or m.top.playlist.Count() = 0 then return
    idx = m.top.startIndex
    if idx = invalid or idx < 0 or idx >= m.top.playlist.Count() then idx = 0
    playIndex(idx)
end sub

sub playIndex(idx as integer)
    if m.top.playlist = invalid or m.top.playlist.Count() = 0 return
    if idx < 0 or idx >= m.top.playlist.Count() return
    
    m.currentIndex = idx
    channel = m.top.playlist[idx]
    
    node = CreateObject("roSGNode", "ContentNode")
    node.title = channel.name
    node.url = channel.url
    node.streamFormat = "hls"
    
    m.video.content = node
    m.video.control = "play"
    
    if not IsAdultGroup(channel.group)
        PushRecent(channel.name)
    end if
    
    m.errorDialog.visible = false
    
    ' Set the loading caption HERE, not only from onVideoStateChange. That observer
    ' fires on a state CHANGE, and a zap while the video is already "buffering" does
    ' not change the state -- so the caption kept naming the previous channel during a
    ' fast surf. Same class as the Settings action field that only fired once.
    m.loadingLabel.text = "Loading: " + channel.name

    showMiniBanner(channel)
    updateOverlayData(channel)
    
    focusPlayer()
end sub

sub onVideoStateChange()
    state = m.video.state
    if state = "buffering"
        m.spinner.visible = true
        m.spinnerAnim.control = "start"
        m.loadingLabel.visible = true
        if m.currentIndex >= 0 and m.top.playlist <> invalid
            m.loadingLabel.text = "Loading: " + m.top.playlist[m.currentIndex].name
        else
            m.loadingLabel.text = "Loading…"
        end if
    else if state = "playing"
        m.spinner.visible = false
        m.spinnerAnim.control = "stop"
        m.loadingLabel.visible = false
    else if state = "error"
        m.spinner.visible = false
        m.spinnerAnim.control = "stop"
        m.loadingLabel.visible = false
        showErrorDialog()
    end if
end sub

function buildErrorOptions() as object
    c = CreateObject("roSGNode", "ContentNode")
    addErrorOption(c, "Retry")
    addErrorOption(c, "Next channel")
    isFav = false
    if m.currentIndex >= 0 and m.top.playlist <> invalid
        ch = m.top.playlist[m.currentIndex]
        if ch <> invalid then isFav = IsFavorite(ch.name)
    end if
    if isFav
        addErrorOption(c, "Remove from favorites")
    else
        addErrorOption(c, "Add to favorites")
    end if
    addErrorOption(c, "Back")
    return c
end function

sub showErrorDialog()
    m.errorMsg.text = "Couldn't play this stream."
    m.errorOptions.content = buildErrorOptions()
    m.errorDialog.visible = true
    m.errorOptions.setFocus(true)
end sub

sub onErrorOptionSelected()
    idx = m.errorOptions.itemSelected
    if idx = 0 ' Retry
        if m.currentIndex >= 0 then playIndex(m.currentIndex)
    else if idx = 1 ' Next channel
        zapDown()
    else if idx = 2 ' Toggle favorite
        if m.currentIndex >= 0 and m.top.playlist <> invalid
            ch = m.top.playlist[m.currentIndex]
            if ch <> invalid
                isFav = ToggleFavorite(ch.name)
                if isFav
                    showToast("Added to favorites")
                else
                    showToast("Removed from favorites")
                end if
                ' rebuild the menu (option label changed), keep the dialog open
                m.errorOptions.content = buildErrorOptions()
                m.errorOptions.setFocus(true)
            end if
        end if
    else if idx = 3 ' Back
        exitPlayer()
    end if
end sub

sub showOverlay()
    ' The two panels overlap. Without this the banner draws on top of the overlay
    ' whenever OK is pressed within the banner's few seconds.
    hideMiniBanner()
    m.overlayGroup.visible = true
    updateClock()
    m.clockTimer.control = "start"
    m.overlayTimer.control = "start"
end sub

sub hideOverlay()
    m.overlayGroup.visible = false
    m.clockTimer.control = "stop"
end sub

sub updateOverlayData(channel as object)
    m.overlayName.text = channel.name
    if channel.group <> invalid
        m.overlayGroupLabel.text = channel.group
    else
        m.overlayGroupLabel.text = ""
    end if
    
    info = EpgFind(m.global.epg, channel.name, m.global.nowSec)
    s = ""
    if info.now <> invalid then s = "Now: " + info.now.t + " (" + EpgFmtHM(info.now.s) + "-" + EpgFmtHM(info.now.e) + ")"
    if info.next <> invalid then s = s + "   Next: " + info.next.t
    m.overlayEpg.text = s
end sub

' Row 1 is always the channel. Row 2 is the programme when the guide has one, and
' the channel's category when it does not -- roughly two thirds of channels have no
' guide at all, and the whole Sport2 category has none, so a "no programme
' information" string would be the most-shown text in the app and would repeat for
' hundreds of consecutive zaps. The category is always true, always non-empty
' (M3uParser falls back to "Uncategorized") and tells the viewer where they are.
' Which of the two it is reads from the colour, from the presence of the end time,
' and from the progress foot -- three signals, no layout change either way.
sub showMiniBanner(channel as object)
    if channel = invalid then return

    m.miniBannerLabel.text = channel.name

    info = EpgFind(m.global.epg, channel.name, m.global.nowSec)
    dur = 3.0
    if info.now <> invalid
        m.zapLine2.text = info.now.t
        m.zapLine2.color = m.theme.colorText
        m.zapUntil.text = "until " + EpgFmtHM(info.now.e)
        setZapProgress(info.now)
        dur = 4.5          ' more to read; every zap restarts the timer, so a burst
                           ' only ever runs the LAST banner to completion
    else
        grp = ""
        if channel.group <> invalid then grp = channel.group
        m.zapLine2.text = grp
        m.zapLine2.color = m.theme.colorTextDim
        m.zapUntil.text = ""
        m.zapProgress.visible = false
    end if

    m.miniBanner.visible = true
    ' Assigning duration to a RUNNING timer is unreliable: stop, set, start.
    m.miniBannerTimer.control = "stop"
    m.miniBannerTimer.duration = dur
    m.miniBannerTimer.control = "start"
end sub

' Computed once, at show time. The banner lives 3-4.5s, over which the bar would
' move about 0.05% of its width -- observing nowSec to animate it would be pure cost
' on the zap hot path.
sub setZapProgress(prog as object)
    span = prog.e - prog.s
    if span <= 0
        m.zapProgress.visible = false
        return
    end if
    nowSec = m.global.nowSec
    if nowSec = invalid or nowSec <= 0 then nowSec = CreateObject("roDateTime").AsSeconds()
    frac = (nowSec - prog.s) / span
    if frac < 0 then frac = 0
    if frac > 1 then frac = 1
    w = Int(1040 * frac)
    if w < 8 then w = 8   ' a just-started programme must not read as "no data"
    m.zapProgress.width = w
    m.zapProgress.visible = true
end sub

sub hideMiniBanner()
    m.miniBannerTimer.control = "stop"
    m.miniBanner.visible = false
end sub

sub showToast(msg as string)
    m.toastLabel.text = msg
    m.toastBg.visible = true
    m.toastTimer.control = "start"
end sub

sub hideToast()
    m.toastBg.visible = false
end sub

sub onOkLongPress()
    m.okLongFired = true
    if m.currentIndex < 0 or m.top.playlist = invalid then return
    ch = m.top.playlist[m.currentIndex]
    if ch = invalid then return
    isFav = ToggleFavorite(ch.name)
    if isFav
        showToast("Added to favorites")
    else
        showToast("Removed from favorites")
    end if
end sub

sub updateClock()
    dt = CreateObject("roDateTime")
    dt.ToLocalTime()
    h = dt.GetHours().ToStr()
    m_str = dt.GetMinutes().ToStr()
    if h.Len() = 1 then h = "0" + h
    if m_str.Len() = 1 then m_str = "0" + m_str
    m.overlayTime.text = h + ":" + m_str
end sub

sub zapUp()
    zap(-1)
end sub

sub zapDown()
    zap(1)
end sub

sub zap(stepDelta as integer)
    if m.top.playlist = invalid or m.top.playlist.Count() = 0 return
    
    count = m.top.playlist.Count()
    idx = m.currentIndex
    
    for i = 1 to count
        idx = idx + stepDelta
        if idx < 0
            idx = count - 1
        else if idx >= count
            idx = 0
        end if
        
        ch = m.top.playlist[idx]
        if ch <> invalid and ch.compatible = true
            playIndex(idx)
            return
        end if
    end for
end sub

sub exitPlayer()
    m.video.control = "stop"
    m.errorDialog.visible = false
    m.top.exitRequested = not m.top.exitRequested
end sub

sub openZapper()
    if m.top.playlist = invalid or m.top.playlist.Count() = 0 then return
    ' Time the rebuild. This runs on the render thread, so it must be the GLOBAL Uptime()
    ' and never CreateObject("roTimespan") -- that is a MAIN|TASK-only component and rule
    ' 20 makes it a hard failure here. The number settles a standing open item: the panel
    ' recreates every node on every open, and nobody has ever measured whether that costs
    ' anything on 1548 channels or is lost in the noise.
    t0 = Uptime(0)
    ' hide overlay/banner
    hideOverlay()
    hideMiniBanner()
    ' build content from the current category
    root = CreateObject("roSGNode", "ContentNode")
    
    favSet = {}
    favs = LoadFavorites()
    if favs <> invalid
        for each f in favs
            favSet[f] = true
        end for
    end if
    
    for each ch in m.top.playlist
        item = root.createChild("ChannelContent")
        item.name = ch.name
        item.favorite = (favSet[ch.name] <> invalid)
        item.compatible = (ch.compatible = true)
    end for
    m.zapperGrid.content = root
    if m.currentIndex >= 0 then m.zapperGrid.jumpToItem = m.currentIndex
    m.zapperPanel.visible = true
    m.zapperGrid.setFocus(true)         ' focus the GRID, not the panel (rule #9)
    m.zapperTimer.control = "start"
    ' Index, never the group title: the console on 8085 is unauthenticated, and one of
    ' this playlist's categories is one the owner would not want printed.
    print "[ZAPPER] open items="; m.top.playlist.Count(); " ms="; Int((Uptime(0) - t0) * 1000)
end sub

sub focusPlayer()
    if m.errorOptions <> invalid then m.errorOptions.setFocus(false)
    if m.zapperGrid <> invalid then m.zapperGrid.setFocus(false)
    m.top.setFocus(true)
end sub

sub closeZapper()
    m.zapperTimer.control = "stop"
    m.zapperPanel.visible = false
    focusPlayer()
end sub

sub onZapperFocused()
    ' activity — restart auto-hide
    if m.zapperPanel.visible
        m.zapperTimer.control = "stop"
        m.zapperTimer.control = "start"
    end if
end sub

sub onZapperSelected()
    if not m.zapperPanel.visible then return   ' panel hidden — ignore
    idx = m.zapperGrid.itemSelected
    if idx = invalid or m.top.playlist = invalid then return
    if idx < 0 or idx >= m.top.playlist.Count() then return
    ch = m.top.playlist[idx]
    if ch = invalid then return
    if ch.compatible <> true
        showToast("Stream not supported")
        return                          ' keep the panel open, don't change channel
    end if
    closeZapper()
    playIndex(idx)                      ' playIndex focuses the player and updates everything
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false
    if m.zapperPanel.visible
        if press
            m.zapperTimer.control = "stop"
            m.zapperTimer.control = "start"
            if key = "back"
                closeZapper()
                handled = true
            else if key = "up" or key = "down" or key = "OK"
                handled = false                 ' navigation and select go to the grid
            else if key = "left" or key = "right" or key = "options"
                handled = true                  ' swallow
            end if
        else
            if key = "back" or key = "left" or key = "right" or key = "options"
                handled = true
            end if
        end if
    else if m.errorDialog.visible
        if press
            if key = "back"
                exitPlayer()
                handled = true
            else if key = "OK" or key = "up" or key = "down"
                ' Let errorOptions handle it
                handled = false
            end if
        end if
    else
        if key = "OK"
            if press
                m.okLongFired = false
                m.okTimer.control = "start"
                handled = true
            else
                m.okTimer.control = "stop"
                if m.okLongFired = false
                    if m.overlayGroup.visible
                        hideOverlay()
                    else
                        showOverlay()
                    end if
                end if
                handled = true
            end if
        else if press
            if key = "back"
                exitPlayer()
                handled = true
            else if key = "up"
                zapUp()
                handled = true
            else if key = "down"
                zapDown()
                handled = true
            else if key = "left"
                openZapper()
                handled = true
            else if key = "options"
                if m.currentIndex >= 0 and m.top.playlist <> invalid
                    ch = m.top.playlist[m.currentIndex]
                    isFav = ToggleFavorite(ch.name)
                    if isFav
                        showToast("Added to favorites")
                    else
                        showToast("Removed from favorites")
                    end if
                end if
                handled = true
            end if
        end if
    end if
    return handled
end function
