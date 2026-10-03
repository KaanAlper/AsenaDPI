# AsenaDPI - one-line installer
#   irm https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/install.ps1 | iex
# Downloads the latest release's setup program with a progress bar, checks its SHA-256 and runs it
# silently (Windows asks for administrator permission once); the setup program adds the Start menu shortcut
# and the entry in Settings > Apps (with its uninstaller).
# Running the same command again updates it. On an error or Ctrl+C everything goes back to how it was.
# No telemetry: the only requests go to api.github.com and the release download. Log: %TEMP%\AsenaDPI-install.log
# Options (set before running):  $env:ASENADPI_UNINSTALL = 1    remove AsenaDPI
#                                 $env:ASENADPI_VERSION = 'x.y.z' install that release instead of the latest
#                                 $env:ASENADPI_SOURCE = <file>   install from a local setup exe (a CI build)
#                                 $env:ASENADPI_LANGUAGE = 'tr' or 'en'
#                                 $env:ASENADPI_DEFAULTS = 1      no questions (default answers)
#                                 $env:ASENADPI_FORCE = 1         reinstall even when this version is already installed
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- what is installed
$App = [ordered]@{
    Name          = 'AsenaDPI'
    Id            = 'AsenaDPI'
    Repo          = 'KaanAlper/AsenaDPI'
    Branch        = 'master'
    Publisher     = 'Kaan Alper'
    Env           = 'ASENADPI'
    Accent        = '#b69df8'
    TaglineEn     = 'One-click DPI and DNS-poisoning bypass (zapret winws + DoH). No VPN, no tunnel.'
    TaglineTr     = 'Tek tuşla DPI ve DNS zehri bypass (zapret winws + DoH). VPN yok, tünel yok.'
    Mode          = 'setup'
    Asset         = '^AsenaDPI-Setup\.exe$'
    Exe           = 'AsenaDPI.exe'
    Shortcut      = $false
    Path          = $false
    Command       = ''
    Autostart     = 'no'
    AutostartArgs = ''
    Data          = @()
    Legacy        = @()
    Launch        = $false
    KeyName       = '{9470A0DB-A82D-4627-B054-40BC61F0DBF3}_is1'
    SetupArgs     = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
    UninstallArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    Admin         = $true
    DefaultDir    = "$env:ProgramFiles\AsenaDPI"
}
function Opt([string]$name) { [Environment]::GetEnvironmentVariable("$($App.Env)_$name") }
$Dir = Join-Path $env:LOCALAPPDATA ('Programs\' + $App.Id)
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $App.Id
$StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) ($App.Name + '.lnk')
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$LogFile = Join-Path $env:TEMP ($App.Id + '-install.log')
$ESC = [char]27

# ---------------------------------------------------------------- texts (Turkish / English)
function Get-Texts([bool]$tr) {
if ($tr) { @{
    tagline = $App.TaglineTr
    qLang = 'Kurulum dili / Installer language'
    looking = 'Son sürüm aranıyor'; noRelease = 'Bu bilgisayar için indirilebilir bir sürüm henüz yayımlanmamış.'
    welcomeNew = '{0} kurulacak'; welcomeUpd = '{0} güncellenecek'
    body = "Sürüm: {0}`nİndirme: {1}`nKonum: {2}"
    bodyUser = 'Yönetici izni gerekmez. Bir şey ters giderse ya da vazgeçersen her şey eski haline döner.'
    bodyAdmin = 'Kurulum programı Windows''tan bir kez yönetici izni isteyecek. Yarıda kalan bir kurulumu kendisi geri alır.'
    current = 'Kurulu sürüm: {0}'
    qGo = 'Devam edelim mi?'; go = 'Kur'; goUpd = 'Güncelle'; cancel = 'Vazgeç'
    upToDate = '{0} {1} zaten kurulu ve güncel.'; qReinstall = 'Yine de yeniden kurulsun mu?'; reinstall = 'Yeniden kur'; keep = 'Böyle kalsın'
    downloading = 'İndiriliyor'; verifying = 'Paket doğrulanıyor'; extracting = 'Paket açılıyor'; closing = 'Açık {0} kapatılıyor'
    placing = 'Dosyalar yerleştiriliyor'; registering = 'Başlat menüsü ve Uygulamalar kaydı'
    running = 'Kurulum programı çalışıyor'; uac = "Windows'un izin penceresini onayla"
    qAutostart = 'Windows açılınca {0} kendiliğinden başlasın mı?'; yes = 'Evet'; no = 'Hayır'
    qStart = '{0} şimdi açılsın mı?'
    doneNew = 'Hazır! {0} {1} kuruldu'; doneUpd = 'Hazır! {0} {1} sürümüne güncellendi'
    doneBody = "Başlat menüsünde: {0}`nGüncellemek için aynı komutu yeniden çalıştır.`nKaldırmak için: Ayarlar > Uygulamalar > {0}"
    doneCli = "Yeni bir terminal aç ve '{1}' yaz.`nGüncellemek için aynı komutu yeniden çalıştır.`nKaldırmak için: Ayarlar > Uygulamalar > {0}"
    other = "Bu bilgisayarda {0} başka bir yolla da kurulmuş ({1}). İki kopya karışmasın diye onu Ayarlar > Uygulamalar'dan kaldırabilirsin."
    errTitle = 'Olmadı, ama merak etme'
    errBody = "Kurulum '{0}' adımında takıldı. Bilgisayarında hiçbir şey yarım kalmadı: yapılan değişiklikler geri alındı."
    errDetail = 'Ayrıntı'; errLog = 'Günlük'
    errRetry = "Aynı komutu yeniden çalıştırarak tekrar deneyebilirsin. Sorun sürerse günlüğü paylaş:`nhttps://github.com/$($App.Repo)/issues"
    netTitle = 'GitHub''a ulaşamadık'; netBody = 'Bağlantını kontrol edip aynı komutu yeniden çalıştır. Bilgisayarında hiçbir şey değişmedi.'
    cancelTitle = 'Kurulumdan vazgeçildi'; cancelBody = 'Her şey eski haline döndü, bilgisayarında hiçbir şey değişmedi.'
    uacTitle = 'İzin verilmedi'; uacBody = 'Yönetici izni olmadan kurulum yapılamıyor. Hiçbir şey değişmedi; hazır olduğunda aynı komutu yeniden çalıştır.'
    badPkg = 'İndirilen paket bozuk görünüyor (SHA-256 tutmadı).'; noExe = 'Pakette {0} bulunamadı.'; setupCode = 'Kurulum programı {0} koduyla bitti.'
    retrying = 'bağlantı koptu, {0} sn sonra kaldığı yerden devam ({1}/5)'
    plainPick = 'Numara yaz ve Enter''a bas'
    unTitle = '{0} kaldırılsın mı?'; unGo = 'Kaldır'; notInstalled = '{0} bu bilgisayarda kurulu değil.'; removed = '{0} kaldırıldı.'
} } else { @{
    tagline = $App.TaglineEn
    qLang = 'Installer language / Kurulum dili'
    looking = 'Looking for the latest release'; noRelease = 'No downloadable release for this computer has been published yet.'
    welcomeNew = 'Installing {0}'; welcomeUpd = 'Updating {0}'
    body = "Version: {0}`nDownload: {1}`nLocation: {2}"
    bodyUser = 'No administrator permission needed. If something goes wrong or you cancel, everything goes back to how it was.'
    bodyAdmin = 'The setup program asks Windows for administrator permission once. It undoes an install that does not finish by itself.'
    current = 'Installed version: {0}'
    qGo = 'Go ahead?'; go = 'Install'; goUpd = 'Update'; cancel = 'Cancel'
    upToDate = '{0} {1} is already installed and up to date.'; qReinstall = 'Reinstall it anyway?'; reinstall = 'Reinstall'; keep = 'Leave it'
    downloading = 'Downloading'; verifying = 'Verifying the package'; extracting = 'Unpacking'; closing = 'Closing the running {0}'
    placing = 'Putting the files in place'; registering = 'Start menu and Apps entry'
    running = 'Running the setup program'; uac = "Approve Windows' permission prompt"
    qAutostart = 'Start {0} automatically when Windows starts?'; yes = 'Yes'; no = 'No'
    qStart = 'Open {0} now?'
    doneNew = 'All set! {0} {1} is installed'; doneUpd = 'All set! {0} is updated to {1}'
    doneBody = "In the Start menu: {0}`nTo update, run the same command again.`nTo remove it: Settings > Apps > {0}"
    doneCli = "Open a new terminal and type '{1}'.`nTo update, run the same command again.`nTo remove it: Settings > Apps > {0}"
    other = '{0} is also installed another way on this computer ({1}). To keep the two copies apart you can remove that one in Settings > Apps.'
    errTitle = "That didn't work, but don't worry"
    errBody = "The install got stuck at '{0}'. Nothing was left half-done: the changes were undone."
    errDetail = 'Details'; errLog = 'Log'
    errRetry = "You can try again by running the same command. If it keeps happening, please share the log:`nhttps://github.com/$($App.Repo)/issues"
    netTitle = "We couldn't reach GitHub"; netBody = 'Check your connection and run the same command again. Nothing on your computer was changed.'
    cancelTitle = 'Install cancelled'; cancelBody = 'Everything is back to how it was; nothing on your computer was changed.'
    uacTitle = 'Permission was not given'; uacBody = 'The install needs administrator permission. Nothing was changed; run the same command again when you are ready.'
    badPkg = 'The downloaded package looks damaged (the SHA-256 does not match).'; noExe = '{0} is missing from the package.'; setupCode = 'The setup program ended with code {0}.'
    retrying = 'connection dropped, resuming in {0} s ({1}/5)'
    plainPick = 'Type a number and press Enter'
    unTitle = 'Remove {0}?'; unGo = 'Remove'; notInstalled = '{0} is not installed on this computer.'; removed = '{0} was removed.'
} }
}
$tr = (Get-UICulture).Name -like 'tr*'
if ((Opt 'LANGUAGE') -in 'tr', 'en') { $tr = (Opt 'LANGUAGE') -eq 'tr' }
$T = Get-Texts $tr

# ---------------------------------------------------------------- drawing
$COL = @{ accent = $App.Accent; text = '#e6e0e9'; dim = '#938f99'; ok = '#a8dab5'; err = '#f2b8b5'; warn = '#ffb77c' }
function Fg([string]$hex) { $h = $hex.TrimStart('#'); "$ESC[38;2;$([Convert]::ToInt32($h.Substring(0, 2), 16));$([Convert]::ToInt32($h.Substring(2, 2), 16));$([Convert]::ToInt32($h.Substring(4, 2), 16))m" }
$RESET = "$ESC[0m"
# The classic console draws only what its font has (WGL4); modern terminals fill in the rest
$GL = if ($env:WT_SESSION -or $env:TERM_PROGRAM) {
    @{ ok = '✓'; fail = '✗'; cursor = '❯'; wait = '◌'; fill = '━'; tl = '╭'; tr = '╮'; bl = '╰'; br = '╯'; spin = '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
} else {
    @{ ok = '√'; fail = 'x'; cursor = '►'; wait = '○'; fill = '─'; tl = '┌'; tr = '┐'; bl = '└'; br = '┘'; spin = '|', '/', '-', '\' }
}
function Paint([string]$hex, [string]$s) { (Fg $hex) + $s + $RESET }
function Width { try { [Math]::Max(40, [Math]::Min(76, [Console]::WindowWidth - 4)) } catch { 72 } }
function Wrap([string]$text, [int]$w) {
    $out = New-Object Collections.Generic.List[string]
    foreach ($para in (($text -replace "`r", '').TrimEnd() -split "`n")) {
        if ($para.Length -le $w) { $out.Add($para); continue }
        $line = ''
        $words = foreach ($wd in ($para -split ' ')) { for ($k = 0; $k -lt [Math]::Max(1, $wd.Length); $k += $w) { $wd.Substring($k, [Math]::Min($w, [Math]::Max(0, $wd.Length - $k))) } }
        foreach ($word in $words) {
            if ($line.Length -eq 0) { $line = $word }
            elseif (($line.Length + 1 + $word.Length) -le $w) { $line += ' ' + $word }
            else { $out.Add($line); $line = $word }
        }
        $out.Add($line)
    }
    return $out
}
function Box([string]$color, [string]$title, [string]$body) {
    $w = Width; $in = $w - 4; $b = Fg $color
    Write-Host ''
    Write-Host ("  $b$($GL.tl)" + ('─' * ($w - 2)) + "$($GL.tr)$RESET")
    if ($title) {
        Write-Host ("  $b│$RESET " + "$ESC[1m" + (Fg $color) + $title.PadRight($in) + "$RESET $b│$RESET")
        Write-Host ("  $b│$RESET " + (' ' * $in) + " $b│$RESET")
    }
    foreach ($l in (Wrap $body $in)) { Write-Host ("  $b│$RESET " + (Fg $COL.text) + $l.PadRight($in) + "$RESET $b│$RESET") }
    Write-Host ("  $b$($GL.bl)" + ('─' * ($w - 2)) + "$($GL.br)$RESET")
}
function Banner {
    Write-Host ''
    Write-Host ('  ' + "$ESC[1m" + (Paint $COL.accent $App.Name))
    Write-Host ('  ' + (Paint $COL.dim $T.tagline))
}
function Say([string]$sym, [string]$color, [string]$text) { Write-Host ('  ' + (Paint $color $sym) + ' ' + (Paint $COL.text $text)) }
function Human([double]$b) { if ($b -ge 1MB) { '{0:0.0} MB' -f ($b / 1MB) } else { '{0:0} KB' -f ($b / 1KB) } }
function Bar([double]$frac, [int]$width, [int]$tick) {
    $fill = [int][Math]::Floor($frac * $width); $s = ''
    for ($i = 0; $i -lt $width; $i++) {
        if ($i -lt $fill) { $s += $(if ((($i - $tick) % 24 + 24) % 24 -lt 3) { (Fg '#f0eaff') } else { (Fg $COL.accent) }) + $GL.fill }
        elseif ($i -eq $fill) { $s += (Fg $COL.accent) + '╸' }
        else { $s += (Fg '#49454f') + '─' }
    }
    return $s + $RESET
}
function Log([string]$m) { try { Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss ') + $m) -Encoding UTF8 } catch {} }

# ---------------------------------------------------------------- input
$interactive = (-not (Opt 'DEFAULTS')) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
# Arrow keys + Enter (numbers in a plain console); returns the value of the picked item
function Choose([string]$header, [object[]]$items, [string]$default) {
    if (-not $interactive) { return $default }
    $sel = [Math]::Max(0, [Array]::IndexOf(@($items | ForEach-Object { $_[1] }), $default))
    $raw = $true
    try { [void][Console]::KeyAvailable; [Console]::CursorVisible = $false } catch { $raw = $false }
    if (-not $raw) {
        Write-Host "  $header"
        for ($i = 0; $i -lt $items.Count; $i++) { Write-Host "  $($i + 1). $($items[$i][0])" }
        while ($true) {
            $a = (Read-Host "  $($T.plainPick) [$($sel + 1)]").Trim()
            if (-not $a) { return $items[$sel][1] }
            $n = 0
            if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { return $items[$n - 1][1] }
        }
    }
    Write-Host ''
    Write-Host ('  ' + (Paint $COL.accent '?') + ' ' + "$ESC[1m" + (Paint $COL.text $header))
    $first = $true
    try {
        while ($true) {
            if (-not $first) { Write-Host -NoNewline "$ESC[$($items.Count)A" }
            $first = $false
            for ($i = 0; $i -lt $items.Count; $i++) {
                $line = if ($i -eq $sel) { '  ' + (Paint $COL.accent ($GL.cursor + ' ' + $items[$i][0])) } else { '    ' + (Paint $COL.dim $items[$i][0]) }
                Write-Host ("`r" + $line + "$ESC[K")
            }
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow' { $sel = ($sel - 1 + $items.Count) % $items.Count }
                'DownArrow' { $sel = ($sel + 1) % $items.Count }
                'Enter' { return $items[$sel][1] }
                'Escape' { throw (New-Object OperationCanceledException) }
                default {
                    $n = 0
                    if ([int]::TryParse([string]$k.KeyChar, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { $sel = $n - 1 }
                }
            }
        }
    }
    finally { try { [Console]::CursorVisible = $true } catch {} }
}
function Confirm([string]$q, [string]$yes, [string]$no, [bool]$default = $true) {
    (Choose $q @(@($yes, 'y'), @($no, 'n')) $(if ($default) { 'y' } else { 'n' })) -eq 'y'
}

# ---------------------------------------------------------------- download with a progress bar
function Get-WithBar([string]$url, [string]$dst, [string]$label, [long]$sizeHint) {
    # a dropped connection continues where it stopped (HTTP Range) instead of starting over
    $tick = 0; $last = ''
    for ($try = 1; $try -le 5; $try++) {
        try {
            $have = if (Test-Path -LiteralPath $dst) { (Get-Item -LiteralPath $dst).Length } else { 0 }
            $req = [Net.HttpWebRequest]::Create($url)
            $req.UserAgent = "$($App.Id)-install"; $req.Timeout = 30000; $req.ReadWriteTimeout = 60000
            if ($have -gt 0) { $req.AddRange([long]$have) }
            $res = $req.GetResponse()
            try {
                if ([int]$res.StatusCode -ne 206) { $have = 0 }
                $total = if ($res.ContentLength -gt 0) { $have + $res.ContentLength } else { $sizeHint }
                $in = $res.GetResponseStream()
                $out = if ($have -gt 0) { New-Object IO.FileStream($dst, [IO.FileMode]::Append) } else { [IO.File]::Create($dst) }
                try {
                    $buf = New-Object byte[] 131072; $done = $have
                    $sw = [Diagnostics.Stopwatch]::StartNew(); $draw = [Diagnostics.Stopwatch]::StartNew()
                    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $n); $done += $n
                        if ($draw.ElapsedMilliseconds -ge 60) {
                            $draw.Restart(); $tick++
                            $frac = if ($total -gt 0) { [Math]::Min(1.0, [double]$done / $total) } else { 0 }
                            $speed = if ($sw.Elapsed.TotalSeconds -gt 0.3) { (Human (($done - $have) / $sw.Elapsed.TotalSeconds)) + '/s' } else { '' }
                            $pct = if ($total -gt 0) { '{0,3:0}%' -f ($frac * 100) } else { '' }
                            $info = (Human $done) + $(if ($total -gt 0) { ' / ' + (Human $total) }) + '  ' + $speed
                            $bw = 16
                            try { $bw = [Math]::Max(5, [Math]::Min(40, [Console]::WindowWidth - 14 - $label.Length - $pct.Length - $info.Length)) } catch {}
                            Write-Host -NoNewline ("`r  " + (Paint $COL.accent $GL.spin[$tick % $GL.spin.Count]) + ' ' + $label + '  ' + (Bar $frac $bw $tick) + ' ' + (Paint $COL.text $pct) + '  ' + (Paint $COL.dim $info) + "$ESC[K")
                        }
                    }
                }
                finally { $out.Dispose(); $in.Dispose() }
            }
            finally { $res.Dispose() }
            if ($total -gt 0 -and $done -lt $total) { throw "the connection closed at $(Human $done) of $(Human $total)" }
            Write-Host ("`r  " + (Paint $COL.ok $GL.ok) + ' ' + $label + '  ' + (Paint $COL.dim (Human (Get-Item -LiteralPath $dst).Length)) + "$ESC[K")
            return
        }
        catch [OperationCanceledException] { throw }
        catch {
            $last = $_.Exception.Message
            Log "download try ${try}: $last"
            for ($ex = $_.Exception; $ex; $ex = $ex.InnerException) {
                # 416: what is on disk does not fit the file on the server; start over
                if ($ex -is [Net.WebException] -and $ex.Response -and [int]$ex.Response.StatusCode -eq 416) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
                # 404 / 403: the file is not there; asking again does not help
                if ($ex -is [Net.WebException] -and $ex.Response -and [int]$ex.Response.StatusCode -in 403, 404, 410) { $try = 5 }
            }
            if ($try -eq 5) { break }
            for ($w = 2 * $try; $w -gt 0; $w--) {
                Write-Host -NoNewline ("`r  " + (Paint $COL.warn '↻') + ' ' + $label + '  ' + (Paint $COL.dim ($T.retrying -f $w, ($try + 1))) + "$ESC[K")
                Start-Sleep -Seconds 1
            }
        }
    }
    throw $last
}
# "◌ label" while it runs, then ✓ / ✗ in place
function Step([string]$label, [scriptblock]$sb) {
    $state.stage = $label
    Log "step: $label"
    Write-Host -NoNewline ('  ' + (Paint $COL.accent $GL.wait) + ' ' + $label)
    try { $result = & $sb; Write-Host ("`r  " + (Paint $COL.ok $GL.ok) + ' ' + $label + "$ESC[K"); return $result }
    catch { Write-Host ("`r  " + (Paint $COL.err $GL.fail) + ' ' + $label + "$ESC[K"); throw }
}

# ---------------------------------------------------------------- the uninstaller (also written next to the program)
$UninstallTemplate = @'
# Removes @@NAME@@ for this user (written by install.ps1; Settings > Apps runs it).
#   -Quiet  no questions    -Purge  also delete the settings
param([switch]$Quiet, [switch]$Purge)
$ErrorActionPreference = 'Stop'
$Id = '@@ID@@'; $Name = '@@NAME@@'
$Dir = Join-Path $env:LOCALAPPDATA ('Programs\' + $Id)
$Data = @(@@DATA@@)
# files an older installer put elsewhere
$Legacy = @(@@LEGACY@@)
$tr = (Get-UICulture).Name -like 'tr*'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
$ask = (-not $Quiet) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
if ($ask) {
    $q = if ($tr) { "$Name kaldırılsın mı? [E/h]" } else { "Remove ${Name}? [Y/n]" }
    if ((Read-Host $q).Trim() -match '^(h|n|hayir|hayır|no)$') { return }
}
# the program, then everything that points at it
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Dir + '\', [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { try { $_.Kill(); [void]$_.WaitForExit(5000) } catch {} }
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) "$Name.lnk") -Force -ErrorAction SilentlyContinue
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$v = (Get-ItemProperty -LiteralPath $run -ErrorAction SilentlyContinue).$Id
if ($v -and $v -like "*$Dir*") { Remove-ItemProperty -LiteralPath $run -Name $Id -ErrorAction SilentlyContinue }
$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($path) {
    $parts = @($path -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $Dir })
    $new = $parts -join ';'
    if ($new -ne $path) { [Environment]::SetEnvironmentVariable('Path', $new, 'User') }
}
foreach ($l in $Legacy) { Remove-Item -LiteralPath $l -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$Id" -Recurse -Force -ErrorAction SilentlyContinue
if (-not $Purge -and $ask) {
    $have = @($Data | Where-Object { Test-Path -LiteralPath $_ })
    if ($have.Count) {
        $q = if ($tr) { "Ayarlar ve veriler de silinsin mi? ($($have -join ', ')) [e/H]" } else { "Delete its settings and data too? ($($have -join ', ')) [y/N]" }
        $Purge = (Read-Host $q).Trim() -match '^(e|y|evet|yes)$'
    }
}
if ($Purge) { foreach ($d in $Data) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
# the folder holds this script: leave it first; a file Windows still holds is removed a moment later
Set-Location -LiteralPath $env:TEMP
try { Remove-Item -LiteralPath $Dir -Recurse -Force }
catch { Start-Process cmd.exe -ArgumentList "/c timeout /t 3 /nobreak >nul & rd /s /q `"$Dir`"" -WindowStyle Hidden }
if ($ask) { Write-Host $(if ($tr) { "$Name kaldırıldı." } else { "$Name was removed." }) }
'@
function Get-UninstallScript {
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $UninstallTemplate.Replace('@@ID@@', ($App.Id -replace "'", "''")).Replace('@@NAME@@', ($App.Name -replace "'", "''")).
        Replace('@@DATA@@', (@($App.Data | Where-Object { $_ } | ForEach-Object { & $q $_ }) -join ', ')).
        Replace('@@LEGACY@@', (@($App.Legacy | Where-Object { $_ } | ForEach-Object { & $q $_ }) -join ', '))
}

# ---------------------------------------------------------------- release lookup
function Get-Release {
    $want = Opt 'VERSION'
    $hdr = @{ 'User-Agent' = "$($App.Id)-install"; Accept = 'application/vnd.github+json' }
    $list = Invoke-RestMethod -Uri "https://api.github.com/repos/$($App.Repo)/releases?per_page=40" -Headers $hdr -TimeoutSec 30
    foreach ($rel in @($list)) {
        if ($rel.draft) { continue }
        if ($want) { if ($rel.tag_name -ne "v$want") { continue } }
        elseif ($rel.prerelease) { continue }
        $file = @($rel.assets | Where-Object { $_.name -match $App.Asset }) | Select-Object -First 1
        if (-not $file) { continue }
        $sha = @($rel.assets | Where-Object { $_.name -eq ($file.name + '.sha256') }) | Select-Object -First 1
        return [pscustomobject]@{ Version = ($rel.tag_name -replace '^v', ''); Url = $file.browser_download_url; Name = $file.name; Size = [long]$file.size; Sha = $(if ($sha) { $sha.browser_download_url }) }
    }
    return $null
}
# zip mode: our own Apps entry; setup mode: the entry the setup program writes (machine or user)
function Get-SetupEntry {
    $roots = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($root in $roots) {
        $p = Get-ItemProperty -LiteralPath (Join-Path $root $App.KeyName) -ErrorAction SilentlyContinue
        if ($p) { return $p }
    }
    return $null
}
function Get-Installed {
    if ($App.Mode -eq 'setup') { $e = Get-SetupEntry; if ($e) { return $e.DisplayVersion }; return $null }
    try { (Get-ItemProperty -LiteralPath $UninstallKey -ErrorAction Stop).DisplayVersion } catch { $null }
}
function Get-InstallDir {
    if ($App.Mode -ne 'setup') { return $Dir }
    $e = Get-SetupEntry
    if (-not $e) { return $null }
    # some setup programs (Tauri's) store it in quotes
    if ($e.InstallLocation) { return $e.InstallLocation.Trim('"').TrimEnd('\') }
    if ($e.DisplayIcon) { return (Split-Path (($e.DisplayIcon -split ',')[0].Trim('"'))) }
    return $null
}
function Get-Running([string]$where) {
    if (-not $where) { return @() }
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($where.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
}
function Stop-Running([string]$where) {
    foreach ($p in Get-Running $where) { try { [void]$p.CloseMainWindow() } catch {} }
    Start-Sleep -Milliseconds 1500
    foreach ($p in Get-Running $where) { try { $p.Kill(); [void]$p.WaitForExit(5000) } catch {} }
}
# the same program installed another way (a setup exe, a portable copy registered elsewhere)
function Find-OtherInstall {
    $mine = if ($App.Mode -eq 'setup') { $App.KeyName } else { $App.Id }
    $roots = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and $_.PSChildName -ne $mine -and $p.DisplayName -and ($p.DisplayName -eq $App.Name -or $p.DisplayName -like "$($App.Name) *")) {
                $(if ($p.InstallLocation) { $p.InstallLocation } else { $p.DisplayName })
            }
        }
    }
}
function New-Shortcut([string]$lnk, [string]$target, [string]$workdir) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = $target; $s.WorkingDirectory = $workdir; $s.IconLocation = "$target,0"; $s.Description = $App.TaglineEn
    $s.Save()
}
# "C:\path\unins000.exe" /x  ->  exe + arguments
function Split-Command([string]$cmd) {
    $cmd = $cmd.Trim()
    if ($cmd.StartsWith('"')) { $end = $cmd.IndexOf('"', 1); return @($cmd.Substring(1, $end - 1), $cmd.Substring($end + 1).Trim()) }
    $m = [regex]::Match($cmd, '^(.+?\.exe)\s*(.*)$', 'IgnoreCase')
    if ($m.Success) { return @($m.Groups[1].Value, $m.Groups[2].Value) }
    return @($cmd, '')
}
# a setup or uninstall program; $true when it finished well, $false when Windows' permission was declined
function Invoke-Program([string]$exe, [string]$arguments) {
    Log "run: $exe $arguments"
    # not -Wait: Windows PowerShell then also waits for what the program starts (a silent setup starts the app)
    try { $p = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru }
    catch {
        # a declined permission prompt (1223), possibly wrapped by Windows PowerShell 5.1
        for ($x = $_.Exception; $x; $x = $x.InnerException) {
            if ($x -is [ComponentModel.Win32Exception] -and $x.NativeErrorCode -eq 1223) { Log 'permission declined'; return $false }
        }
        throw
    }
    $null = $p.Handle  # keeps the exit code readable after the process ends
    $p.WaitForExit()
    Log "exit $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { throw ($T.setupCode -f $p.ExitCode) }
    return $true
}

# ---------------------------------------------------------------- uninstall
function Invoke-Uninstall {
    if ($App.Mode -eq 'setup') {
        $e = Get-SetupEntry
        if (-not $e) { Say $GL.ok $COL.ok ($T.notInstalled -f $App.Name); return }
        if ($interactive -and -not (Confirm ($T.unTitle -f $App.Name) $T.unGo $T.cancel $true)) { return }
        Stop-Running (Get-InstallDir)
        $cmd = Split-Command $(if ($e.QuietUninstallString) { $e.QuietUninstallString } else { $e.UninstallString })
        $ok = Step ($T.unGo + ' ' + $App.Name) {
            $done = Invoke-Program $cmd[0] (($cmd[1] + ' ' + $App.UninstallArgs).Trim())
            # NSIS and Inno uninstallers hand over to a copy of themselves in %TEMP% and return at once: wait for the Apps entry to go
            for ($w = 0; $done -and $w -lt 120 -and (Get-SetupEntry); $w++) { Start-Sleep -Milliseconds 500 }
            $done
        }
        if (-not $ok) { Box $COL.warn $T.uacTitle $T.uacBody; return }
    }
    else {
        if (-not (Test-Path -LiteralPath $UninstallKey) -and -not (Test-Path -LiteralPath $Dir)) { Say $GL.ok $COL.ok ($T.notInstalled -f $App.Name); return }
        if ($interactive -and -not (Confirm ($T.unTitle -f $App.Name) $T.unGo $T.cancel $true)) { return }
        $uargs = @{ Quiet = $true; Purge = [bool](Opt 'PURGE') }
        & ([scriptblock]::Create((Get-UninstallScript))) @uargs
    }
    Log 'uninstalled'
    Say $GL.ok $COL.ok ($T.removed -f $App.Name)
}

# ---------------------------------------------------------------- zip mode: unpack next to the old copy, swap, register
function Install-Zip($rel, [string]$zip, [bool]$autostart) {
    New-Item -ItemType Directory -Force $parent | Out-Null
    Step $T.extracting {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $stagingDir)
        # a zip with one top folder: its content is the program
        $top = @(Get-ChildItem -LiteralPath $stagingDir -Force)
        if ($top.Count -eq 1 -and $top[0].PSIsContainer -and -not (Test-Path -LiteralPath (Join-Path $stagingDir $App.Exe))) {
            $inner = $top[0].FullName
            Get-ChildItem -LiteralPath $inner -Force | Move-Item -Destination $stagingDir
            Remove-Item -LiteralPath $inner -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $stagingDir $App.Exe))) { throw ($T.noExe -f $App.Exe) }
        [IO.File]::WriteAllText((Join-Path $stagingDir 'uninstall.ps1'), (Get-UninstallScript), (New-Object Text.UTF8Encoding $true))
    }
    $state.wasRunning = @(Get-Running $Dir | ForEach-Object { $_.Path } | Select-Object -Unique)
    if ($state.wasRunning.Count) { Step ($T.closing -f $App.Name) { Stop-Running $Dir } }
    Step $T.placing {
        if (Test-Path -LiteralPath $Dir) {
            Move-Item -LiteralPath $Dir $backupDir
            $undo.Add({ if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }; Move-Item -LiteralPath $backupDir $Dir })
        }
        else { $undo.Add({ if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force } }) }
        Move-Item -LiteralPath $stagingDir $Dir
    }
    $exe = Join-Path $Dir $App.Exe
    Step $T.registering {
        # every value is put back as it was if a later step fails
        $state.hadKey = Test-Path -LiteralPath $UninstallKey
        $state.oldValues = if ($state.hadKey) { Get-ItemProperty -LiteralPath $UninstallKey } else { $null }
        $undo.Add({
            Remove-Item -LiteralPath $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
            if ($state.hadKey) {
                New-Item -Path $UninstallKey -Force | Out-Null
                foreach ($pr in $state.oldValues.PSObject.Properties) { if ($pr.Name -notlike 'PS*') { Set-ItemProperty -LiteralPath $UninstallKey -Name $pr.Name -Value $pr.Value } }
            }
        })
        New-Item -Path $UninstallKey -Force | Out-Null
        $un = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Dir 'uninstall.ps1')`""
        $size = [int]((Get-ChildItem -LiteralPath $Dir -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
        $icon = if ($App.Exe -like '*.exe') { "$exe,0" } else { "$env:SystemRoot\System32\cmd.exe,0" }
        $vals = [ordered]@{ DisplayName = $App.Name; DisplayVersion = $rel.Version; Publisher = $App.Publisher; DisplayIcon = $icon; InstallLocation = $Dir
            InstallDate = (Get-Date -Format 'yyyyMMdd'); URLInfoAbout = "https://github.com/$($App.Repo)"; UninstallString = $un; QuietUninstallString = "$un -Quiet" }
        foreach ($k in $vals.Keys) { Set-ItemProperty -LiteralPath $UninstallKey -Name $k -Value $vals[$k] }
        foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -LiteralPath $UninstallKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
        New-ItemProperty -LiteralPath $UninstallKey -Name 'EstimatedSize' -Value $size -PropertyType DWord -Force | Out-Null

        if ($App.Shortcut) {
            if (-not (Test-Path -LiteralPath $StartMenu)) { $undo.Add({ Remove-Item -LiteralPath $StartMenu -Force -ErrorAction SilentlyContinue }) }
            New-Shortcut $StartMenu $exe $Dir
        }
        if ($App.Path) {
            $state.userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (-not (@($state.userPath -split ';') | Where-Object { $_.TrimEnd('\') -eq $Dir })) {
                $undo.Add({ [Environment]::SetEnvironmentVariable('Path', $state.userPath, 'User') })
                [Environment]::SetEnvironmentVariable('Path', ((@($state.userPath -split ';' | Where-Object { $_ }) + $Dir) -join ';'), 'User')
            }
        }
        if ($App.Autostart -eq 'ask') {
            $state.prevRun = (Get-ItemProperty -LiteralPath $RunKey -ErrorAction SilentlyContinue).($App.Id)
            $undo.Add({
                if ($state.prevRun) { Set-ItemProperty -LiteralPath $RunKey -Name $App.Id -Value $state.prevRun }
                else { Remove-ItemProperty -LiteralPath $RunKey -Name $App.Id -ErrorAction SilentlyContinue }
            })
            if ($autostart) { Set-ItemProperty -LiteralPath $RunKey -Name $App.Id -Value ("`"$exe`"" + $(if ($App.AutostartArgs) { ' ' + $App.AutostartArgs })) }
            else { Remove-ItemProperty -LiteralPath $RunKey -Name $App.Id -ErrorAction SilentlyContinue }
        }
        # files an older installer put elsewhere: kept aside until the end, put back on a failure
        $i = 0
        foreach ($old in @($App.Legacy | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
            $aside = Join-Path $work ('legacy' + $i++)
            Move-Item -LiteralPath $old $aside
            $state.legacy += , @($old, $aside)
        }
        if ($state.legacy.Count) { $undo.Add({ foreach ($l in $state.legacy) { if (Test-Path -LiteralPath $l[1]) { Move-Item -LiteralPath $l[1] $l[0] -Force } } }) }
    }
    return $exe
}

# ---------------------------------------------------------------- setup mode: the release's setup program does the install
function Install-Setup($rel, [string]$file) {
    $where = Get-InstallDir
    $state.wasRunning = @(Get-Running $where | ForEach-Object { $_.Path } | Select-Object -Unique)
    if ($state.wasRunning.Count) { Step ($T.closing -f $App.Name) { Stop-Running $where } }
    $label = if ($App.Admin) { "$($T.running) ($($T.uac))" } else { $T.running }
    $ok = Step $label { Invoke-Program $file $App.SetupArgs }
    if (-not $ok) { $state.declined = $true; throw (New-Object OperationCanceledException) }
    $dir = Get-InstallDir
    if (-not $dir) { return $null }
    return (Join-Path $dir $App.Exe)
}

# ---------------------------------------------------------------- install / update
$work = Join-Path $env:TEMP ($App.Id + '-install-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$parent = Split-Path $Dir -Parent
$stagingDir = Join-Path $parent ('.' + $App.Id + '-new-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
$backupDir = Join-Path $parent ('.' + $App.Id + '-old-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
$undo = New-Object Collections.Generic.List[scriptblock]
# what the steps saw before they changed anything (the undo blocks read it; they run in this scope)
$state = @{ stage = $T.looking; wasRunning = @(); legacy = @() }
$oldOut = [Console]::OutputEncoding
$committed = $false
try {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    Log "---- $($App.Name) installer, PowerShell $($PSVersionTable.PSVersion), $([Environment]::OSVersion.VersionString)"
    if ($interactive -and -not (Opt 'LANGUAGE')) {
        Banner
        $tr = (Choose $T.qLang @(@('English', 'en'), @('Türkçe (Turkish)', 'tr')) $(if ($tr) { 'tr' } else { 'en' })) -eq 'tr'
        $T = Get-Texts $tr
        if (-not [Console]::IsOutputRedirected) { Clear-Host }
    }
    Banner
    if (Opt 'UNINSTALL') { Invoke-Uninstall; $committed = $true; return }

    # ------------------------------------------------------------ which release
    $installed = Get-Installed
    $src = Opt 'SOURCE'
    if ($src) {
        $src = (Resolve-Path -LiteralPath $src).Path
        $m = [regex]::Match([IO.Path]::GetFileName($src), '\d+\.\d+\.\d+')
        $rel = [pscustomobject]@{ Version = $(if ($m.Success) { $m.Value } else { '0.0.0' }); Url = $null; Name = [IO.Path]::GetFileName($src); Size = (Get-Item -LiteralPath $src).Length; Sha = $null }
    }
    else {
        try { $rel = Step $T.looking { Get-Release } }
        catch { Log "release lookup: $($_.Exception.Message)"; Box $COL.err $T.netTitle ($T.netBody + "`n`n$($T.errDetail): $($_.Exception.Message)"); return }
        if (-not $rel) { Box $COL.warn $T.errTitle $T.noRelease; return }
    }
    Log "release $($rel.Version) ($($rel.Name)), installed: $installed"
    if ($installed -and $installed -eq $rel.Version -and -not (Opt 'FORCE') -and -not $src) {
        Say $GL.ok $COL.ok ($T.upToDate -f $App.Name, $installed)
        if (-not ($interactive -and (Confirm $T.qReinstall $T.reinstall $T.keep $false))) { return }
    }
    $update = [bool]$installed
    $title = if ($update) { $T.welcomeUpd -f $App.Name } else { $T.welcomeNew -f $App.Name }
    $where = Get-InstallDir
    $body = ($T.body -f $rel.Version, (Human $rel.Size), $(if ($where) { $where } elseif ($App.Mode -eq 'setup') { $App.DefaultDir } else { $Dir })) + "`n`n" + $(if ($App.Admin) { $T.bodyAdmin } else { $T.bodyUser })
    if ($installed) { $body = ($T.current -f $installed) + "`n" + $body }
    Box $COL.accent $title $body
    foreach ($o in @(Find-OtherInstall | Select-Object -Unique)) { Box $COL.warn '' ($T.other -f $App.Name, $o) }
    if ($interactive -and -not (Confirm $T.qGo $(if ($update) { $T.goUpd } else { $T.go }) $T.cancel $true)) { throw (New-Object OperationCanceledException) }
    $autostart = $false
    if ($App.Mode -ne 'setup' -and $App.Autostart -eq 'ask') {
        $prev = (Get-ItemProperty -LiteralPath $RunKey -ErrorAction SilentlyContinue).($App.Id)
        $autostart = if ($update) { [bool]$prev } else { Confirm ($T.qAutostart -f $App.Name) $T.yes $T.no $false }
    }
    Write-Host ''

    # ------------------------------------------------------------ download and verify
    New-Item -ItemType Directory -Force $work | Out-Null
    $file = Join-Path $work $rel.Name
    if ($src) { Copy-Item -LiteralPath $src $file }
    else {
        $state.stage = $T.downloading
        Get-WithBar $rel.Url $file "$($T.downloading) $($App.Name) $($rel.Version)" $rel.Size
        if ($rel.Sha) {
            Step $T.verifying {
                $want = ([string](Invoke-RestMethod -Uri $rel.Sha -Headers @{ 'User-Agent' = "$($App.Id)-install" } -TimeoutSec 30) -split '\s+' | Where-Object { $_ })[0].ToLower()
                $got = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
                Log "sha256 want $want got $got"
                if ($want -ne $got) { throw $T.badPkg }
            }
        }
    }

    $exe = if ($App.Mode -eq 'setup') { Install-Setup $rel $file } else { Install-Zip $rel $file $autostart }
    # the version the setup program actually registered (a local setup exe has none in its name)
    if ($App.Mode -eq 'setup') { $v = Get-Installed; if ($v) { $rel.Version = $v } }
    $committed = $true
    Log "installed $($rel.Version)"
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue }

    $done = if ($update) { $T.doneUpd -f $App.Name, $rel.Version } else { $T.doneNew -f $App.Name, $rel.Version }
    Box $COL.ok $done $(if ($App.Command) { $T.doneCli -f $App.Name, $App.Command } else { $T.doneBody -f $App.Name })
    # what was running before the update runs again; a new install asks
    if ($App.Launch -and $exe -and (Test-Path -LiteralPath $exe)) {
        if ($state.wasRunning.Count) { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) }
        elseif (-not $update -and $interactive -and (Confirm ($T.qStart -f $App.Name) $T.yes $T.no $true)) { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) }
    }
}
catch [OperationCanceledException] {
    Log $(if ($state.declined) { 'permission declined' } else { 'cancelled' })
    Write-Host ''
    if ($state.declined) { Box $COL.warn $T.uacTitle $T.uacBody } else { Box $COL.warn $T.cancelTitle $T.cancelBody }
}
catch {
    Log "error at '$($state.stage)': $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    Write-Host ''
    Box $COL.err $T.errTitle (($T.errBody -f $state.stage) + "`n`n$($T.errDetail): $($_.Exception.Message)`n$($T.errLog): $LogFile`n`n" + $T.errRetry)
}
finally {
    # Ctrl+C lands here too: undo in reverse order, then start what was running before
    if (-not $committed) {
        for ($i = $undo.Count - 1; $i -ge 0; $i--) { try { & $undo[$i] } catch { Log "undo: $($_.Exception.Message)" } }
        if ($undo.Count) { Log 'rolled back' }
        foreach ($p in $state.wasRunning) { if (Test-Path -LiteralPath $p) { try { Start-Process -FilePath $p -WorkingDirectory (Split-Path $p) } catch {} } }
    }
    if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    try { [Console]::OutputEncoding = $oldOut } catch {}
    Write-Host -NoNewline $RESET
    Write-Host ''
}
}
