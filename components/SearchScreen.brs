' SearchScreen: modal keyboard, OK/Back navigation

sub init()
    m.searchButton = m.top.findNode("searchButton")
    m.hintLabel = m.top.findNode("hintLabel")
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
    
    m.keyboard.observeField("text", "onTextChanged")
    m.searchTimer.observeField("fire", "performSearch")
    m.channelGrid.observeField("itemSelected", "onChannelSelected")
    m.searchButton.observeField("buttonSelected", "onSearchButtonSelected")
    m.toastTimer.observeField("fire", "hideToast")
    m.top.observeField("visible", "onVisibleChange")
    
    theme = getTheme()
    if theme <> invalid
        m.hintLabel.color = theme.colorTextDim
        m.headerLabel.color = theme.colorText
        m.statusLabel.color = theme.colorTextDim
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
        m.channelGrid.itemSpacing = [theme.spacingUnit, theme.spacingUnit]
    end if
    
    m.allChannels = []
    m.currentChannels = []
end sub

sub onVisibleChange()
    if m.top.visible then m.searchButton.setFocus(true)
end sub

sub onChannelsChange()
    m.allChannels = m.top.channels
    if m.allChannels = invalid then m.allChannels = []
end sub

sub onSearchButtonSelected()
    m.keyboardBg.visible = true
    m.keyboard.setFocus(true)
end sub

sub onTextChanged()
    m.searchTimer.control = "start"
end sub

sub performSearch()
    query = m.keyboard.text
    
    if Len(query) < 2
        m.channelGrid.content = CreateObject("roSGNode", "ContentNode")
        m.headerLabel.text = ""
        m.statusLabel.visible = true
        m.statusLabel.text = "Type at least 2 characters"
        if query <> ""
            m.searchButton.text = "Search: " + query
        else
            m.searchButton.text = "Search: (press OK)"
        end if
        return
    end if
    
    favs = LoadFavorites()
    qLower = LCase(query)
    
    gridContent = CreateObject("roSGNode", "ContentNode")
    m.currentChannels = []
    matchCount = 0
    
    for each ch in m.allChannels
        nameLower = LCase(ch.name)
        tvgLower = ""
        if ch.tvgName <> invalid then tvgLower = LCase(ch.tvgName)
        
        if Instr(1, nameLower, qLower) > 0 or (tvgLower <> "" and Instr(1, tvgLower, qLower) > 0)
            isFav = false
            if favs <> invalid
                for each f in favs
                    if f = ch.name
                        isFav = true
                        exit for
                    end if
                end for
            end if
            
            addChannel(gridContent, ch, isFav)
            m.currentChannels.Push(ch)
            matchCount = matchCount + 1
        end if
    end for
    
    m.channelGrid.content = gridContent
    m.searchButton.text = "Search: " + query
    
    if matchCount > 0
        m.headerLabel.text = "Found: " + matchCount.ToStr()
        m.statusLabel.visible = false
        m.channelGrid.jumpToItem = 0
    else
        m.headerLabel.text = "Found: 0"
        m.statusLabel.visible = true
        m.statusLabel.text = "Nothing found"
    end if
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
        m.top.playRequest = { channels: m.currentChannels, index: idx }
    else
        showToast("Stream not supported")
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false
    if press
        if m.keyboardBg.visible
            if key = "back"
                m.keyboardBg.visible = false
                if m.channelGrid.content <> invalid and m.channelGrid.content.getChildCount() > 0
                    m.channelGrid.setFocus(true)
                else
                    m.searchButton.setFocus(true)
                end if
                handled = true
            else
                handled = false
            end if
        else
            if key = "back"
                if m.channelGrid.hasFocus()
                    m.searchButton.setFocus(true)
                    handled = true
                else
                    m.top.exitRequested = not m.top.exitRequested
                    handled = true
                end if
            else if key = "options" and m.channelGrid.hasFocus()
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
            else
                handled = false
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
