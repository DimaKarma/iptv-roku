' SearchScreen: its own keyboard on the left, live results on the right.
'
' Focus model. This screen ITSELF holds focus while the keyboard is in use, so every
' arrow, OK, * and Back arrives in onKeyEvent (the stock Keyboard node swallows arrows,
' rule 8, which is why there is none here). The result grid is the only other holder.
' focusKeyboard / focusGrid are the only places that move focus; both clear okArmed.
'
' The keyboard is 6 columns x 7 rows. Rows 0-5 are 36 character cells whose texts
' change with the layout (EN, RU, 123); row 6 is the function row: Space, Delete,
' Clear, EN, RU, 123. The cells are created ONCE in init (rule 17); a layout switch only
' rewrites texts. THIS FILE CONTAINS NO CYRILLIC: the Russian letters are made with
' Chr() from code points, as Translit.brs does for its table.
'
' OK acts on PRESS (typing); its release is swallowed when this screen saw the press.

sub init()
    m.fieldBg = m.top.findNode("fieldBg")
    m.fieldLabel = m.top.findNode("fieldLabel")
    m.headerLabel = m.top.findNode("headerLabel")
    m.hintLabel = m.top.findNode("hintLabel")
    m.channelGrid = m.top.findNode("channelGrid")
    m.statusLabel = m.top.findNode("statusLabel")
    m.keyBgs = m.top.findNode("keyBgs")
    m.keyLabels = m.top.findNode("keyLabels")
    m.keyHighlight = m.top.findNode("keyHighlight")
    m.activeBar = m.top.findNode("activeBar")
    m.wayBack = m.top.findNode("wayBack")

    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")

    m.searchTimer = m.top.findNode("searchTimer")
    m.toastTimer = m.top.findNode("toastTimer")

    m.gridCols = m.channelGrid.numColumns
    if m.gridCols < 1 then m.gridCols = 1

    m.searchTimer.observeField("fire", "performSearch")
    m.channelGrid.observeField("itemSelected", "onChannelSelected")
    m.toastTimer.observeField("fire", "hideToast")
    m.top.observeField("visible", "onVisibleChange")

    m.theme = getTheme()
    theme = m.theme
    if theme <> invalid
        m.fieldBg.color = theme.colorSurfaceHi
        m.headerLabel.color = theme.colorText
        m.hintLabel.color = theme.colorTextDim
        m.statusLabel.color = theme.colorTextDim
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
        m.keyHighlight.color = theme.colorFocus
        m.activeBar.color = theme.colorInfo
        for each side in ["wayTop", "wayBottom", "wayLeft", "wayRight"]
            m.top.findNode(side).color = theme.colorTextDim
        end for
        m.channelGrid.itemSpacing = [theme.spacingUnit, theme.spacingUnit]
    end if

    m.allChannels = []
    m.byName = {}
    m.currentChannels = []
    ' Set when a play request leaves this screen; read (and cleared) by the visible
    ' handler when the screen comes back, so that path does not steal focus.
    m.returning = false
    m.playIdx = 0
    ' True only between an OK PRESS this screen saw on the keyboard and its release.
    m.okArmed = false
    ' True from a query change until the next performSearch (the 0.3 s timer, or Right).
    m.searchDirty = false

    ' The query and the cursor live in m and survive while the app runs. Lower case only.
    m.query = ""
    m.kr = 0
    m.kc = 0
    m.keysFocused = true

    m.layouts = buildLayouts()
    m.layout = "en"
    m.activeCol = 3
    m.cellInert = []
    m.cellBg = []
    m.cellLabel = []
    fnWords = ["Space", "Delete", "Clear", "EN", "RU", "123"]
    for i = 0 to 41
        r = Int(i / 6)
        col = i - r * 6
        x = 96 + col * 104
        y = 140 + r * 72
        bg = m.keyBgs.createChild("Rectangle")
        bg.translation = [x, y]
        bg.width = 96
        bg.height = 64
        m.cellBg.Push(bg)
        lbl = m.keyLabels.createChild("Label")
        lbl.translation = [x, y]
        lbl.width = 96
        lbl.height = 64
        lbl.horizAlign = "center"
        lbl.vertAlign = "center"
        if r = 6
            lbl.text = fnWords[col]
            ' Words in 96 px cells: smaller than the default font by scale only (rule 22).
            ' A Label ellipsises at its UNSCALED width, so the label is 128 wide (128 * 0.8 =
            ' 102.4 on screen), moved 16 left so its centre (64) stays on the cell centre
            ' (x + 48), and scaled about that centre. The letters keep the default size.
            lbl.width = 128
            lbl.translation = [x - 16, y]
            lbl.scale = [0.8, 0.8]
            lbl.scaleRotateCenter = [64, 32]
        end if
        m.cellLabel.Push(lbl)
        m.cellInert.Push(false)
    end for
    applyLayout("en")
    updateFieldText()
    ' Not focusKeyboard(): init runs while the screen is hidden and must not take focus.
    refreshCursorMarks()
    updateHint()
end sub

' The three layouts, each exactly 36 strings ("" = an inert cell the cursor skips).
function buildLayouts() as object
    en = []
    for cp = 97 to 122
        en.Push(Chr(cp))
    end for
    for cp = 48 to 57
        en.Push(Chr(cp))
    end for

    ' The 33 Russian letters: U+0430..U+044F with U+0451 placed after U+0435.
    ru = []
    for cp = &h430 to &h435
        ru.Push(Chr(cp))
    end for
    ru.Push(Chr(&h451))
    for cp = &h436 to &h44F
        ru.Push(Chr(cp))
    end for
    ru.Push("-")
    ru.Push(".")
    ru.Push("+")

    ' Digits and the punctuation that occurs in channel names. The apostrophe is Chr(39)
    ' so that no quote character sits inside a string literal.
    num = []
    chars = "1234567890-.+&" + Chr(39) + "!:(),/@#_"
    for i = 1 to Len(chars)
        num.Push(Mid(chars, i, 1))
    end for
    while num.Count() < 36
        num.Push("")
    end while

    return { en: en, ru: ru, num: num }
end function

' Rewrite the 36 character texts and mark the active layout key. No node is created.
sub applyLayout(name as string)
    chars = m.layouts[name]
    if chars = invalid then return
    m.layout = name
    if name = "en"
        m.activeCol = 3
    else if name = "ru"
        m.activeCol = 4
    else
        m.activeCol = 5
    end if
    for i = 0 to 35
        m.cellLabel[i].text = chars[i]
        m.cellInert[i] = (chars[i] = "")
    end for
    m.activeBar.translation = [96 + m.activeCol * 104, 140 + 6 * 72 + 60]
    for i = 0 to 41
        paintCell(i)
    end for
end sub

' Colours of one cell from its state: focused (accent fill, on-accent text), the active
' layout key (hi fill, info text), a function word (dim), a character (text).
sub paintCell(i as integer)
    theme = m.theme
    if theme = invalid then return
    bg = m.cellBg[i]
    lbl = m.cellLabel[i]
    if m.cellInert[i]
        bg.visible = false
        return
    end if
    bg.visible = true
    isActive = (i = 36 + m.activeCol)
    isFocused = false
    if m.keysFocused
        if i = m.kr * 6 + m.kc then isFocused = true
    end if
    if isActive
        bg.color = theme.colorSurfaceHi
    else
        bg.color = theme.colorSurface
    end if
    if isFocused
        lbl.color = theme.colorOnAccent
    else if isActive
        lbl.color = theme.colorInfo
    else if i >= 36
        lbl.color = theme.colorTextDim
    else
        lbl.color = theme.colorText
    end if
end sub

' Put the highlight (keyboard focus) or the way-back outline (grid focus) on the cursor.
sub refreshCursorMarks()
    x = 96 + m.kc * 104
    y = 140 + m.kr * 72
    m.keyHighlight.translation = [x, y]
    m.wayBack.translation = [x, y]
    m.keyHighlight.visible = m.keysFocused
    m.wayBack.visible = not m.keysFocused
    paintCell(m.kr * 6 + m.kc)
end sub

sub setCursor(r as integer, c as integer)
    oldIdx = m.kr * 6 + m.kc
    m.kr = r
    m.kc = c
    paintCell(oldIdx)
    refreshCursorMarks()
end sub

' Next non-inert column from c in direction stepC (+1 or -1) on row r; -1 when none.
function findCol(r as integer, c as integer, stepC as integer) as integer
    cc = c + stepC
    while cc >= 0 and cc <= 5
        if not m.cellInert[r * 6 + cc] then return cc
        cc = cc + stepC
    end while
    return -1
end function

' The non-inert column of row r nearest to column c; -1 when the whole row is inert.
function nearestCol(r as integer, c as integer) as integer
    for d = 0 to 5
        if c - d >= 0
            if not m.cellInert[r * 6 + c - d] then return c - d
        end if
        if c + d <= 5
            if not m.cellInert[r * 6 + c + d] then return c + d
        end if
    end for
    return -1
end function

' Up and Down wrap between row 0 and row 6; rows that are inert in this layout are skipped.
sub moveVertical(delta as integer)
    r = m.kr
    for n = 1 to 7
        r = r + delta
        if r < 0 then r = 6
        if r > 6 then r = 0
        c = nearestCol(r, m.kc)
        if c >= 0
            setCursor(r, c)
            return
        end if
    end for
end sub

' OK on the cursor cell.
sub activateKey()
    if m.kr < 6
        chars = m.layouts[m.layout]
        typeChar(chars[m.kr * 6 + m.kc])
    else if m.kc = 0
        if Len(m.query) > 0 then typeChar(" ")
    else if m.kc = 1
        deleteChar()
    else if m.kc = 2
        if Len(m.query) > 0
            m.query = ""
            onQueryChanged()
        end if
    else if m.kc = 3
        applyLayout("en")
    else if m.kc = 4
        applyLayout("ru")
    else
        applyLayout("num")
    end if
end sub

sub typeChar(s as string)
    if s = "" then return
    if Len(m.query) >= 40 then return
    m.query = m.query + s
    onQueryChanged()
end sub

' Mid, never Left: Left is byte-based and would cut a Cyrillic character in half (rule 2).
sub deleteChar()
    q = m.query
    if Len(q) = 0 then return
    m.query = Mid(q, 1, Len(q) - 1)
    onQueryChanged()
end sub

' Every change restarts the 0.3 s timer: stop, then start.
sub onQueryChanged()
    m.searchDirty = true
    updateFieldText()
    updateHint()
    m.searchTimer.control = "stop"
    m.searchTimer.control = "start"
end sub

' The screen was shown. Back from the player (m.returning): keep everything, focus the
' card that was played. Otherwise: refresh the list (Recent and the favourite stars can
' have changed since the last visit) and focus the keyboard at the remembered cell.
sub onVisibleChange()
    if not m.top.visible then return
    m.okArmed = false
    if m.returning
        m.returning = false
        restoreGrid()
    else
        performSearch()
        focusKeyboard()
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
        focusKeyboard()
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

sub focusKeyboard()
    m.okArmed = false
    m.channelGrid.setFocus(false)
    m.top.setFocus(true)
    m.keysFocused = true
    refreshCursorMarks()
    updateHint()
end sub

sub focusGrid()
    m.okArmed = false
    m.keysFocused = false
    m.channelGrid.setFocus(true)
    refreshCursorMarks()
    updateHint()
end sub

' The query field only displays m.query. A long query shows its TAIL (the end being typed).
sub updateFieldText()
    q = m.query
    if q = ""
        m.fieldLabel.text = "Type to search"
        if m.theme <> invalid then m.fieldLabel.color = m.theme.colorTextDim
    else
        shown = q
        if Len(q) > 22 then shown = Mid(q, Len(q) - 21, 22)
        m.fieldLabel.text = shown
        if m.theme <> invalid then m.fieldLabel.color = m.theme.colorText
    end if
end sub

sub updateHint()
    if m.keysFocused
        if m.query = ""
            m.hintLabel.text = "OK type   * Delete   Right: recent"
        else
            m.hintLabel.text = "OK type   * Delete   Right: results"
        end if
    else
        m.hintLabel.text = "OK play   * Favorite   Left: keyboard"
    end if
end sub

sub performSearch()
    m.searchDirty = false
    query = m.query
    
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
        m.headerLabel.text = "RESULTS - 60 of " + total.ToStr()
    else
        m.headerLabel.text = "RESULTS - " + total.ToStr()
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
    m.headerLabel.text = "RECENT"
    if shown.Count() = 0
        if query = ""
            m.statusLabel.text = "Type to search"
        else
            m.statusLabel.text = "Type at least 2 characters"
        end if
    end if
end sub

' Put `shown` into the grid and remember it as the play list. Sets the status label
' hidden when there are items; callers set its text when there are none.
sub showResults(shown as object, favSet as object)
    gridContent = CreateObject("roSGNode", "ContentNode")
    ' One guide read per build; the cards show epgNow and read no guide themselves.
    ' Results are rebuilt on every query, so they pick up a newer guide on the next one.
    epg = m.global.epg
    nowSec = m.global.nowSec
    for each ch in shown
        addChannel(gridContent, ch, (favSet[ch.name] <> invalid), epg, nowSec)
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


' OK is acted on at PRESS (see onKeysKey); its release is swallowed only when this screen
' saw the press, so a release that belongs to another screen (the rail selects on press and
' the release lands here) is left alone and can never type.
function onKeyEvent(key as string, press as boolean) as boolean
    ' A hidden screen acts on nothing. The grid raises its selection on the OK PRESS,
    ' MainScene hides this screen and moves focus to the player, and the SAME press then
    ' continues up to this handler: it must not be read as a key press on the keyboard.
    if not m.top.visible then return false
    if key = "OK" and not press
        if m.okArmed
            m.okArmed = false
            return true
        end if
        return false
    end if
    if not press then return false
    ' Where focus is comes from m.keysFocused (set only by focusKeyboard / focusGrid), never
    ' from hasFocus() being false: a press that already moved focus away must not fall
    ' through to the keyboard.
    if m.keysFocused then return onKeysKey(key)
    if m.channelGrid.hasFocus() then return onGridKey(key)
    return false
end function

function onKeysKey(key as string) as boolean
    handled = false
    if key = "up"
        moveVertical(-1)
        handled = true
    else if key = "down"
        moveVertical(1)
        handled = true
    else if key = "left"
        c = findCol(m.kr, m.kc, -1)
        if c >= 0 then setCursor(m.kr, c)
        handled = true
    else if key = "right"
        c = findCol(m.kr, m.kc, 1)
        if c >= 0
            setCursor(m.kr, c)
        else
            goToResults()
        end if
        handled = true
    else if key = "OK"
        m.okArmed = true
        activateKey()
        handled = true
    else if key = "options"
        deleteChar()
        handled = true
    else if key = "back"
        m.top.exitRequested = not m.top.exitRequested
        handled = true
    end if
    return handled
end function

' Right at the edge: run the search NOW (the timer may be pending), then move to the
' results only if there is something to land on. An empty grid would be dead focus.
sub goToResults()
    ' Rebuild only when the shown results are stale; otherwise the grid would jump back to
    ' item 0 for nothing.
    if m.searchDirty
        m.searchTimer.control = "stop"
        performSearch()
    end if
    if hasItems() then focusGrid()
end sub

function onGridKey(key as string) as boolean
    handled = false
    if key = "back"
        focusKeyboard()
        handled = true
    else if key = "left"
        if m.channelGrid.itemFocused mod m.gridCols = 0
            focusKeyboard()
            handled = true
        end if
    else if key = "up"
        if m.channelGrid.itemFocused < m.gridCols then handled = true
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
