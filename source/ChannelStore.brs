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

' One-shot restore from a seed shipped inside the package.
'
' A dev install can clear the whole `userdata` registry section. It happened in July
' with a corrupt zip, and again on 2026-09-09 after an install that failed to compile
' -- both times the favourites were gone. The registry is the only durable store on
' the device (a reinstall wipes cachefs), so the recovery path has to come in with the
' package itself.
'
' Seeds ONLY when the whole `userdata` section has no keys at all, which is what a wipe
' leaves behind. A list the user emptied on purpose keeps its key (SaveFavorites writes
' "[]"), so it is left alone: the trigger used to be "this key's list is empty", which
' put a hand-emptied favourites list back from the seed. That makes the file inert on
' every start after the first: it can never overwrite what the user has built up, and it
' needs no flag, no version counter and no cleanup.
sub RestoreStoreIfEmpty()
    raw = ReadAsciiFile("pkg:/source/restore.json")
    if raw = "" then return          ' no seed shipped; ReadAsciiFile logs, returns ""
    seed = ParseJson(raw)
    if seed = invalid then return

    sectionEmpty = false
    sec = getRegistrySection()
    if sec <> invalid
        keys = sec.GetKeyList()
        if keys = invalid or keys.Count() = 0 then sectionEmpty = true
    end if

    if seed.favorites <> invalid and sectionEmpty
        SaveFavorites(seed.favorites)
        print "[STORE] restored favorites=" + seed.favorites.Count().ToStr()
    end if

    if seed.recents <> invalid and sectionEmpty
        SaveRecents(seed.recents)
        print "[STORE] restored recents=" + seed.recents.Count().ToStr()
    end if
end sub

' Print favorites and recents to the debug console (port 8085) so they can be captured
' OFF the device before a sideload.
'
' Do NOT assume the registry survives an install. It was measured surviving one in
' TASK-21/TASK-24, but on 2026-09-09 an install wiped the whole `userdata` section --
' 31 favourites to zero -- most likely because the install before it had failed to
' compile and unloaded the channel. A corrupt zip did the same in July. cachefs is no
' help either: a reinstall wipes it. The console is the only way this data leaves the
' box, so deploy.ps1 captures these two lines before it installs anything.
' Format is deliberately one key per line with a fixed prefix, so a capture script can
' find them without parsing the surrounding log.
sub DumpStore()
    favs = LoadFavorites()
    recents = LoadRecents()
    if favs = invalid then favs = []
    if recents = invalid then recents = []
    print "[STORE] favorites=" + FormatJson(favs)
    print "[STORE] recents=" + FormatJson(recents)
end sub

' Old entries are URLs (contain "://"). Convert them using the current playlist; drop unmatched.
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
            val = urlToName[entry]   ' invalid if the channel is gone
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

' "Взрослые" is the provider's adult category name (#EXTGRP) — a data literal, not UI text.
function IsAdultGroup(group as dynamic) as boolean
    if group = invalid then return false
    return group = "Взрослые"
end function

' Resume last channel. The key holds the PLAIN name of the last non-adult channel that
' played for 10 s, or is absent. It is written from exactly one place (the player's
' recent timer) and removed from the player's adult branch and from the purge below.
' Console lines never carry a channel name.
sub SaveLastChannel(name as string)
    if name = "" then return
    sec = getRegistrySection()
    if sec = invalid
        print "[RESUME] save failed"
        return
    end if
    wrote = sec.Write("lastChannel", name)
    flushed = sec.Flush()
    if wrote <> true or flushed <> true then print "[RESUME] save failed"
end sub

' No registry call at all when the key is already absent.
sub ClearLastChannel()
    sec = getRegistrySection()
    if sec = invalid then return
    if not sec.Exists("lastChannel") then return
    removed = sec.Delete("lastChannel")
    flushed = sec.Flush()
    if removed = true and flushed = true then return
    ' Delete or Flush failed: blank the value instead (LoadLastChannel treats "" as none).
    wrote = sec.Write("lastChannel", "")
    flushed2 = sec.Flush()
    if wrote <> true or flushed2 <> true then print "[RESUME] clear failed"
end sub

function LoadLastChannel() as string
    sec = getRegistrySection()
    if sec = invalid then return ""
    if not sec.Exists("lastChannel") then return ""
    val = sec.Read("lastChannel")
    if val = invalid then return ""
    return val
end function

' Setting `Resume last channel`: absent or "1" = On, "0" = Off.
function IsResumeEnabled() as boolean
    sec = CreateObject("roRegistrySection", "settings")
    if sec = invalid then return true
    if not sec.Exists("resumeLast") then return true
    return sec.Read("resumeLast") <> "0"
end function

sub SetResumeEnabled(enabled as boolean)
    sec = CreateObject("roRegistrySection", "settings")
    if sec = invalid then return
    if enabled
        sec.Write("resumeLast", "1")
    else
        sec.Write("resumeLast", "0")
    end if
    sec.Flush()
end sub

' Remove any already-stored Recent entries whose channel is in the adult group, and the
' stored last channel when its name is in that set now (the provider may have moved it).
' Returns how many channels of the adult group the playlist holds: the caller treats 0 as
' "the classifier no longer matches anything" and disables resume.
function PurgeAdultFromRecents(channels as object) as integer
    if channels = invalid then return 0
    adult = {}
    adultCount = 0
    for each ch in channels
        if IsAdultGroup(ch.group)
            adultCount = adultCount + 1
            if ch.name <> invalid then adult[ch.name] = true
        end if
    end for

    last = LoadLastChannel()
    if last <> "" and adult[last] <> invalid then ClearLastChannel()

    recents = LoadRecents()
    if recents = invalid or recents.Count() = 0 then return adultCount

    result = []
    changed = false
    for each r in recents
        if adult[r] <> invalid
            changed = true          ' drop this adult entry
        else
            result.Push(r)
        end if
    end for

    if changed then SaveRecents(result)
    return adultCount
end function
