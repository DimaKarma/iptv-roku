function getTheme()
    return {
        colorBg:          "0x020B13FF",
        colorSurface:     "0x062230FF",
        colorSurfaceHi:   "0x0E3442FF",
        colorLine:        "0x1D4551FF",
        colorFocus:       "0xD5401AFF",
        colorFocusBright: "0xFF5A2BFF",
        ' Text drawn ON the accent colour. From the brandbook's .btn.primary and
        ' .toggle[aria-selected]; white on colorFocus #D5401A is 4.59:1.
        colorOnAccent:    "0xFFFFFFFF",
        colorText:        "0xDCE9EEFF",
        colorTextDim:     "0x86A6B1FF",
        colorError:       "0xFBA60BFF",
        colorInfo:        "0x60BBD2FF",
        spacingUnit:      12,
        focusScale:       1.05
    }
end function

' Centre a Keyboard on the 1920-wide screen at row y. Used by Settings and the
' onboarding screen: a hardcoded x put the right edge past 1920.
' boundingRect() can report a zero width before the node has been laid out, so callers
' run this once in init AND again when the keyboard is shown; with no usable width it
' falls back to x=274.
sub CenterKeyboard(kb as object, y as integer)
    if kb = invalid then return
    x = 274
    r = kb.boundingRect()
    if r <> invalid
        if r.width > 0
            x = Int((1920 - r.width) / 2)
            if x < 0 then x = 0
        end if
    end if
    kb.translation = [x, y]
end sub
