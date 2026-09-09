' EpgTask: downloads epg.json, caches it, parses it

sub init()
    m.top.functionName = "runEpg"
end sub

sub runEpg()
    url = m.top.epgUrl
    if url = invalid or url = ""
        failEpg("no EPG URL configured")
        return
    end if

    port = CreateObject("roMessagePort")
    req = CreateObject("roUrlTransfer")
    req.SetUrl(url)
    req.SetMessagePort(port)
    req.SetCertificatesFile("common:/certs/ca-bundle.crt")
    req.InitClientCertificates()
    req.EnableEncodings(true)

    reason = "request could not be started"
    if req.AsyncGetToString()
        msg = wait(30000, port)
        if type(msg) = "roUrlEvent"
            code = msg.GetResponseCode()
            if code = 200
                body = msg.GetString()
                if body <> ""
                    parsed = ParseJson(body)
                    if isUsableEpgPayload(parsed)
                        WriteAsciiFile("cachefs:/epg.json", body)

                        m.top.result = parsed
                        m.top.status = "ok"
                        return
                    else
                        reason = "response was not a usable guide"
                    end if
                else
                    reason = "empty response body"
                end if
            else
                reason = "HTTP " + code.ToStr()
            end if
        else
            reason = "timed out after 30s"
        end if
    end if

    ' Network path failed. Fall back to the cache -- a stale guide beats none.
    fs = CreateObject("roFileSystem")
    if fs.Exists("cachefs:/epg.json")
        body = ReadAsciiFile("cachefs:/epg.json")
        parsed = ParseJson(body)
        if isUsableEpgPayload(parsed)
            m.top.result = parsed
            m.top.status = "cache"
            return
        end if
        failEpg(reason + "; cached guide unusable too")
        return
    end if

    failEpg(reason + "; no cached guide")
end sub

' Set the reason BEFORE the status: status is the observed field, so MainScene must
' find `error` already populated when its handler runs.
' The URL is deliberately not included -- the user can type any URL in Settings, and
' PlaylistTask.maskToken is not in this component's namespace.
sub failEpg(reason as string)
    m.top.error = reason
    m.top.status = "error"
end sub

function isUsableEpgPayload(parsed as dynamic) as boolean
    if parsed = invalid then return false
    if GetInterface(parsed, "ifAssociativeArray") = invalid then return false
    if parsed.epg = invalid then return false
    if GetInterface(parsed.epg, "ifAssociativeArray") = invalid then return false
    ' An empty map is structurally valid and useless. Rejecting it stops a degenerate
    ' publish ({"count":0,"epg":{}}) from overwriting a good cache with nothing. The
    ' map is checked rather than the payload's own `count`, which is self-reported.
    ' Zero is the only scale-free threshold: this file is keyed by the curated
    ' channels.txt names, so the device cannot know how many entries to expect. The
    ' real floor lives upstream in epg/generate_epg.py, which knows that number.
    return parsed.epg.Count() > 0
end function
