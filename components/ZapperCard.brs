' ZapperCard: item component for zapper grid

sub init()
    m.fallbackBg = m.top.findNode("fallbackBg")
    m.fallbackLabel = m.top.findNode("fallbackLabel")
    m.nameLabel = m.top.findNode("nameLabel")
    m.epgLabel = m.top.findNode("epgLabel")
    m.favStar = m.top.findNode("favStar")
    m.badge = m.top.findNode("badge")
    m.focusBorder = m.top.findNode("focusBorder")
    
    theme = getTheme()
    if theme <> invalid
        m.nameLabel.color = theme.colorText
        m.epgLabel.color = theme.colorTextDim
        m.badge.color = theme.colorError
        
        for i = 0 to 3
            m.focusBorder.getChild(i).color = theme.colorFocus
        end for
    end if
end sub

sub onContentChange()
    content = m.top.itemContent
    if content = invalid return
    
    m.nameLabel.text = content.name
    
    m.fallbackBg.color = getColorFromHash(content.name)
    m.fallbackLabel.text = getInitials(content.name)
    
    if content.favorite = true
        m.favStar.visible = true
    else
        m.favStar.visible = false
    end if
    
    if content.compatible = false
        m.badge.visible = true
        ' Optionally dim the fallback background
        m.fallbackBg.opacity = 0.5
    else
        m.badge.visible = false
        m.fallbackBg.opacity = 1.0
    end if
    
    info = EpgFind(m.global.epg, content.name, m.global.nowSec)
    if info.now <> invalid
        m.epgLabel.text = info.now.t
    else
        m.epgLabel.text = ""
    end if
end sub

sub onFocusChange()
    m.focusBorder.visible = (m.top.focusPercent > 0.5)
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
