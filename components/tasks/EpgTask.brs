' EpgTask: downloads epg.json, caches it, parses it

sub init()
    m.top.functionName = "runEpg"
end sub

sub runEpg()
    url = m.top.epgUrl
    if url = invalid or url = ""
        m.top.status = "error"
        return
    end if
    
    port = CreateObject("roMessagePort")
    req = CreateObject("roUrlTransfer")
    req.SetUrl(url)
    req.SetMessagePort(port)
    req.SetCertificatesFile("common:/certs/ca-bundle.crt")
    req.InitClientCertificates()
    req.EnableEncodings(true)
    
    if req.AsyncGetToString()
        msg = wait(30000, port)
        if type(msg) = "roUrlEvent"
            code = msg.GetResponseCode()
            if code = 200
                body = msg.GetString()
                if body <> ""
                    parsed = ParseJson(body)
                    if parsed <> invalid
                        fs = CreateObject("roFileSystem")
                        WriteAsciiFile("cachefs:/epg.json", body)
                        
                        m.top.result = parsed
                        m.top.status = "ok"
                        return
                    end if
                end if
            end if
        end if
    end if
    
    ' Error or timeout, try from cache
    fs = CreateObject("roFileSystem")
    if fs.Exists("cachefs:/epg.json")
        body = ReadAsciiFile("cachefs:/epg.json")
        parsed = ParseJson(body)
        if parsed <> invalid
            m.top.result = parsed
            m.top.status = "cache"
            return
        end if
    end if
    
    m.top.status = "error"
end sub
