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
    m.stallTimer = m.top.findNode("stallTimer")
    m.recentTimer = m.top.findNode("recentTimer")
    
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
    m.stallTimer.observeField("fire", "onStallTimeout")
    m.recentTimer.observeField("fire", "onRecentTimer")
    
    m.zapperGrid.observeField("itemSelected", "onZapperSelected")
    m.zapperGrid.observeField("itemFocused", "onZapperFocused")
    m.zapperTimer.observeField("fire", "closeZapper")
    
    m.okLongFired = false
    ' True only between an OK PRESS that this screen saw and its release. The release is
    ' acted on only when armed: a press that went to another node (the error dialog's
    ' list, the zapper) must not turn its release into an action here.
    m.okArmed = false
    ' Stall watchdog and delayed Recent. hasPlayed: a `playing` was seen since the last
    ' playIndex. recentPending: the Recent timer is still to be armed by that `playing`.
    ' recentName: the channel the Recent timer was armed for (invalid = adult group).
    m.hasPlayed = false
    m.recentPending = false
    m.recentName = invalid
    ' False once the player was left. A late `error` or `finished` from the stopped video
    ' must not open the dialog and take focus from the screen that now has it.
    m.active = false
    
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
        m.errorOptions.focusedColor = theme.colorOnAccent
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
    m.active = true
    channel = m.top.playlist[idx]
    
    node = CreateObject("roSGNode", "ContentNode")
    node.title = channel.name
    node.url = channel.url
    node.streamFormat = "hls"
    
    m.video.content = node
    m.video.control = "play"
    
    ' Recent is no longer written here: a zap through ten channels used to push all ten.
    ' It is written by recentTimer, 10 s after the first `playing` of THIS channel. The
    ' adult-group exclusion is applied here, when the name is captured.
    disarmRecentTimer()
    m.hasPlayed = false
    m.recentPending = true
    if IsAdultGroup(channel.group)
        m.recentName = invalid
        ' The only delete site of the stored resume channel in the player: playing an
        ' adult-group channel at all removes it, and nothing derived from it is stored.
        ClearLastChannel()
    else
        m.recentName = channel.name
    end if
    armStallWatchdog(20.0)
    
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
        ' A buffering AFTER playing restarts the watchdog at 30 s. The first buffering of
        ' a new channel keeps the 20 s one that playIndex armed.
        if m.hasPlayed then armStallWatchdog(30.0)
    else if state = "playing"
        m.spinner.visible = false
        m.spinnerAnim.control = "stop"
        m.loadingLabel.visible = false
        disarmStallWatchdog()
        m.hasPlayed = true
        if m.recentPending
            m.recentPending = false
            armRecentTimer()
        end if
    else if state = "error"
        failPlayback("Couldn't play this stream.")
    else if state = "finished"
        ' A `finished` from the OUTGOING stream can land after playIndex started the next
        ' one. Until the current stream has reached `playing` it is not ours to act on.
        if not m.hasPlayed then return
        ' A live stream that ends is a failure from the viewer's side.
        failPlayback("The stream ended.")
    end if
end sub

' Common tail of `error`, `finished` and a watchdog fire: nothing may fire later for
' this channel, the spinner goes, the dialog opens.
sub failPlayback(reason as string)
    if not m.active then return
    disarmStallWatchdog()
    disarmRecentTimer()
    m.spinner.visible = false
    m.spinnerAnim.control = "stop"
    m.loadingLabel.visible = false
    showErrorDialog(reason)
end sub

' (Re)start the stall watchdog. Stop, set, start: assigning duration to a running timer
' is unreliable (see showMiniBanner).
sub armStallWatchdog(seconds as float)
    m.stallTimer.control = "stop"
    m.stallTimer.duration = seconds
    m.stallTimer.control = "start"
end sub

sub disarmStallWatchdog()
    m.stallTimer.control = "stop"
end sub

' The stream never reached `playing` in time (or stalled after it): stop it, then the
' same dialog as a hard error.
sub onStallTimeout()
    m.video.control = "stop"
    failPlayback("Stream is not responding.")
end sub

sub armRecentTimer()
    m.recentTimer.control = "stop"
    m.recentTimer.duration = 10.0
    m.recentTimer.control = "start"
end sub

' Also forgets the pending state, so a later `playing` of the SAME channel (after a
' stall, say) cannot arm a timer that playIndex or exitPlayer already cancelled.
sub disarmRecentTimer()
    m.recentTimer.control = "stop"
    m.recentPending = false
end sub

' Fires 10 s after playback started: the channel it was armed for goes into Recent.
sub onRecentTimer()
    if m.recentName <> invalid
        PushRecent(m.recentName)
        ' The only write site of the resume channel. The argument is m.recentName, the
        ' name captured when THIS timer was armed, never the playlist entry at the
        ' current index (a zap in the meantime must not store the channel zapped to).
        SaveLastChannel(m.recentName)
        m.recentName = invalid
    end if
end sub

' Labels and actions are written in ONE pass into two parallel lists, so the menu's length
' and its behaviour cannot drift apart. This menu is now variable-length, and the dispatch
' below reads m.errorActions rather than a fixed index -- with hardcoded indices, dropping
' one row would silently move "Back" from 3 to 2, so Back would do nothing and index 2
' would toggle favourites on a channel that has none.
function buildErrorOptions() as object
    c = CreateObject("roSGNode", "ContentNode")
    m.errorActions = []

    addErrorOption(c, "Retry")
    m.errorActions.Push("retry")

    addErrorOption(c, "Next channel")
    m.errorActions.Push("next")

    ' Offered ONLY when the channel already is a favourite. This dialog is open because the
    ' stream would not play, so inviting the user to bookmark it made no sense. The REMOVE
    ' case is the reason the option exists at all (TASK-18 Part B): a dead favourite cannot
    ' be removed from the grid, because this dialog holds the focus.
    isFav = false
    if m.currentIndex >= 0 and m.top.playlist <> invalid
        ch = m.top.playlist[m.currentIndex]
        if ch <> invalid then isFav = IsFavorite(ch.name)
    end if
    if isFav
        addErrorOption(c, "Remove from favorites")
        m.errorActions.Push("fav")
    end if

    addErrorOption(c, "Back")
    m.errorActions.Push("back")

    return c
end function

sub showErrorDialog(reason as string)
    m.okTimer.control = "stop"
    m.okArmed = false
    ' The dialog is about to take focus, so nothing else may be holding it or running.
    disarmStallWatchdog()
    ' The zapper panel can be open (select a dead channel in it, wait, and its 5 s timer
    ' used to take the focus back from this list). closeZapper() BEFORE the dialog takes
    ' focus, never after: it ends in focusPlayer(), which would steal it.
    closeZapper()
    msg = reason
    code = m.video.errorCode
    if code <> invalid
        if code <> 0 then msg = msg + " (code " + code.ToStr() + ")"
    end if
    m.errorMsg.text = msg
    m.errorOptions.content = buildErrorOptions()
    m.errorDialog.visible = true
    m.errorOptions.setFocus(true)
end sub

sub onErrorOptionSelected()
    idx = m.errorOptions.itemSelected
    ' Bound-check rather than trust. itemSelected is a plain integer and can outlive the
    ' menu it indexed: the favourite row removes itself, so the content is rebuilt one row
    ' shorter while the cursor still holds the old position.
    if m.errorActions = invalid or idx < 0 or idx >= m.errorActions.Count() then return
    action = m.errorActions[idx]

    if action = "retry"
        if m.currentIndex >= 0 then playIndex(m.currentIndex)
    else if action = "next"
        zapDown()
    else if action = "fav"
        if m.currentIndex >= 0 and m.top.playlist <> invalid
            ch = m.top.playlist[m.currentIndex]
            if ch <> invalid
                ' The row is only built for a channel that IS a favourite, and nothing can
                ' change that while this dialog holds focus -- onKeyEvent's errorDialog
                ' branch passes only back/OK/up/down, so the "*" toggle cannot reach the
                ' player here. So this is always a removal today. The toast still reports
                ' what ToggleFavorite actually DID rather than what that reasoning predicts,
                ' because the reasoning is about the current key handling and the toast
                ' should not start lying if that changes.
                isFav = ToggleFavorite(ch.name)
                if isFav
                    showToast("Added to favorites")
                else
                    showToast("Removed from favorites")
                end if
                ' Rebuild, because the row just removed itself. Replacing `content` resets
                ' the list to its first item on its own, so no jumpToItem is needed --
                ' and note this LabelList PINS the focused row at the top of the panel and
                ' scrolls the items under it, so "which row is highlighted" cannot be read
                ' from a screenshot by y-coordinate. Press an arrow and compare two
                ' captures instead.
                m.errorOptions.content = buildErrorOptions()
                m.errorOptions.setFocus(true)
            end if
        end if
    else if action = "back"
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
    ' The player must not act while it is not the active screen. The error dialog's "Back" row
    ' calls exitPlayer() on the OK press, and that same press can still reach onKeyEvent and arm
    ' this timer; its release goes to ChannelsScreen, so the timer fires on a dead player and
    ' would silently favourite the dead channel.
    if m.active <> true or m.errorDialog.visible or m.zapperPanel.visible then return
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
    m.okTimer.control = "stop"
    m.okArmed = false
    disarmStallWatchdog()
    disarmRecentTimer()
    m.hasPlayed = false
    m.active = false
    m.video.control = "stop"
    m.errorDialog.visible = false
    m.top.exitRequested = not m.top.exitRequested
end sub

sub openZapper()
    m.okTimer.control = "stop"
    m.okArmed = false
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
                ' Never arm the long-press timer once exitPlayer() has run (m.active = false).
                if m.active <> true then return true
                m.okLongFired = false
                m.okArmed = true
                m.okTimer.control = "start"
                handled = true
            else
                m.okTimer.control = "stop"
                if m.okArmed and m.okLongFired = false
                    if m.overlayGroup.visible
                        hideOverlay()
                    else
                        showOverlay()
                    end if
                end if
                m.okArmed = false
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
