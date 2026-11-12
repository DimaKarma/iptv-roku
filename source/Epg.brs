' Return {now, next} for a channel. epgMap = m.global.epg (may be invalid).
function EpgFind(epgMap as object, name as string, nowSec as dynamic) as object
    res = { now: invalid, next: invalid }
    if epgMap = invalid or name = invalid or name = "" then return res
    list = epgMap[name]
    if list = invalid then return res
    now = nowSec
    if now = invalid or now <= 0 then now = CreateObject("roDateTime").AsSeconds()
    for i = 0 to list.Count() - 1
        p = list[i]
        if p.s <= now and now < p.e
            res.now = p
            if i + 1 < list.Count() then res.next = list[i + 1]
            return res
        else if p.s > now
            if res.next = invalid then res.next = p
            return res
        end if
    end for
    return res
end function

' Title of the programme on now, or "" (no guide, no entry, nothing on). The caller reads
' m.global.epg ONCE per batch and passes it in: an assocarray field read copies the whole
' map, so reading it per card is what made the Recent grid slow.
function EpgNowText(epgMap as dynamic, name as string, nowSec as dynamic) as string
    if epgMap = invalid then return ""
    info = EpgFind(epgMap, name, nowSec)
    if info.now <> invalid and info.now.t <> invalid then return info.now.t
    return ""
end function

' Unix UTC epoch -> "HH:MM" in the TV's local time.
function EpgFmtHM(epoch as integer) as string
    dt = CreateObject("roDateTime")
    dt.FromSeconds(epoch)
    dt.ToLocalTime()
    h = dt.GetHours().ToStr()
    mn = dt.GetMinutes().ToStr()
    if h.Len() = 1 then h = "0" + h
    if mn.Len() = 1 then mn = "0" + mn
    return h + ":" + mn
end function
