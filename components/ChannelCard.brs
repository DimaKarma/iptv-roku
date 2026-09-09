' ChannelCard: item component for grid

sub init()
    m.background = m.top.findNode("background")
    m.fallbackBg = m.top.findNode("fallbackBg")
    m.fallbackLabel = m.top.findNode("fallbackLabel")
    m.logo = m.top.findNode("logo")
    m.errorBadge = m.top.findNode("errorBadge")
    m.dimmer = m.top.findNode("dimmer")
    m.favStar = m.top.findNode("favStar")
    m.nameLabel = m.top.findNode("nameLabel")
    m.epgLabel = m.top.findNode("epgLabel")

    m.theme = m.global.theme
    if m.theme = invalid then m.theme = getTheme()   ' fallback for early init
    theme = m.theme
    if theme <> invalid
        m.background.color = theme.colorSurface
        m.nameLabel.color = theme.colorText
    end if
    
    ' Fix anchor for scaling (center of 330x220)
    m.top.scaleRotateCenter = [165.0, 110.0]
    
    m.global.observeField("epgReady", "onEpgReady")
    m.epgLabel.color = theme.colorTextDim
end sub

sub onContentChange()
    content = m.top.itemContent
    if content = invalid return
    
    theme = m.theme
    
    ' Set name
    m.nameLabel.text = content.name
    
    ' Set logo or fallback
    if content.logo <> invalid and content.logo <> ""
        m.logo.uri = content.logo
        m.logo.visible = true
        m.fallbackBg.visible = false
    else
        m.logo.visible = false
        m.fallbackBg.visible = true
        m.fallbackLabel.text = getInitials(content.name)
        m.fallbackBg.color = getColorFromHash(content.name)
    end if
    
    ' Incompatible stream
    if content.compatible = false
        m.errorBadge.visible = true
        if theme <> invalid then m.errorBadge.color = theme.colorError
        m.dimmer.visible = true
    else
        m.errorBadge.visible = false
        m.dimmer.visible = false
    end if
    
    ' Favorite
    if content.favorite = true
        m.favStar.visible = true
    else
        m.favStar.visible = false
    end if
    
    updateEpgLabel()
end sub

sub onEpgReady()
    updateEpgLabel()
end sub

sub updateEpgLabel()
    if m.top.itemContent = invalid
        m.epgLabel.text = ""
        return
    end if
    
    info = EpgFind(m.global.epg, m.top.itemContent.name, m.global.nowSec)
    if info.now <> invalid
        m.epgLabel.text = info.now.t
    else
        m.epgLabel.text = ""
    end if
end sub

' The focus ring is drawn by the GRID, not by this card.
'
' This used to keep four green rectangles at [-4,-4] and toggle them here. They were
' never visible when it mattered: the grid clips item children to the GRID's viewport, so
' the two at negative offsets were cut away entirely, and when the grid actually held
' focus the stock focus bitmap was painted over the two that survived. Fixing the
' coordinates was not the answer either -- inside the item the border lands on the
' initials tile at 1.63:1 against seven of the eight tile colours. The grid's own ring is
' drawn outside the item and outside the clip, so it needs no geometry at all; it is
' tinted to the brand green with focusBitmapBlendColor on the grid.
sub onFocusChange()
    theme = m.theme
    hasFocus = m.top.focusPercent > 0.5

    scale = 1.05
    if theme <> invalid and theme.focusScale <> invalid then scale = theme.focusScale
    
    if hasFocus
        m.top.scale = [scale, scale]
    else
        m.top.scale = [1.0, 1.0]
    end if
end sub

function getInitials(name as string) as string
    if name = invalid or name = "" then return ""
    parts = name.Split(" ")
    if parts.Count() = 0 then return ""
    if parts.Count() > 1
        return Mid(parts[0], 1, 1) + Mid(parts[1], 1, 1)
    else
        return Mid(parts[0], 1, 2)
    end if
end function

function getColorFromHash(name as string) as string
    if name = invalid or name = "" return "0x333333FF"
    hash = 0
    for i = 1 to Len(name)
        hash = hash + Asc(Mid(name, i, 1))
    end for
    colors = ["0x2F6E4EFF", "0x3C6E86FF", "0x6E7D3AFF", "0x7A5C3EFF", "0x4E6E6EFF", "0x5B4E7AFF", "0x6E3E4EFF", "0x3E7A66FF"]
    idx = hash MOD colors.Count()
    return colors[idx]
end function
