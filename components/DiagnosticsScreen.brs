' DiagnosticsScreen: device probes for the Search S2 decision. Created by
' SettingsScreen only when the Diagnostics row is selected.
'
' Rules this file keeps:
'   * No probe runs in init(), on creation, or on a timer. A probe runs when its row is
'     selected, once per press.
'   * Each probe creates its node BY STRING, checks for invalid, and prints exactly one
'     "[PROBE] <name> ..." line on the debug console (port 8085).
'   * The rule 20 probe only tests whether CreateObject("roFileSystem") came back
'     invalid. It NEVER calls a method on the result: on the render thread the next call
'     on the failed object is what raised &hec.

sub init()
    m.probeList = m.top.findNode("probeList")
    m.resultLabel = m.top.findNode("resultLabel")

    theme = getTheme()
    if theme <> invalid
        m.top.findNode("titleLabel").color = theme.colorText
        m.probeList.color = theme.colorTextDim
        m.probeList.focusedColor = theme.colorOnAccent
        m.resultLabel.color = theme.colorTextDim
    end if

    content = CreateObject("roSGNode", "ContentNode")
    addProbe(content, "MiniKeyboard")
    addProbe(content, "DynamicCustomKeyboard")
    addProbe(content, "Rule 8: arrows from a Keyboard")
    addProbe(content, "Rule 20: roFileSystem on this thread")
    m.probeList.content = content
    ' Parallel list of probe ids, same order as the titles above.
    m.probeIds = ["mini", "dynamic", "rule8", "rule20"]

    m.probeList.observeField("itemSelected", "onProbeSelected")

    ' State of the rule 8 probe. kbProbe is a Keyboard created by string on demand.
    m.rule8Active = false
    m.arrowsSeen = 0
    m.kbProbe = invalid
end sub

sub addProbe(parent as object, title as string)
    item = parent.createChild("ContentNode")
    item.title = title
end sub

sub onOpen()
    m.top.visible = true
    if m.kbProbe <> invalid then endRule8Probe()
    m.probeList.setFocus(true)
end sub

sub onProbeSelected()
    idx = m.probeList.itemSelected
    if idx < 0 or idx >= m.probeIds.Count() then return
    probeId = m.probeIds[idx]
    if probeId = "mini"
        probeCreate("MiniKeyboard")
    else if probeId = "dynamic"
        probeCreate("DynamicCustomKeyboard")
    else if probeId = "rule8"
        startRule8Probe()
    else if probeId = "rule20"
        probeRule20()
    end if
end sub

' Create a node by type name, report whether it exists and, if it does, its bounding
' rect. The node is never attached to the screen and is dropped when the sub returns.
sub probeCreate(typeName as string)
    node = CreateObject("roSGNode", typeName)
    if node = invalid
        report("[PROBE] " + typeName + " created=false")
        return
    end if
    line = "[PROBE] " + typeName + " created=true"
    r = node.boundingRect()
    if r <> invalid
        line = line + " rect w=" + numText(r.width) + " h=" + numText(r.height)
    else
        line = line + " rect=invalid"
    end if
    report(line)
end sub

' Rule 8 says a focused Keyboard swallows every arrow, so none reaches onKeyEvent. This
' probe puts a real Keyboard on screen, focuses it and counts the arrows that DO arrive
' here. Back ends it and prints the count.
sub startRule8Probe()
    if m.kbProbe <> invalid then return
    kb = CreateObject("roSGNode", "Keyboard")
    if kb = invalid
        report("[PROBE] rule8 Keyboard created=false")
        return
    end if
    m.kbProbe = kb
    m.arrowsSeen = 0
    m.rule8Active = true
    kb.translation = [274, 300]
    m.top.appendChild(kb)
    kb.setFocus(true)
    m.resultLabel.text = "Rule 8 probe running. Press the arrow keys, then Back."
end sub

sub endRule8Probe()
    m.rule8Active = false
    if m.kbProbe <> invalid
        m.kbProbe.setFocus(false)
        m.top.removeChild(m.kbProbe)
        m.kbProbe = invalid
    end if
    report("[PROBE] rule8 arrows_reached_onKeyEvent=" + m.arrowsSeen.ToStr())
    m.probeList.setFocus(true)
end sub

' Only whether the object came back invalid. No method is ever called on it.
sub probeRule20()
    fs = CreateObject("roFileSystem")
    if fs = invalid
        report("[PROBE] rule20 roFileSystem=invalid")
    else
        report("[PROBE] rule20 roFileSystem=object")
    end if
end sub

sub report(line as string)
    print line
    m.resultLabel.text = line
end sub

function numText(v as dynamic) as string
    if v = invalid then return "?"
    return v.ToStr()
end function

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false
    if press
        if m.rule8Active
            if key = "back"
                endRule8Probe()
                handled = true
            else if key = "up" or key = "down" or key = "left" or key = "right"
                m.arrowsSeen = m.arrowsSeen + 1
            end if
        else if key = "back"
            m.top.visible = false
            m.top.exitRequested = not m.top.exitRequested
            handled = true
        end if
    end if
    return handled
end function
