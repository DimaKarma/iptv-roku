function getTheme()
    return {
        colorBg:          "0x0E1310FF",
        colorSurface:     "0x18211CFF",
        colorSurfaceHi:   "0x212C26FF",
        colorLine:        "0x2A362FFF",
        colorFocus:       "0x4FB03AFF",
        colorFocusBright: "0x74D45BFF",
        ' Text drawn ON the accent colour. From the brandbook's .btn.primary and
        ' .toggle[aria-selected]; 6.86:1 on colorFocus, against 2.43:1 for colorText.
        colorOnAccent:    "0x08130AFF",
        colorText:        "0xECF2EEFF",
        colorTextDim:     "0x8A968EFF",
        colorError:       "0xD9584FFF",
        spacingUnit:      12,
        focusScale:       1.05
    }
end function
