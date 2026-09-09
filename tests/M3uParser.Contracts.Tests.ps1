# NOTE: a SOURCE LINTER, not a behavioural test -- it regex-matches the text of
# M3uParser.brs. The parsing rule itself is verified by tools/check_m3u_names.py,
# which ports the algorithm and runs it over both real playlists. Neither proves the
# BrightScript runs; only a sideload does. See AUDIT-2026-09-09.md A6.

$projectRoot = Split-Path -Parent $PSScriptRoot
$parserPath = Join-Path $projectRoot 'source\M3uParser.brs'

Describe 'M3U name-splitting contract' {
    It 'splits the EXTINF line on the first UNQUOTED comma' {
        # Splitting on the first comma named 98 of 467 Sport2 channels after a
        # fragment of the http-user-agent attribute, whose value contains
        # "(KHTML, like Gecko)".
        $parser = Get-Content -Raw $parserPath

        $parser | Should Match 'commaPos = FirstUnquotedComma\(line\)'
        $parser | Should Not Match 'commaPos = line\.Instr\(","\)'
        $parser | Should Match 'function FirstUnquotedComma\(line as string\) as integer'
    }

    It 'walks the line by index and never slices it' {
        # Left is byte-based on this device and Mid is not; mixing them splits
        # Cyrillic. The helper must use Instr offsets only.
        $parser = Get-Content -Raw $parserPath
        $body = [regex]::Match($parser,
            '(?s)function FirstUnquotedComma.*?end function').Value

        $body | Should Not BeNullOrEmpty
        $body | Should Not Match '\.Left\('
        $body | Should Not Match '\.Mid\('
        $body | Should Match '\.Instr\(scanAt, chr\(34\)\)'   # NOT `pos`: reserved, see BrightScript.Lint.Tests.ps1
    }
}
