' Task for fetching, caching, and parsing M3U playlist

sub init()
    m.top.functionName = "runPlaylist"
end sub

sub runPlaylist()
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
    
    if meta <> invalid and meta.sourceUrl <> invalid and meta.sourceUrl = url
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
        
        ' Merge extra playlists (config-defined) — each tagged under a fixed category
        extras = m.top.extraPlaylists
        if extras <> invalid
            for each ex in extras
                exUrl = ex.url
                exCat = ex.category
                if exUrl <> invalid and exUrl <> "" and exCat <> invalid and exCat <> ""
                    body2 = fetchUrlBody(exUrl)
                    if body2 <> ""
                        p2 = ParseM3U(body2)
                        addedCount = 0
                        for each ch in p2.channels
                            ch.group = exCat            ' перекрываем group -> "Sport2"
                            parsed.channels.Push(ch)
                            addedCount = addedCount + 1
                        end for
                        print "PlaylistTask: extra '" + exCat + "' +" + addedCount.ToStr() + " channels"
                    else
                        print "PlaylistTask: extra '" + exCat + "' fetch failed or empty"
                    end if
                end if
            end for
        end if
        
        ' Build categories
        categories = []
        catMap = {}
        totalChannels = parsed.channels.Count()
        incompatibleCount = 0
        
        for each ch in parsed.channels
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
        
        categories.Push({ title: "All", count: totalChannels })
        for each k in keys
            categories.Push({ title: k, count: catMap[k] })
        end for
        
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
        loadFromCache("ok")
        
    else
        print "PlaylistTask: HTTP Error " + respCode.ToStr() + " or empty body. Trying cache..."
        cacheLoaded = loadFromCache("cache")
        if not cacheLoaded
            if respCode = 0
                m.top.error = "No network, and the cache is empty"
            else
                m.top.error = "Network error (code " + respCode.ToStr() + "), and the cache is empty"
            end if
            m.top.status = "error"
        end if
    end if
end sub

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

function loadFromCache(statusIfSuccess as string) as boolean
    cachedStr = ""
    if CreateObject("roFileSystem").Exists("cachefs:/playlist.json")
        cachedStr = ReadAsciiFile("cachefs:/playlist.json")
    end if
    if cachedStr <> ""
        cached = ParseJson(cachedStr)
        if cached <> invalid
            cached.source = "cache"
            m.top.result = cached
            m.top.status = statusIfSuccess
            return true
        end if
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
