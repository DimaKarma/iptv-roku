' ChannelStore: manages favorites and recent channels in registry

function getRegistrySection() as object
    return CreateObject("roRegistrySection", "userdata")
end function

function LoadFavorites() as object
    sec = getRegistrySection()
    if sec <> invalid and sec.Exists("favorites")
        json = sec.Read("favorites")
        if json <> invalid and json <> ""
            parsed = ParseJson(json)
            if parsed <> invalid then return parsed
        end if
    end if
    return []
end function

function SaveFavorites(favs as object) as void
    sec = getRegistrySection()
    if sec <> invalid
        json = FormatJson(favs)
        sec.Write("favorites", json)
        sec.Flush()
    end if
end function

function IsFavorite(name as string) as boolean
    if name = invalid or name = "" return false
    favs = LoadFavorites()
    if favs <> invalid
        for each f in favs
            if f = name then return true
        end for
    end if
    return false
end function

function ToggleFavorite(name as string) as boolean
    if name = invalid or name = "" return false
    favs = LoadFavorites()
    if favs = invalid then favs = []
    
    idx = -1
    for i = 0 to favs.Count() - 1
        if favs[i] = name
            idx = i
            exit for
        end if
    end for
    
    isFav = false
    if idx >= 0
        favs.Delete(idx)
        isFav = false
    else
        favs.Push(name)
        isFav = true
    end if
    
    SaveFavorites(favs)
    return isFav
end function

function LoadRecents() as object
    sec = getRegistrySection()
    if sec <> invalid and sec.Exists("recents")
        json = sec.Read("recents")
        if json <> invalid and json <> ""
            parsed = ParseJson(json)
            if parsed <> invalid then return parsed
        end if
    end if
    return []
end function

function SaveRecents(recents as object) as void
    sec = getRegistrySection()
    if sec <> invalid
        json = FormatJson(recents)
        sec.Write("recents", json)
        sec.Flush()
    end if
end function

function PushRecent(name as string) as void
    if name = invalid or name = "" return
    recents = LoadRecents()
    if recents = invalid then recents = []
    
    idx = -1
    for i = 0 to recents.Count() - 1
        if recents[i] = name
            idx = i
            exit for
        end if
    end for
    
    if idx >= 0
        recents.Delete(idx)
    end if
    
    recents.Unshift(name)
    
    while recents.Count() > 20
        recents.Pop()
    end while
    
    SaveRecents(recents)
end function

' Старые записи — URL (содержат "://"). Конвертировать по текущему плейлисту, несматченные отбросить.
sub MigrateStoreToNames(channels as object)
    if channels = invalid then return
    urlToName = {}
    for each ch in channels
        if ch.url <> invalid and ch.name <> invalid then urlToName[ch.url] = ch.name
    end for
    migrateList("favorites", urlToName)
    migrateList("recents", urlToName)
end sub

sub migrateList(key as string, urlToName as object)
    sec = getRegistrySection()
    if sec = invalid or not sec.Exists(key) then return
    parsed = ParseJson(sec.Read(key))
    if parsed = invalid then return
    changed = false
    seen = {}
    result = []
    for each entry in parsed
        val = entry
        if entry.Instr("://") >= 0
            changed = true
            val = urlToName[entry]   ' invalid, если канал исчез
        end if
        if val <> invalid and seen[val] = invalid
            seen[val] = true
            result.Push(val)
        end if
    end for
    if changed
        sec.Write(key, FormatJson(result))
        sec.Flush()
    end if
end sub
