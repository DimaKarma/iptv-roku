' SearchScreen: a branded field, a five-column result grid and a modal Keyboard.
'
' Focus model. The field is drawn by this screen (fieldBg / fieldLabel) and is "focused"
' when this component itself holds focus, so Down, OK and Back all arrive in onKeyEvent
' (a one-row LabelList wraps and would swallow Down). The grid and the keyboard are the
' two other holders; the helpers focusField / focusGrid are the only places that move it,
' and focusField clears the child holders FIRST (rule 13).

sub init()
    m.fieldBg = m.top.findNode("fieldBg")
    m.fieldLabel = m.top.findNode("fieldLabel")
    m.headerLabel = m.top.findNode("headerLabel")
    m.channelGrid = m.top.findNode("channelGrid")
    m.statusLabel = m.top.findNode("statusLabel")
    m.keyboardBg = m.top.findNode("keyboardBg")
    m.keyboard = m.top.findNode("keyboard")
    m.keyboardHint = m.top.findNode("keyboardHint")
    
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    
    m.searchTimer = m.top.findNode("searchTimer")
    m.toastTimer = m.top.findNode("toastTimer")
    
    m.gridCols = m.channelGrid.numColumns
    if m.gridCols < 1 then m.gridCols = 1
    
    m.keyboard.observeField("text", "onTextChanged")
    m.searchTimer.observeField("fire", "performSearch")
    m.channelGrid.observeField("itemSelected", "onChannelSelected")
    m.toastTimer.observeField("fire", "hideToast")
    m.top.observeField("visible", "onVisibleChange")
    
    m.theme = getTheme()
    theme = m.theme
    if theme <> invalid
        m.headerLabel.color = theme.colorText
        m.statusLabel.color = theme.colorTextDim
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
        m.keyboardHint.color = theme.colorText
        m.channelGrid.itemSpacing = [theme.spacingUnit, theme.spacingUnit]
    end if
    
    m.allChannels = []
    m.byName = {}
    m.currentChannels = []
    ' Set when a play request leaves this screen; read (and cleared) by the visible
    ' handler when the screen comes back, so that path does not steal focus to the field.
    m.returning = false
    m.playIdx = 0
    ' OK on the field opens the keyboard on RELEASE, and only if this screen saw the
    ' press. Opening it on the press would send the release to the Keyboard, which could
    ' read it as a key press and type a character.
    m.okArmed = false
    
    CenterKeyboard(m.keyboard, 250)
    updateFieldText("")
    setFieldFocus(false)
end sub

' The screen was shown. Back from the player (m.returning): keep everything, focus the
' card that was played. Otherwise: refresh the list (Recent and the favourite stars can
' have changed since the last visit) and focus the field.
sub onVisibleChange()
    if not m.top.visible then return
    if m.returning
        m.returning = false
        restoreGrid()
    else
        performSearch()
        focusField()
    end if
end sub

' MainScene toggles this after making the screen visible again. Idempotent with the
' branch above, so the order of the two observers does not matter.
sub onRestoreFocus()
    restoreGrid()
end sub

sub restoreGrid()
    refreshStars()
    if hasItems()
        idx = m.playIdx
        if idx < 0 or idx >= m.channelGrid.content.getChildCount() then idx = 0
        m.channelGrid.jumpToItem = idx
        focusGrid()
    else
        focusField()
    end if
end sub

' Read m.top.channels ONCE here; nothing else reads the interface field.
sub onChannelsChange()
    m.allChannels = m.top.channels
    if m.allChannels = invalid then m.allChannels = []
    m.byName = {}
    for each ch in m.allChannels
        if ch.name <> invalid
            if m.byName[ch.name] = invalid then m.byName[ch.name] = ch
        end if
    end for
end sub

function hasItems() as boolean
    if m.channelGrid.content = invalid then return false
    return m.channelGrid.content.getChildCount() > 0
end function

sub focusField()
    m.channelGrid.setFocus(false)
    m.keyboard.setFocus(false)
    m.top.setFocus(true)
    setFieldFocus(true)
end sub

sub focusGrid()
    m.channelGrid.setFocus(true)
    setFieldFocus(false)
end sub

' Accent chip with on-accent text when selected, surface with dim text otherwise.
sub setFieldFocus(isOn as boolean)
    if m.theme = invalid then return
    if isOn
        m.fieldBg.color = m.theme.colorFocus
        m.fieldLabel.color = m.theme.colorOnAccent
    else
        m.fieldBg.color = m.theme.colorSurface
        m.fieldLabel.color = m.theme.colorTextDim
    end if
end sub

sub updateFieldText(query as string)
    if query = ""
        m.fieldLabel.text = "Search: press OK to type"
    else
        m.fieldLabel.text = "Search: " + query
    end if
end sub

sub openKeyboard()
    m.keyboardBg.visible = true
    ' Again here: boundingRect() can be zero before the first layout.
    CenterKeyboard(m.keyboard, 250)
    m.keyboard.setFocus(true)
end sub

sub closeKeyboard()
    m.keyboardBg.visible = false
    m.keyboard.setFocus(false)
    ' Do not wait for the 0.3 s timer: the results must match what was typed.
    m.searchTimer.control = "stop"
    performSearch()
    if hasItems()
        focusGrid()
    else
        focusField()
    end if
end sub

sub onTextChanged()
    m.searchTimer.control = "start"
end sub

sub performSearch()
    query = m.keyboard.text
    if query = invalid then query = ""
    updateFieldText(query)
    
    ' No query yet (or one character): the Recent channels.
    if Len(query) < 2
        showRecent(query)
        return
    end if
    
    qLower = LCase(query)
    qSk = NameSkeleton(query)
    qSkLen = Len(qSk)
    favSet = buildFavSet()
    
    ' Ranking: favourites, then names whose skeleton STARTS with the query's, then the
    ' rest; within each group the playlist order is kept.
    favHits = []
    prefixHits = []
    restHits = []
    total = 0
    
    for each ch in m.allChannels
        nm = ch.name
        if nm <> invalid
            sk = ch.sk
            if sk = invalid then sk = ""
            
            ' A match is the skeleton of the query inside the skeleton of the name, OR the
            ' raw lower-cased query inside the lower-cased name (the old behaviour).
            matched = false
            if qSkLen > 0 and sk <> ""
                if Instr(1, sk, qSk) > 0 then matched = true
            end if
            if not matched
                if Instr(1, LCase(nm), qLower) > 0 then matched = true
            end if
            if not matched
                if ch.tvgName <> invalid
                    if ch.tvgName <> ""
                        if Instr(1, LCase(ch.tvgName), qLower) > 0 then matched = true
                    end if
                end if
            end if
            
            if matched
                total = total + 1
                if favSet[nm] <> invalid
                    favHits.Push(ch)
                else if qSkLen > 0 and Left(sk, qSkLen) = qSk
                    prefixHits.Push(ch)
                else
                    restHits.Push(ch)
                end if
            end if
        end if
    end for
    
    ' At most 60 are drawn.
    shown = []
    for each part in [favHits, prefixHits, restHits]
        for each ch in part
            if shown.Count() >= 60 then exit for
            shown.Push(ch)
        end for
    end for
    
    showResults(shown, favSet)
    
    if total > 60
        m.headerLabel.text = total.ToStr() + " found, showing 60"
    else
        m.headerLabel.text = total.ToStr() + " found"
    end if
    if total = 0
        m.statusLabel.text = "Nothing found"
    end if
end sub

' The Recent channels, newest first, resolved against the playlist by name.
sub showRecent(query as string)
    favSet = buildFavSet()
    shown = []
    recents = LoadRecents()
    if recents <> invalid
        for each r in recents
            ch = m.byName[r]
            if ch <> invalid then shown.Push(ch)
        end for
    end if
    
    showResults(shown, favSet)
    m.headerLabel.text = "Recent"
    if shown.Count() = 0
        if query = ""
            m.statusLabel.text = "Press OK, then type to search"
        else
            m.statusLabel.text = "Type at least 2 characters"
        end if
    end if
end sub

' Put `shown` into the grid and remember it as the play list. Sets the status label
' hidden when there are items; callers set its text when there are none.
sub showResults(shown as object, favSet as object)
    gridContent = CreateObject("roSGNode", "ContentNode")
    for each ch in shown
        addChannel(gridContent, ch, (favSet[ch.name] <> invalid))
    end for
    m.currentChannels = shown
    m.channelGrid.content = gridContent
    if shown.Count() > 0
        m.statusLabel.visible = false
        m.channelGrid.jumpToItem = 0
    else
        m.statusLabel.visible = true
    end if
end sub

function buildFavSet() as object
    favSet = {}
    favs = LoadFavorites()
    if favs <> invalid
        for each f in favs
            favSet[f] = true
        end for
    end if
    return favSet
end function

' After the player: favourites may have been toggled there.
sub refreshStars()
    content = m.channelGrid.content
    if content = invalid then return
    favSet = buildFavSet()
    for i = 0 to content.getChildCount() - 1
        child = content.getChild(i)
        if child <> invalid then child.favorite = (favSet[child.name] <> invalid)
    end for
end sub

sub addChannel(parent as object, ch as object, isFav as boolean)
    item = parent.createChild("ChannelContent")
    
    item.name = ch.name
    item.url = ch.url
    item.group = ch.group
    item.logo = ch.logo
    item.compatible = ch.compatible
    item.favorite = isFav
end sub

sub onChannelSelected()
    idx = m.channelGrid.itemSelected
    if m.channelGrid.content = invalid return
    item = m.channelGrid.content.getChild(idx)
    if item = invalid return
    
    if item.compatible
        ' Remember the card BEFORE the request leaves: Back from the player returns to it.
        m.playIdx = idx
        m.returning = true
        m.top.playRequest = { channels: m.currentChannels, index: idx }
    else
        showToast("Stream not supported")
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false
    if key = "OK" and not press
        if m.okArmed
            m.okArmed = false
            if not m.keyboardBg.visible and not m.channelGrid.hasFocus() then openKeyboard()
            return true
        end if
        return false
    end if
    if press
        if m.keyboardBg.visible
            ' Rule 8: the Keyboard swallows every arrow; only Back reaches here.
            if key = "back"
                closeKeyboard()
                handled = true
            end if
        else if m.channelGrid.hasFocus()
            if key = "back"
                focusField()
                handled = true
            else if key = "up"
                if m.channelGrid.itemFocused < m.gridCols
                    focusField()
                    handled = true
                end if
            else if key = "options"
                idx = m.channelGrid.itemFocused
                if m.channelGrid.content <> invalid
                    item = m.channelGrid.content.getChild(idx)
                    if item <> invalid
                        isFav = ToggleFavorite(item.name)
                        item.favorite = isFav
                        if isFav
                            showToast("Added to favorites")
                        else
                            showToast("Removed from favorites")
                        end if
                    end if
                end if
                handled = true
            end if
        else
            ' The field is selected.
            if key = "down"
                if hasItems() then focusGrid()
                handled = true
            else if key = "OK"
                m.okArmed = true
                handled = true
            else if key = "back"
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
