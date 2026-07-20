' ChannelsScreen: rail and grid

sub init()
    m.categoryList = m.top.findNode("categoryList")
    m.channelGrid = m.top.findNode("channelGrid")
    m.gridCols = m.channelGrid.numColumns
    if m.gridCols < 1 then m.gridCols = 1
    m.headerLabel = m.top.findNode("headerLabel")
    m.emptyLabel = m.top.findNode("emptyLabel")
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    m.toastTimer = m.top.findNode("toastTimer")
    
    m.categoryList.observeField("itemFocused", "onCategoryFocused")
    m.categoryList.observeField("itemSelected", "onCategorySelected")
    m.toastTimer.observeField("fire", "hideToast")
    m.top.observeField("restoreFocus", "onRestoreFocus")
    
    theme = getTheme()
    if theme <> invalid
        m.categoryList.color = theme.colorTextDim
        m.categoryList.focusedColor = theme.colorText
        m.headerLabel.color = theme.colorText
        m.emptyLabel.color = theme.colorTextDim
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
        m.channelGrid.itemSpacing = [theme.spacingUnit, theme.spacingUnit]
    end if
    
    ' Position memory map: categoryIndex -> focused channel index
    m.gridFocusMemory = {} 
    m.currentChannels = []
    m.gridCache = {}
    m.channelsCache = {}
    m.favSet = {}
    m.pendingIdx = -1
    m.currentCategoryIdx = -1
    m.gridDebounceTimer = m.top.findNode("gridDebounceTimer")
    m.gridDebounceTimer.observeField("fire", "onGridDebounceFire")
    
    m.okTimer = m.top.findNode("okTimer")
    m.okTimer.observeField("fire", "onOkLongPress")
    m.okLongFired = false
end sub

sub rebuildFavSet()
    m.favSet = {}
    favs = LoadFavorites()
    if favs <> invalid
        for each f in favs
            m.favSet[f] = true
        end for
    end if
end sub

sub clearGridCache()
    m.gridCache = {}
    m.channelsCache = {}
end sub

' Refresh favorite state without clearing the whole cache.
' dropRecent=true also invalidates Recent (after the player).
sub refreshFavState(dropRecent as boolean)
    rebuildFavSet()
    keysToDrop = ["1"]
    if dropRecent then keysToDrop.Push("2")
    for each k in keysToDrop
        if m.gridCache.DoesExist(k) then m.gridCache.Delete(k)
        if m.channelsCache.DoesExist(k) then m.channelsCache.Delete(k)
    end for
    for each key in m.gridCache
        content = m.gridCache[key]
        if content <> invalid
            for i = 0 to content.getChildCount() - 1
                child = content.getChild(i)
                child.favorite = (m.favSet[child.name] <> invalid)
            end for
        end if
    end for
end sub

function headerForCategory(idx as integer) as string
    if idx = 1 then return "CHANNELS — Favorites"
    if idx = 2 then return "CHANNELS — Recent"
    res = m.top.playlistResult
    catIndex = idx - 3
    if res <> invalid and res.categories <> invalid and catIndex >= 0 and catIndex < res.categories.Count()
        cat = res.categories[catIndex]
        return "CHANNELS — " + cat.title + " (" + cat.count.ToStr() + ")"
    end if
    return "CHANNELS"
end function

function emptyTextForCategory(idx as integer) as string
    if idx = 1 then return "No favorites yet"
    if idx = 2 then return "Nothing watched yet"
    return "Nothing found"
end function

function buildGridForCategory(idx as integer) as object
    res = m.top.playlistResult
    gridContent = CreateObject("roSGNode", "ContentNode")
    channels = []
    if res = invalid then return { content: gridContent, channels: channels }

    if idx = 1 ' Favorites
        if res.channels <> invalid
            for each ch in res.channels
                if m.favSet[ch.name] <> invalid
                    addChannel(gridContent, ch, true)
                    channels.Push(ch)
                end if
            end for
        end if
    else if idx = 2 ' Recents
        recents = LoadRecents()
        if recents <> invalid and res.channels <> invalid
            for each r in recents
                for each ch in res.channels
                    if ch.name = r
                        addChannel(gridContent, ch, (m.favSet[ch.name] <> invalid))
                        channels.Push(ch)
                        exit for
                    end if
                end for
            end for
        end if
    else ' Regular category ("All" or others)
        catIndex = idx - 3
        if catIndex >= 0 and res.categories <> invalid and catIndex < res.categories.Count()
            cat = res.categories[catIndex]
            if res.channels <> invalid
                for each ch in res.channels
                    if cat.title = "All" or ch.group = cat.title
                        addChannel(gridContent, ch, (m.favSet[ch.name] <> invalid))
                        channels.Push(ch)
                    end if
                end for
            end if
        end if
    end if
    return { content: gridContent, channels: channels }
end function

sub onPlaylistChange()
    res = m.top.playlistResult
    if res = invalid return
    
    RestoreStoreFromBackup()
    MigrateStoreToNames(res.channels)
    
    buildCategories()
    clearGridCache()
    rebuildFavSet()
    
    m.categoryList.setFocus(true)
    ' Default to "Favorites" which is index 1
    if m.categoryList.content <> invalid and m.categoryList.content.getChildCount() > 1
        m.categoryList.jumpToItem = 1
    end if
end sub

sub buildCategories()
    res = m.top.playlistResult
    if res = invalid return
    
    favs = LoadFavorites()
    recents = LoadRecents()
    
    favCount = 0
    if favs <> invalid then favCount = favs.Count()
    recCount = 0
    if recents <> invalid then recCount = recents.Count()
    
    content = CreateObject("roSGNode", "ContentNode")
    
    addCategory(content, "Search")
    addCategory(content, "★ Favorites (" + favCount.ToStr() + ")")
    addCategory(content, "Recent (" + recCount.ToStr() + ")")
    
    if res.categories <> invalid
        for each cat in res.categories
            addCategory(content, cat.title + " (" + cat.count.ToStr() + ")")
        end for
    end if
    
    addCategory(content, "Settings")
    
    m.categoryList.content = content
end sub

sub addCategory(parent as object, title as string)
    item = parent.createChild("ContentNode")
    item.title = title
end sub

sub updateCategoryCounts()
    favs = LoadFavorites()
    recents = LoadRecents()
    
    favCount = 0
    if favs <> invalid then favCount = favs.Count()
    recCount = 0
    if recents <> invalid then recCount = recents.Count()
    
    if m.categoryList.content <> invalid
        favNode = m.categoryList.content.getChild(1)
        if favNode <> invalid then favNode.title = "★ Favorites (" + favCount.ToStr() + ")"
        
        recNode = m.categoryList.content.getChild(2)
        if recNode <> invalid then recNode.title = "Recent (" + recCount.ToStr() + ")"
    end if
end sub

sub onCategoryFocused()
    m.pendingIdx = m.categoryList.itemFocused
    m.gridDebounceTimer.control = "stop"
    m.gridDebounceTimer.control = "start"
end sub

sub onGridDebounceFire()
    if m.pendingIdx >= 0
        updateGridForCategory(m.pendingIdx)
        m.pendingIdx = -1
    end if
end sub

sub flushPendingGrid()
    m.gridDebounceTimer.control = "stop"
    if m.pendingIdx >= 0
        updateGridForCategory(m.pendingIdx)
        m.pendingIdx = -1
    end if
end sub

sub onCategorySelected()
    idx = m.categoryList.itemSelected
    if idx = 0
        m.top.openSearch = not m.top.openSearch
    else if m.categoryList.content <> invalid and idx = m.categoryList.content.getChildCount() - 1
        m.top.openSettings = not m.top.openSettings
    end if
end sub

sub updateGridForCategory(idx as integer)
    m.currentCategoryIdx = idx
    if m.categoryList.content = invalid then return
    lastIdx = m.categoryList.content.getChildCount() - 1

    ' Search / Settings — empty grid (cheap, not cached)
    if idx = 0 or idx = lastIdx
        m.channelGrid.content = CreateObject("roSGNode", "ContentNode")
        m.currentChannels = []
        m.emptyLabel.visible = true
        m.emptyLabel.text = "Select to open"
        m.headerLabel.text = "CHANNELS — " + m.categoryList.content.getChild(idx).title
        return
    end if

    key = idx.ToStr()
    if not m.gridCache.DoesExist(key)
        built = buildGridForCategory(idx)
        m.gridCache[key] = built.content
        m.channelsCache[key] = built.channels
    end if

    m.channelGrid.content = m.gridCache[key]
    m.currentChannels = m.channelsCache[key]
    m.headerLabel.text = headerForCategory(idx)

    if m.currentChannels.Count() = 0
        m.emptyLabel.visible = true
        m.emptyLabel.text = emptyTextForCategory(idx)
    else
        m.emptyLabel.visible = false
        if m.gridFocusMemory.DoesExist(key)
            m.channelGrid.jumpToItem = m.gridFocusMemory[key]
        else
            m.channelGrid.jumpToItem = 0
        end if
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

sub playFocusedChannel()
    if m.channelGrid.content = invalid then return
    idx = m.channelGrid.itemFocused
    item = m.channelGrid.content.getChild(idx)
    if item = invalid then return

    if item.compatible
        m.top.playRequest = { channels: m.currentChannels, index: idx }
    else
        showToast("Stream not supported")
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false

    ' Long OK on a card: short = play, long = favorite (add/remove by category)
    if key = "OK" and m.channelGrid.hasFocus()
        if press
            m.okLongFired = false
            m.okTimer.control = "stop"
            m.okTimer.control = "start"
        else
            m.okTimer.control = "stop"
            if not m.okLongFired then playFocusedChannel()
        end if
        return true
    end if

    if press
        if key = "right"
            if m.categoryList.hasFocus()
                flushPendingGrid()
                if m.channelGrid.content <> invalid and m.channelGrid.content.getChildCount() > 0
                    m.channelGrid.setFocus(true)
                end if
                handled = true
            end if
        else if key = "left"
            if m.channelGrid.hasFocus()
                idx = m.channelGrid.itemFocused
                if (idx MOD m.gridCols) = 0
                    catIdx = m.currentCategoryIdx
                    m.gridFocusMemory[catIdx.ToStr()] = idx
                    
                    m.categoryList.setFocus(true)
                    handled = true
                end if
            end if
        else if key = "options"
            if m.channelGrid.hasFocus()
                idx = m.channelGrid.itemFocused
                if m.channelGrid.content <> invalid
                    item = m.channelGrid.content.getChild(idx)
                    if item <> invalid
                        isFav = ToggleFavorite(item.name)
                        item.favorite = isFav
                        refreshFavState(false)
                        catIdx = m.currentCategoryIdx
                        if catIdx = 1 and not isFav
                            updateGridForCategory(catIdx)
                            m.channelGrid.setFocus(true)
                        end if
                        updateCategoryCounts()
                    end if
                end if
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

sub onRestoreFocus()
    refreshFavState(true)
    updateCategoryCounts()
    curIdx = m.categoryList.itemFocused
    updateGridForCategory(curIdx)
    if m.channelGrid.content <> invalid and m.channelGrid.content.getChildCount() > 0
        m.channelGrid.setFocus(true)
    else
        m.categoryList.setFocus(true)
    end if
end sub

sub onOkLongPress()
    m.okLongFired = true
    if not m.channelGrid.hasFocus() then return
    if m.channelGrid.content = invalid then return
    idx = m.channelGrid.itemFocused
    item = m.channelGrid.content.getChild(idx)
    if item = invalid then return

    catIdx = m.currentCategoryIdx
    if catIdx = 1
        ' Favorites category — remove from favorites
        if IsFavorite(item.name)
            ToggleFavorite(item.name)
            item.favorite = false
            showToast("Removed from favorites")
            refreshFavState(false)
            updateGridForCategory(1)
            m.channelGrid.setFocus(true)
            updateCategoryCounts()
        end if
    else
        ' Other categories — add to favorites
        if IsFavorite(item.name)
            showToast("Already in favorites")
        else
            ToggleFavorite(item.name)
            item.favorite = true
            showToast("Added to favorites")
            refreshFavState(false)
            updateCategoryCounts()
        end if
    end if
end sub
