' Task for fetching, caching, and parsing M3U playlist

sub init()
    m.top.functionName = "runPlaylist"
end sub

sub runPlaylist()
    ' FIRST step: the Clear cache action. It lives here, in a Task, because
    ' CreateObject("roFileSystem") is forbidden on the render thread (rule 20) and the
    ' Settings screen used to call it there.
    if m.top.clearCache then clearCacheFiles()

    url = ""
    
    ' 1. Resolve URL: registry > config.json
    sec = CreateObject("roRegistrySection", "settings")
    if sec.Exists("playlistUrl")
        regUrl = sec.Read("playlistUrl")
        if regUrl <> "" then url = regUrl
    end if
    
    if url = "" then url = m.top.playlistUrl
    
    if url = ""
        m.top.error = "No playlist URL set"
        m.top.status = "error"
        return
    end if
    
    ' 2. Read cache metadata
    meta = invalid
    metaStr = ""
    if CreateObject("roFileSystem").Exists("cachefs:/playlist_meta.json")
        metaStr = ReadAsciiFile("cachefs:/playlist_meta.json")
    end if
    if metaStr <> ""
        meta = ParseJson(metaStr)
    end if
    
    ' 3. roUrlTransfer
    http = CreateObject("roUrlTransfer")
    http.SetUrl(url)
    http.EnableEncodings(true)
    http.SetCertificatesFile("common:/certs/ca-bundle.crt")
    http.InitClientCertificates()
    http.RetainBodyOnError(true)
    
    if not m.top.forceReload and meta <> invalid and meta.sourceUrl <> invalid and meta.sourceUrl = url
        if meta.etag <> invalid and meta.etag <> ""
            http.AddHeader("If-None-Match", meta.etag)
        end if
        if meta.lastModified <> invalid and meta.lastModified <> ""
            http.AddHeader("If-Modified-Since", meta.lastModified)
        end if
    end if
    
    ' Perform GET
    port = CreateObject("roMessagePort")
    http.SetMessagePort(port)
    
    respBody = ""
    respCode = 0
    headers = {}
    
    if http.AsyncGetToString()
        ev = wait(30000, port)
        if type(ev) = "roUrlEvent"
            respCode = ev.GetResponseCode()
            respBody = ev.GetString()
            headers = ev.GetResponseHeaders()
        else
            respCode = 0
        end if
    else
        respCode = 0
    end if
    
    ' 4. Process response
    if respCode = 200 and respBody <> ""
        startTime = CreateObject("roTimespan")
        startTime.Mark()
        
        parsed = ParseM3U(respBody)
        
        parseDuration = startTime.TotalMilliseconds()
        
        ' The MAIN playlist must yield at least one channel, checked BEFORE any extra is
        ' merged (the extras would otherwise make a dead main playlist look healthy).
        ' Anything else -- an HTML error page served with a 200, a truncated body -- takes
        ' the cache-fallback path and writes neither the cache nor the meta.
        if parsed.channels.Count() < 1
            print "PlaylistTask: main playlist parsed to 0 channels. Trying cache..."
            fallbackToCache("Playlist had no channels")
            return
        end if
        
        ' Merge extra playlists (config-defined) -- each tagged under a fixed category.
        ' When an extra cannot be fetched (or yields nothing), the channels of that
        ' category are taken from the cached result instead of vanishing with it.
        extras = m.top.extraPlaylists
        if extras <> invalid
            cached = invalid
            cachedRead = false
            for each ex in extras
                exUrl = ex.url
                exCat = ex.category
                if exUrl <> invalid and exUrl <> "" and exCat <> invalid and exCat <> ""
                    addedCount = 0
                    body2 = fetchUrlBody(exUrl)
                    if body2 <> ""
                        p2 = ParseM3U(body2)
                        for each ch in p2.channels
                            ch.group = exCat            ' override group -> "Sport2"
                            parsed.channels.Push(ch)
                            addedCount = addedCount + 1
                        end for
                    end if
                    if addedCount > 0
                        print "PlaylistTask: extra '" + exCat + "' +" + addedCount.ToStr() + " channels"
                    else
                        print "PlaylistTask: extra '" + exCat + "' fetch failed or empty. Using cached channels."
                        if not cachedRead
                            cached = readCachedResult()
                            cachedRead = true
                        end if
                        if cached <> invalid and cached.channels <> invalid
                            keptCount = 0
                            for each cch in cached.channels
                                if cch.group = exCat
                                    parsed.channels.Push(cch)
                                    keptCount = keptCount + 1
                                end if
                            end for
                            print "PlaylistTask: extra '" + exCat + "' kept " + keptCount.ToStr() + " cached channels"
                        end if
                    end if
                end if
            end for
        end if
        
        AddSkeletons(parsed.channels)
        built = BuildCategoryList(parsed.channels)
        categories = built.categories
        totalChannels = parsed.channels.Count()
        incompatibleCount = built.incompatible
        
        ' Print debug info (masking url)
        safeLogUrl = maskToken(url)
        print "PlaylistTask: Downloaded from " + safeLogUrl
        print "PlaylistTask: Parse duration = " + parseDuration.ToStr() + " ms"
        print "PlaylistTask: Total channels = " + totalChannels.ToStr()
        print "PlaylistTask: Incompatible (.ts/other) = " + incompatibleCount.ToStr()
        
        print "PlaylistTask: First ~15 categories:"
        catLogLimit = 15
        if categories.Count() < 15 then catLogLimit = categories.Count()
        for i = 0 to catLogLimit - 1
            print " - " + categories[i].title + ": " + categories[i].count.ToStr()
        end for
        
        epoch = CreateObject("roDateTime").AsSeconds()
        
        result = {
            version: 1,
            fetchedAt: epoch,
            source: "network",
            epgUrl: parsed.epgUrl,
            channels: parsed.channels,
            categories: categories
        }
        
        ' Write to cache
        WriteAsciiFile("cachefs:/playlist.json", FormatJson(result))
        
        newMeta = {
            sourceUrl: url,
            etag: "",
            lastModified: ""
        }
        if headers <> invalid
            if headers["etag"] <> invalid then newMeta.etag = headers["etag"]
            if headers["last-modified"] <> invalid then newMeta.lastModified = headers["last-modified"]
        end if
        WriteAsciiFile("cachefs:/playlist_meta.json", FormatJson(newMeta))
        
        m.top.result = result
        m.top.status = "ok"
        
    else if respCode = 304
        print "PlaylistTask: 304 Not Modified. Loading from cache..."
        if not loadFromCache("ok")
            ' The server says our copy is current but the copy is gone. Without this the
            ' status was never set and the loading spinner ran forever. The stale meta is
            ' deleted too, so that the retry is an unconditional fetch rather than the
            ' same 304 again.
            print "PlaylistTask: 304 but the cache is missing or unreadable"
            CreateObject("roFileSystem").Delete("cachefs:/playlist_meta.json")
            m.top.error = "Cached playlist is missing"
            m.top.status = "error"
        end if
        
    else
        print "PlaylistTask: HTTP Error " + respCode.ToStr() + " or empty body. Trying cache..."
        if respCode = 0
            fallbackToCache("No network")
        else
            fallbackToCache("Network error (code " + respCode.ToStr() + ")")
        end if
    end if
end sub

' The existing cache-fallback path, shared by the HTTP-failure branch and the
' zero-channel branch. reason + ", and the cache is empty" reproduces the old messages.
sub fallbackToCache(reason as string)
    cacheLoaded = loadFromCache("cache")
    if not cacheLoaded
        m.top.error = reason + ", and the cache is empty"
        m.top.status = "error"
    end if
end sub

' Delete the three cache files and print what existed BEFORE the deletion.
sub clearCacheFiles()
    fs = CreateObject("roFileSystem")
    hadPlaylist = fs.Exists("cachefs:/playlist.json")
    hadMeta = fs.Exists("cachefs:/playlist_meta.json")
    hadEpg = fs.Exists("cachefs:/epg.json")
    if hadPlaylist then fs.Delete("cachefs:/playlist.json")
    if hadMeta then fs.Delete("cachefs:/playlist_meta.json")
    if hadEpg then fs.Delete("cachefs:/epg.json")
    print "[CACHE] cleared playlist=" + boolText(hadPlaylist) + " meta=" + boolText(hadMeta) + " epg=" + boolText(hadEpg)
end sub

function boolText(b as boolean) as string
    if b then return "true"
    return "false"
end function

' Search key for every channel that does not carry one yet. Fresh parses have none, and
' a cache written before this field existed has none either (that cache is what a 304
' loads). The `version` field of the cache is NOT used: nothing reads it.
sub AddSkeletons(channels as object)
    if channels = invalid then return
    skTimer = CreateObject("roTimespan")
    skTimer.Mark()
    for each ch in channels
        if ch.sk = invalid then ch.sk = NameSkeleton(ch.name)
    end for
    print "PlaylistTask: skeletons ms=" + skTimer.TotalMilliseconds().ToStr() + " n=" + channels.Count().ToStr()
end sub

' Categories for a merged channel list: "All" first, then the groups sorted
' case-insensitively. Returns { categories, incompatible }.
function BuildCategoryList(channels as object) as object
    categories = []
    catMap = {}
    incompatibleCount = 0
    
    for each ch in channels
        if not ch.compatible then incompatibleCount = incompatibleCount + 1
        
        grp = ch.group
        if catMap[grp] = invalid
            catMap[grp] = 1
        else
            catMap[grp] = catMap[grp] + 1
        end if
    end for
    
    ' Sort groups alphabetically (case-insensitive)
    keys = catMap.Keys()
    keys.Sort("i")
    
    categories.Push({ title: "All", count: channels.Count() })
    for each k in keys
        categories.Push({ title: k, count: catMap[k] })
    end for
    
    return { categories: categories, incompatible: incompatibleCount }
end function

function fetchUrlBody(url as string) as string
    http = CreateObject("roUrlTransfer")
    http.SetUrl(url)
    http.EnableEncodings(true)
    http.SetCertificatesFile("common:/certs/ca-bundle.crt")
    http.InitClientCertificates()
    http.RetainBodyOnError(true)
    port = CreateObject("roMessagePort")
    http.SetMessagePort(port)
    if http.AsyncGetToString()
        ev = wait(30000, port)
        if type(ev) = "roUrlEvent" and ev.GetResponseCode() = 200
            return ev.GetString()
        end if
    end if
    return ""
end function

' The parsed cached playlist, or invalid.
function readCachedResult() as dynamic
    cachedStr = ""
    if CreateObject("roFileSystem").Exists("cachefs:/playlist.json")
        cachedStr = ReadAsciiFile("cachefs:/playlist.json")
    end if
    if cachedStr <> ""
        return ParseJson(cachedStr)
    end if
    return invalid
end function

function loadFromCache(statusIfSuccess as string) as boolean
    cached = readCachedResult()
    if cached <> invalid
        ' An older cache has no search keys. Added here, in memory only.
        AddSkeletons(cached.channels)
        cached.source = "cache"
        m.top.result = cached
        m.top.status = statusIfSuccess
        return true
    end if
    return false
end function

function maskToken(url as string) as string
    markers = ["/iptv/", "/uplist/"]
    for each mk in markers
        startIdx = url.Instr(mk)
        if startIdx >= 0
            segStart = startIdx + mk.Len()
            endIdx = url.Instr(segStart, "/")
            if endIdx >= 0
                url = url.Left(segStart) + "***" + url.Mid(endIdx)
            end if
        end if
    end for
    return url
end function
