' Translit.brs: NameSkeleton(), the lossy key that lets Search match a Latin query
' against a Cyrillic channel name and the other way round.
'
' THIS FILE CONTAINS NO CYRILLIC. Every Cyrillic letter is a code point (&h4xx) in the
' table below, because the pre-push scan blocks Cyrillic in the tree.
'
' A host-side Python port with the SAME function names and the SAME step order lives in
' the builder's scratch folder (skeleton_port.py). Keep the two structurally parallel:
' the port is the only executable evidence that the algorithm is self-consistent, and no
' host here can run BrightScript.
'
' Applied identically to channel names (PlaylistTask stores it as ch.sk) and to the query
' (SearchScreen). Steps, in this order:
'   1. walk the characters with Mid(s, i, 1). ASCII letters are lower-cased, digits are
'      kept, every other ASCII character is dropped. Each Cyrillic letter is replaced by
'      its Latin transliteration (hard and soft signs by nothing). Any other non-ASCII
'      character is dropped.
'   2. fold the ASCII result, longest first: shch->sh, sch->sh, kh->h, ts->c, x->h,
'      y->i, j->i, then collapse ii->i until none is left.
' The ts->c fold makes the skeleton of "sport" a non-substring of the skeleton of
' "Sports TV" ("sporctv"), which is why Search ALSO tries the raw lower-cased substring.
'
' Returns "" for invalid or non-string input.
function NameSkeleton(s as dynamic) as string
    if s = invalid then return ""
    if GetInterface(s, "ifString") = invalid then return ""
    n = Len(s)
    if n = 0 then return ""

    ' Built only when a non-ASCII character is met, so pure-ASCII names stay cheap. The
    ' table itself is cached on the caller's m (m.skTbl): rebuilding its ~100 entries for
    ' every Cyrillic name cost startup time on a 1500-channel playlist.
    tbl = invalid
    out = ""
    for i = 1 to n
        c = Mid(s, i, 1)
        a = Asc(c)
        if a < 128
            if a >= 65 and a <= 90
                out = out + LCase(c)
            else if (a >= 97 and a <= 122) or (a >= 48 and a <= 57)
                out = out + c
            end if
        else
            if tbl = invalid
                if m.skTbl = invalid then m.skTbl = skCyrillicTable()
                tbl = m.skTbl
            end if
            rep = tbl[a.ToStr()]
            if rep <> invalid then out = out + rep
        end if
    end for

    return skFold(out)
end function

' code point (as a decimal string) -> Latin transliteration.
function skCyrillicTable() as object
    ' U+0410..U+042F in order: A B V G D E ZH Z I I(short) K L M N O P R S T U F KH TS CH
    ' SH SHCH hard-sign Y soft-sign E(reversed) IU IA. The lower-case letters sit exactly
    ' 0x20 higher and map the same way.
    names = ["a", "b", "v", "g", "d", "e", "zh", "z", "i", "i", "k", "l", "m", "n", "o", "p", "r", "s", "t", "u", "f", "kh", "ts", "ch", "sh", "shch", "", "y", "", "e", "iu", "ia"]
    tbl = {}
    for j = 0 to 31
        capCode = &h410 + j
        lowCode = &h430 + j
        skPut(tbl, capCode, names[j])
        skPut(tbl, lowCode, names[j])
    end for
    ' IO (yo) -> e. Ukrainian: YE -> e, I -> i, YI -> i, GHE-with-upturn -> g.
    skPut(tbl, &h401, "e")
    skPut(tbl, &h451, "e")
    skPut(tbl, &h404, "e")
    skPut(tbl, &h454, "e")
    skPut(tbl, &h406, "i")
    skPut(tbl, &h456, "i")
    skPut(tbl, &h407, "i")
    skPut(tbl, &h457, "i")
    skPut(tbl, &h490, "g")
    skPut(tbl, &h491, "g")
    return tbl
end function

sub skPut(tbl as object, code as integer, rep as string)
    key = code.ToStr()
    tbl[key] = rep
end sub

' Folds on an ASCII-only string. Order matters and mirrors the Python port.
function skFold(t as string) as string
    t = skReplaceAll(t, "shch", "sh")
    t = skReplaceAll(t, "sch", "sh")
    t = skReplaceAll(t, "kh", "h")
    t = skReplaceAll(t, "ts", "c")
    t = skReplaceAll(t, "x", "h")
    t = skReplaceAll(t, "y", "i")
    t = skReplaceAll(t, "j", "i")
    while t.Instr("ii") >= 0
        t = skReplaceAll(t, "ii", "i")
    end while
    return t
end function

' Replace every occurrence of pat. Own loop rather than a platform Replace method: this
' project has never used that method, and the input is ASCII, so byte and character
' offsets agree. Instr and Mid here are the 0-based METHOD forms, like M3uParser.brs.
function skReplaceAll(s as string, pat as string, repl as string) as string
    plen = pat.Len()
    if plen = 0 then return s
    out = ""
    startAt = 0
    while true
        idx = s.Instr(startAt, pat)
        if idx < 0 then exit while
        out = out + s.Mid(startAt, idx - startAt) + repl
        startAt = idx + plen
    end while
    return out + s.Mid(startAt)
end function
