# ============================================================ TUI
$E = [char]27; $SPIN = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'); $b = "$E[1m"
$script:cancelled = $false; $script:ctrlC = $false

# ---------------------------------------------------------------- drawing
$C = @{ accent = '#3dbaba'; text = '#e6e0e9'; dim = '#938f99'; ok = '#a8dab5'; err = '#f2b8b5'; warn = '#ffb77c' }
function Fg([string]$hex) { $h = $hex.TrimStart('#'); "$E[38;2;$([Convert]::ToInt32($h.Substring(0, 2), 16));$([Convert]::ToInt32($h.Substring(2, 2), 16));$([Convert]::ToInt32($h.Substring(4, 2), 16))m" }
$R = "$E[0m"
function Paint([string]$hex, [string]$s) { (Fg $hex) + $s + $R }
function Width { try { [Math]::Max(40, [Math]::Min(76, [Console]::WindowWidth - 4)) } catch { 72 } }

function Wrap([string]$text, [int]$w) {
    $lines = @(); $words = $text -split '\s+'
    $cl = ''; foreach ($word in $words) {
        if ($cl.Length + $word.Length + 1 -le $w) { $cl += $(if ($cl -eq '') { '' } else { ' ' }) + $word }
        else { if ($cl) { $lines += $cl }; $cl = $word }
    }
    if ($cl) { $lines += $cl }; return $lines
}

function Box([string]$color, [string]$title, [string]$body) {
    $w = Width; $in = $w - 4
    Write-Host ("  $b╭" + ('─' * ($w - 2)) + "╮$R")
    if ($title) {
        Write-Host ("  $b│$R " + "$E[1m" + (Fg $color) + $title.PadRight($in) + "$R $b│$R")
        Write-Host ("  $b│$R " + (' ' * $in) + " $b│$R")
    }
    foreach ($l in (Wrap $body $in)) { Write-Host ("  $b│$R " + (Fg $C.text) + $l.PadRight($in) + "$R $b│$R") }
    Write-Host ("  $b╰" + ('─' * ($w - 2)) + "╯$R")
}

function Banner {
    $a = $C.accent
    Write-Host ""
    Write-Host ("  $b" + (Fg $a) + "    ___                        ___  ___  ____ ")
    Write-Host ("  $b" + (Fg $a) + "   / _ | ___ ___  ___  ___    / _ \/ _ \/  _/")
    Write-Host ("  $b" + (Fg $a) + "  / __ |/ -_) _ \/ _ \/ _ \  / // / ___// /  ")
    Write-Host ("  $b" + (Fg $a) + " /_/ |_|\__/_//_/\___/\_,_/ /____/_/  /___/  $R")
    Write-Host ""
}

function Say([string]$text) { Write-Host ('  ' + (Paint $C.accent '>>') + ' ' + (Paint $C.text $text)) }
function Die([string]$text) { Box $C.err "Hata" $text; exit 1 }

function Human([long]$b) {
    if ($b -gt 1GB) { return "$([math]::Round($b / 1GB, 1)) GB" }
    if ($b -gt 1MB) { return "$([math]::Round($b / 1MB, 1)) MB" }
    return "$([math]::Round($b / 1KB, 1)) KB"
}

# ---------------------------------------------------------------- prompts
function Show-Menu([string]$Header, [object[]]$Items, [string]$Selected, [bool]$Multi, [bool]$IsColor) {
    Write-Host -NoNewline "$E[?25l" # hide cursor
    $sel = 0
    if ($Selected) {
        $selectedList = $Selected -split ','
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($IsColor -and $Selected -eq $Items[$i][1]) { $sel = $i }
            elseif (-not $IsColor -and $selectedList -contains $Items[$i][1]) { $sel = $i }
        }
    }
    $drawn = 0
    while ($true) {
        if ($drawn -gt 0) { Write-Host -NoNewline "$E[$($drawn)A" }
        $out = ""
        $out += "  " + (Paint $C.accent $Header) + "`n"
        
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]; $text = $item[0]; $val = $item[1]
            $cur = if ($i -eq $sel) { Paint $C.accent '❯ ' } else { '  ' }
            $prefix = ''
            if ($Multi) {
                $prefix = if ($selectedList -contains $val) { Paint $C.ok '◉ ' } else { Paint $C.dim '○ ' }
            }
            if ($i -eq $sel -and -not $IsColor) { $text = Paint $C.text $text }
            elseif (-not $IsColor) { $text = Paint $C.dim $text }
            
            $out += "  " + $cur + $prefix + $text + "$E[K`n"
        }
        Write-Host -NoNewline $out
        $drawn = $Items.Count + 1

        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'UpArrow') { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
        elseif ($k.Key -eq 'DownArrow') { $sel = ($sel + 1) % $Items.Count }
        elseif ($k.Key -eq 'LeftArrow') { Write-Host -NoNewline "$E[$($drawn)A$E[J"; Write-Host -NoNewline "$E[?25h"; return 'BACK' }
        elseif ($k.Key -eq 'Spacebar' -and $Multi) {
            $val = $Items[$sel][1]
            if ($selectedList -contains $val) { $selectedList = @($selectedList | Where-Object { $_ -ne $val }) }
            else { $selectedList += $val }
        }
        elseif ($k.Key -eq 'Enter') {
            Write-Host -NoNewline "$E[$($drawn)A$E[J"
            Write-Host -NoNewline "$E[?25h"
            if ($Multi) { return $selectedList } else { return $Items[$sel][1] }
        }
        elseif ($k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control)) {
            Write-Host -NoNewline "$E[?25h"; $script:cancelled = $true; throw (New-Object OperationCanceledException)
        }
    }
}

function Choose([string]$header, [object[]]$items, [string]$selected) { return Show-Menu $header $items $selected $false $false }
function Multi([string]$header, [object[]]$items, [string[]]$selected) { return Show-Menu $header $items ($selected -join ',') $true $false }
function Confirm([string]$prompt, [string]$yes, [string]$no, [bool]$default = $true) {
    $ans = Show-Menu $prompt @(@($yes, 'y'), @($no, 'n')) $(if ($default) { 'y' } else { 'n' }) $false $false
    if ($ans -is [string] -and $ans -eq 'BACK') { return 'BACK' }
    return ($ans -eq 'y')
}
function Ask([string]$header, [string]$placeholder, [string]$value) {
    Write-Host ('  ' + (Paint $C.accent $header))
    Write-Host -NoNewline ('  ' + (Paint $C.accent '? '))
    $ans = Read-Host
    if ($ans -eq '') { $ans = $placeholder }
    return $ans.Trim()
}

# ---------------------------------------------------------------- progress
function Bar([double]$f, [int]$w, [int]$tick) {
    $f = [Math]::Max(0.0, [Math]::Min(1.0, $f))
    $c = [int]($f * $w); $rem = ($f * $w) - $c
    $eighths = @(' ', '▏', '▎', '▍', '▌', '▋', '▊', '▉')
    $s = '█' * $c
    if ($c -lt $w) { $s += $eighths[[int]($rem * 8)] + (' ' * ($w - $c - 1)) }
    return (Paint $C.accent $s)
}

function Poll-CtrlC {
    try {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { $script:ctrlC = $true }
        }
    } catch {}
    if ($script:ctrlC) { $script:cancelled = $true; throw (New-Object OperationCanceledException) }
}

function Get-WithBar([string]$url, [string]$out, [string]$label, [long]$total) {
    Write-Host -NoNewline ('  ' + (Paint $C.accent '⠋') + ' ' + $label)
    $start = Get-Date; $wc = New-Object Net.WebClient; $wc.Headers.Add('User-Agent', 'AsenaDPI-Install')
    $task = $wc.DownloadFileTaskAsync($url, $out)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $tick = 0; $lastTick = 0; $have = 0
    try {
        Write-Host -NoNewline "$E[?25l"
        while (-not $task.IsCompleted) {
            Start-Sleep -Milliseconds 90
            Poll-CtrlC
            $tick++
            if ($tick - $lastTick -gt 5) {
                if (Test-Path $out) {
                    try {
                        $done = (Get-Item $out).Length
                        $frac = if ($total -gt 0) { [Math]::Min(1.0, [double]$done / $total) } else { 0 }
                        $speed = if ($sw.Elapsed.TotalSeconds -gt 0.3) { (Human (($done - $have) / $sw.Elapsed.TotalSeconds)) + '/s' } else { '' }
                        $pct = if ($total -gt 0) { '{0,3:0}%' -f ($frac * 100) } else { '' }
                        $info = ((Human $done) + $(if ($total -gt 0) { ' / ' + (Human $total) }) + '  ' + $speed)
                        $bw = 16
                        try { $bw = [Math]::Max(5, [Math]::Min(40, [Console]::WindowWidth - 14 - $label.Length - $pct.Length - $info.Length)) } catch {}
                        Write-Host -NoNewline ("`r  " + (Paint $C.accent $SPIN[$tick % $SPIN.Count]) + ' ' + $label + '  ' + (Bar $frac $bw $tick) + ' ' + (Paint $C.text $pct) + '  ' + (Paint $C.dim $info) + "$E[K")
                    } catch {}
                }
            }
        }
    } finally { Write-Host -NoNewline "$E[?25h" }
    if ($task.IsFaulted) { throw $task.Exception.InnerException }
    Write-Host ("`r  " + (Paint $C.ok '✓') + ' ' + $label + "$E[K")
}

function With-Spinner([string]$label, [scriptblock]$sb) {
    Write-Host -NoNewline ('  ' + (Paint $C.accent '⠋') + ' ' + $label)
    try { 
        $result = & $sb
        Write-Host ("`r  " + (Paint $C.ok '✓') + ' ' + $label + "$E[K")
        return $result 
    }
    catch { 
        Write-Host ("`r  " + (Paint $C.err '✗') + ' ' + $label + "$E[K")
        throw 
    }
}
