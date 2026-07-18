' PlayerScreen
sub init()
    m.video = m.top.findNode("video")
    m.spinner = m.top.findNode("spinner")
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
    
    errContent = CreateObject("roSGNode", "ContentNode")
    addErrorOption(errContent, "Retry")
    addErrorOption(errContent, "Next channel")
    addErrorOption(errContent, "Back")
    m.errorOptions.content = errContent
    
    theme = getTheme()
    if theme <> invalid
        m.overlayName.color = theme.colorText
        m.overlayGroupLabel.color = theme.colorFocusBright
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
    
    PushRecent(channel.name)
    
    m.errorDialog.visible = false
    
    showMiniBanner(channel.name)
    updateOverlayData(channel)
    
    focusPlayer()
end sub

sub onVideoStateChange()
    state = m.video.state
    if state = "buffering"
        m.spinner.visible = true
        m.spinner.control = "start"
        m.loadingLabel.visible = true
        if m.currentIndex >= 0 and m.top.playlist <> invalid
            m.loadingLabel.text = "Loading: " + m.top.playlist[m.currentIndex].name
        else
            m.loadingLabel.text = "Loading…"
        end if
    else if state = "playing"
        m.spinner.visible = false
        m.spinner.control = "stop"
        m.loadingLabel.visible = false
    else if state = "error"
        m.spinner.visible = false
        m.spinner.control = "stop"
        m.loadingLabel.visible = false
        showErrorDialog()
    end if
end sub

sub showErrorDialog()
    m.errorMsg.text = "Couldn't play this stream."
    m.errorDialog.visible = true
    m.errorOptions.setFocus(true)
end sub

sub onErrorOptionSelected()
    idx = m.errorOptions.itemSelected
    if idx = 0 ' Повторить
        if m.currentIndex >= 0
            playIndex(m.currentIndex)
        end if
    else if idx = 1 ' Следующий
        zapDown()
    else if idx = 2 ' Назад
        exitPlayer()
    end if
end sub

sub showOverlay()
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
    
    info = EpgFind(m.global.epg, channel.name)
    s = ""
    if info.now <> invalid then s = "Now: " + info.now.t + " (" + EpgFmtHM(info.now.s) + "-" + EpgFmtHM(info.now.e) + ")"
    if info.next <> invalid then s = s + "   Next: " + info.next.t
    m.overlayEpg.text = s
end sub

sub showMiniBanner(name as string)
    m.miniBannerLabel.text = name
    m.miniBanner.visible = true
    m.miniBannerTimer.control = "start"
end sub

sub hideMiniBanner()
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
    if IsFavorite(ch.name)
        showToast("Already in favorites")
    else
        ToggleFavorite(ch.name)
        showToast("Added to favorites")
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
    ' спрятать оверлей/баннер
    hideOverlay()
    hideMiniBanner()
    ' собрать content из текущей категории
    root = CreateObject("roSGNode", "ContentNode")
    
    favSet = {}
    favs = LoadFavorites()
    if favs <> invalid
        for each f in favs
            favSet[f] = true
        end for
    end if
    
    for each ch in m.top.playlist
        item = root.createChild("ContentNode")
        item.addField("name", "string", false)
        item.addField("favorite", "boolean", false)
        item.addField("compatible", "boolean", false)
        item.name = ch.name
        item.favorite = (favSet[ch.name] <> invalid)
        item.compatible = (ch.compatible = true)
    end for
    m.zapperGrid.content = root
    if m.currentIndex >= 0 then m.zapperGrid.jumpToItem = m.currentIndex
    m.zapperPanel.visible = true
    m.zapperGrid.setFocus(true)         ' фокус на СЕТКУ, не на панель (правило #9)
    m.zapperTimer.control = "start"
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
    ' активность — перезапустить авто-скрытие
    if m.zapperPanel.visible
        m.zapperTimer.control = "stop"
        m.zapperTimer.control = "start"
    end if
end sub

sub onZapperSelected()
    if not m.zapperPanel.visible then return   ' <-- ДОБАВИТЬ: панель скрыта — игнор
    idx = m.zapperGrid.itemSelected
    if idx = invalid or m.top.playlist = invalid then return
    if idx < 0 or idx >= m.top.playlist.Count() then return
    ch = m.top.playlist[idx]
    if ch = invalid then return
    if ch.compatible <> true
        showToast("Stream not supported")
        return                          ' панель НЕ закрываем, канал НЕ меняем
    end if
    closeZapper()
    playIndex(idx)                      ' playIndex сам ставит фокус плееру и обновляет всё
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
                handled = false                 ' навигация и выбор — сетке
            else if key = "left" or key = "right" or key = "options"
                handled = true                  ' глушим
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
