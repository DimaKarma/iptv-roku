' source/M3uParser.brs
' Parser for M3U playlists

function ParseM3U(text as string) as object
    result = {
        epgUrl: "",
        channels: []
    }
    
    if text = invalid or text = "" then return result
    
    ' Strip BOM if present (UTF-8)
    if text.Left(3) = Chr(239) + Chr(187) + Chr(191)
        text = text.Mid(3)
    else if Asc(text.Left(1)) = 65279
        text = text.Mid(1)
    end if
    
    lines = text.Split(chr(10))
    currentChannel = invalid
    
    for each rawLine in lines
        line = rawLine.Trim()
        
        ' Handle \r from \r\n if Trim didn't catch it
        if line.Len() > 0 and line.Right(1) = chr(13)
            line = line.Left(line.Len() - 1).Trim()
        end if
        
        if line <> ""
            if line.StartsWith("#EXTM3U")
                epgMatch = extractAttribute(line, "url-tvg")
                if epgMatch <> "" then result.epgUrl = epgMatch
            else if line.StartsWith("#EXTINF:")
                currentChannel = {}
                ' parse EXTINF
                commaPos = FirstUnquotedComma(line)
                if commaPos >= 0
                    currentChannel.name = line.Mid(commaPos + 1).Trim()
                    attrsStr = line.Mid(8, commaPos - 8)
                    
                    currentChannel.tvgId = extractAttribute(attrsStr, "tvg-id")
                    currentChannel.tvgName = extractAttribute(attrsStr, "tvg-name")
                    currentChannel.logo = extractAttribute(attrsStr, "tvg-logo")
                    
                    rec = extractAttribute(attrsStr, "tvg-rec")
                    currentChannel.catchup = (rec = "1")
                    
                    currentChannel.group = extractAttribute(attrsStr, "group-title")
                else
                    currentChannel.name = "Unknown"
                end if
            else if line.StartsWith("#EXTGRP:")
                if currentChannel <> invalid
                    groupName = line.Mid(8).Trim()
                    if groupName <> ""
                        ' Priority: group-title -> #EXTGRP
                        if currentChannel.group = invalid or currentChannel.group = ""
                            currentChannel.group = groupName
                        end if
                    end if
                end if
            else if not line.StartsWith("#")
                ' This is a URL line
                if currentChannel <> invalid
                    urlLower = LCase(line)
                    if urlLower.Instr(".m3u8") >= 0
                        currentChannel.streamType = "hls"
                        currentChannel.compatible = true
                    else if urlLower.EndsWith(".ts")
                        currentChannel.streamType = "ts"
                        currentChannel.compatible = false
                    else
                        currentChannel.streamType = "other"
                        currentChannel.compatible = false
                    end if
                    
                    if currentChannel.group = invalid or currentChannel.group = ""
                        currentChannel.group = "Uncategorized"
                    end if
                    
                    ' Default missing fields
                    if currentChannel.logo = invalid then currentChannel.logo = ""
                    if currentChannel.tvgId = invalid then currentChannel.tvgId = ""
                    if currentChannel.tvgName = invalid then currentChannel.tvgName = ""
                    if currentChannel.catchup = invalid then currentChannel.catchup = false
                    
                    currentChannel.url = line
                    result.channels.Push(currentChannel)
                    currentChannel = invalid
                end if
            end if
        end if
    end for
    
    return result
end function

' Index (Instr convention) of the first comma that is NOT inside a quoted attribute
' value, or -1.
'
' #EXTINF attributes are key="value" pairs and the channel name is everything after
' the comma that ends them. Splitting on the FIRST comma broke every line whose
' attributes contain one: the Sport2 playlist sets
'   http-user-agent="Mozilla/5.0 (...) AppleWebKit/537.36 (KHTML, like Gecko) ..."
' and the comma in "(KHTML, like Gecko)" was taken as the separator, so 98 of its 467
' channels were named after a fragment of a browser user-agent string.
'
' Splitting on the LAST unquoted comma would fix those but break any name that
' legitimately contains a comma ("Sport, Live"). The first UNQUOTED comma is right in
' both cases: it ends the attribute region, and everything after it -- commas included
' -- is the name.
'
' Walks by index only (Instr with a start offset) and never slices with Left or Mid:
' on this device Left is byte-based while Mid is not, and mixing them splits Cyrillic.
function FirstUnquotedComma(line as string) as integer
    inQuote = false
    pos = 0
    while true
        q = line.Instr(pos, chr(34))
        c = line.Instr(pos, ",")
        if c < 0 then return -1
        if q < 0 or c < q
            if not inQuote then return c
            pos = c + 1
        else
            inQuote = not inQuote
            pos = q + 1
        end if
    end while
    return -1
end function

function extractAttribute(text as string, attrName as string) as string
    searchStr = attrName + "=" + chr(34)
    startPos = text.Instr(searchStr)
    if startPos >= 0
        startPos = startPos + searchStr.Len()
        endPos = text.Instr(startPos, chr(34))
        if endPos >= 0
            return text.Mid(startPos, endPos - startPos)
        end if
    end if
    return ""
end function
