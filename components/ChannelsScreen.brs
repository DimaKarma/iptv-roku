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
    m.top.observeField("noticeCommand", "onNotice")
    m.top.observeField("resumeCommand", "onResumeCommand")
    
    theme = getTheme()
    if theme <> invalid
        m.categoryList.color = theme.colorTextDim
        ' On-accent, because the chip underneath is now the accent colour (see the
        ' focusBitmapBlendColor on categoryList). This line used to set colorText, which
        ' overwrote the XML value and left off-white on the stock grey chip at 1.29:1.
        m.categoryList.focusedColor = theme.colorOnAccent
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
    ' The playlist result, read ONCE per load: reading m.top.playlistResult copies all
    ' ~1500 channels every time. byName maps a channel name to its first entry.
    m.res = invalid
    m.byName = {}
    ' {cat, name} computed by onPlaylistChange, consumed by onResumeCommand. Never set
    ' for an adult-group channel.
    m.resume = invalid
    m.resumeLogged = false
    ' True once the launch resume has been offered (played or not): later playlist
    ' results never compute one.
    m.resumeSpent = false
    ' Global observers are attached lazily in onPlaylistChange: this screen is a static
    ' child of MainScene, its init runs BEFORE MainScene.init creates the fields.
    m.globalObserved = false
    ' Seconds (m.global.nowSec) at which each cached grid had its programme lines built
    ' or refreshed; 0 = stale.
    m.gridStamp = {}
    m.pendingIdx = -1
    m.currentCategoryIdx = -1
    m.gridDebounceTimer = m.top.findNode("gridDebounceTimer")
    m.gridDebounceTimer.observeField("fire", "onGridDebounceFire")
    
    m.okTimer = m.top.findNode("okTimer")
    m.okTimer.observeField("fire", "onOkLongPress")
    m.okLongFired = false
    ' True only between an OK PRESS this screen saw on the grid and its release. A press
    ' that went elsewhere (the player's error dialog, whose "Back" row hands focus to the
    ' grid) must not turn its RELEASE into playFocusedChannel() here.
    m.okArmed = false
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
    m.gridStamp = {}
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
    res = m.res
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
    res = m.res
    gridContent = CreateObject("roSGNode", "ContentNode")
    channels = []
    if res = invalid then return { content: gridContent, channels: channels }
    ' One guide read per build (an assocarray field read copies the whole map).
    epg = m.global.epg
    nowSec = m.global.nowSec

    if idx = 1 ' Favorites
        if res.channels <> invalid
            for each ch in res.channels
                if m.favSet[ch.name] <> invalid
                    addChannel(gridContent, ch, true, epg, nowSec)
                    channels.Push(ch)
                end if
            end for
        end if
    else if idx = 2 ' Recents
        recents = LoadRecents()
        if recents <> invalid
            for each r in recents
                ch = m.byName[r]
                if ch <> invalid
                    addChannel(gridContent, ch, (m.favSet[ch.name] <> invalid), epg, nowSec)
                    channels.Push(ch)
                end if
            end for
        end if
    else ' Regular category ("All" or others)
        catIndex = idx - 3
        if catIndex >= 0 and res.categories <> invalid and catIndex < res.categories.Count()
            cat = res.categories[catIndex]
            if res.channels <> invalid
                for each ch in res.channels
                    if cat.title = "All" or ch.group = cat.title
                        addChannel(gridContent, ch, (m.favSet[ch.name] <> invalid), epg, nowSec)
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
    m.res = res

    if not m.globalObserved
        m.globalObserved = true
        m.global.observeField("epgReady", "onEpgReady")
        m.global.observeField("nowSec", "onNowTick")
    end if

    m.byName = {}
    ' Case-sensitive, like the name comparisons it replaces; before the first insert.
    m.byName.SetModeCaseSensitive()
    if res.channels <> invalid
        for each ch in res.channels
            if ch.name <> invalid and not m.byName.DoesExist(ch.name) then m.byName[ch.name] = ch
        end for
    end if
    
    ' Before migration and the purge, so everything downstream sees the restored
    ' data on the run that seeds it.
    RestoreStoreIfEmpty()
    MigrateStoreToNames(res.channels)
    adultCount = PurgeAdultFromRecents(res.channels)
    ' After migration and purge, so what is printed is exactly what is stored.
    ' deploy.ps1 captures these lines over port 8085 before every sideload.
    DumpStore()
    
    buildCategories()
    clearGridCache()
    rebuildFavSet()

    ' Resume is only COMPUTED here, never started: MainScene toggles resumeCommand after
    ' the screen is shown, and the playback request leaves from onResumeCommand.
    ' Fail closed: with no channel in the adult group the classifier has stopped matching
    ' (a renamed group), so every adult channel would look resumable. Disable instead.
    m.resume = invalid
    m.resumeLogged = false
    if adultCount < 1
        ClearLastChannel()
        m.resumeLogged = true
        print "[RESUME] disabled: adult classifier matched 0"
    else
        computeResume()
    end if
    
    m.categoryList.setFocus(true)
    ' Default to "Favorites" (index 1); to the list holding the resume channel when set.
    if m.categoryList.content <> invalid and m.categoryList.content.getChildCount() > 1
        if m.resume <> invalid
            m.categoryList.jumpToItem = m.resume.cat
        else
            m.categoryList.jumpToItem = 1
        end if
    end if
end sub

' Sets m.resume = {cat, name} or leaves it invalid. Favorites (1) when the channel is a
' favourite, else Recent (2), else nothing. The adult purge has already removed a stored
' name that belongs to the adult group; the entry is checked again here regardless.
sub computeResume()
    m.resume = invalid
    if m.resumeSpent then return
    if not IsResumeEnabled() then return
    name = LoadLastChannel()
    if name = "" then return
    ' Refuse, and forget the name, when ANY channel of that name is in the adult group;
    ' this does not rely on the purge having succeeded.
    if m.res <> invalid and m.res.channels <> invalid
        for each c in m.res.channels
            if c.name = name and IsAdultGroup(c.group)
                ClearLastChannel()
                return
            end if
        end for
    end if
    ch = m.byName[name]
    if ch = invalid then return
    if ch.compatible <> true or IsAdultGroup(ch.group) then return

    cat = 0
    if m.favSet[name] <> invalid
        cat = 1
    else
        recents = LoadRecents()
        if recents <> invalid
            for each r in recents
                if r = name
                    cat = 2
                    exit for
                end if
            end for
        end if
    end if
    if cat = 0 then return
    m.resume = { cat: cat, name: name }
end sub

' Launch-time resume. MainScene toggles resumeCommand once, right after the first
' showChannels of the launch load. It consumes m.resume, so one computed result starts
' at most one playback. Any failure leaves the screen exactly as a normal launch.
sub onResumeCommand()
    r = m.resume
    m.resume = invalid
    m.resumeSpent = true
    if r = invalid
        if not m.resumeLogged then print "[RESUME] none"
        m.resumeLogged = true
        return
    end if
    flushPendingGrid()
    updateGridForCategory(r.cat)
    idx = -1
    for i = 0 to m.currentChannels.Count() - 1
        if m.currentChannels[i].name = r.name
            idx = i
            exit for
        end if
    end for
    ch = invalid
    if idx >= 0 then ch = m.currentChannels[idx]
    ' Final gate, on the entry that is actually handed to the player.
    if ch = invalid or ch.name <> r.name or ch.compatible <> true or IsAdultGroup(ch.group)
        print "[RESUME] none"
        return
    end if
    m.gridFocusMemory[r.cat.ToStr()] = idx
    m.channelGrid.jumpToItem = idx
    print "[RESUME] play cat=" + r.cat.ToStr() + " idx=" + idx.ToStr()
    m.top.playRequest = { channels: m.currentChannels, index: idx }
end sub

' The guide arrived or was refreshed: update the shown grid only and mark every other
' cached grid stale, so it refreshes when it is next shown (no walk over cached nodes).
sub onEpgReady()
    shown = m.currentCategoryIdx.ToStr()
    for each key in m.gridCache
        if key <> shown then m.gridStamp[key] = 0
    end for
    if m.gridCache.DoesExist(shown) then refreshGridEpg(shown)
end sub

' Ticks every 30 s (MainScene.onNowTick bumps nowSec). Only the grid on screen is
' looked at, and only while this screen is visible.
sub onNowTick()
    if not m.top.visible then return
    key = m.currentCategoryIdx.ToStr()
    if not m.gridCache.DoesExist(key) then return
    if not isFreshStamp(key) then refreshGridEpg(key)
end sub

function isFreshStamp(key as string) as boolean
    stamp = m.gridStamp[key]
    if stamp = invalid or stamp = 0 then return false
    return (m.global.nowSec - stamp) <= 300
end function

' Re-compute epgNow of ONE cached grid. One guide read per refresh, never per node.
sub refreshGridEpg(key as string)
    content = m.gridCache[key]
    if content = invalid then return
    t0 = Uptime(0)
    epg = m.global.epg
    nowSec = m.global.nowSec
    n = content.getChildCount()
    for i = 0 to n - 1
        child = content.getChild(i)
        child.epgNow = EpgNowText(epg, child.name, nowSec)
    end for
    m.gridStamp[key] = nowSec
    print "[GRID] epg refresh key=" + key + " items=" + n.ToStr() + " ms=" + Int((Uptime(0) - t0) * 1000).ToStr()
end sub

sub buildCategories()
    res = m.res
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
        t0 = Uptime(0)
        built = buildGridForCategory(idx)
        m.gridCache[key] = built.content
        m.channelsCache[key] = built.channels
        m.gridStamp[key] = m.global.nowSec
        print "[GRID] build idx=" + idx.ToStr() + " items=" + built.channels.Count().ToStr() + " ms=" + Int((Uptime(0) - t0) * 1000).ToStr()
    end if

    ' A cached grid older than 5 minutes (or marked stale) gets fresh programme lines.
    if not isFreshStamp(key) then refreshGridEpg(key)

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

sub addChannel(parent as object, ch as object, isFav as boolean, epg as dynamic, nowSec as dynamic)
    item = parent.createChild("ChannelContent")
    
    item.name = ch.name
    item.epgNow = EpgNowText(epg, ch.name, nowSec)
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
        ' remember where we were so Back from the player returns to this channel
        m.gridFocusMemory[m.currentCategoryIdx.ToStr()] = idx
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
            m.okArmed = true
            m.okTimer.control = "stop"
            m.okTimer.control = "start"
        else
            m.okTimer.control = "stop"
            if m.okArmed and not m.okLongFired then playFocusedChannel()
            m.okArmed = false
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

sub onRestoreFocus()
    m.okArmed = false
    refreshFavState(true)
    updateCategoryCounts()
    curIdx = m.currentCategoryIdx
    if curIdx < 0 then curIdx = m.categoryList.itemFocused
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
