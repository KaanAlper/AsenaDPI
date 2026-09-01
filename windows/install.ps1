# AsenaDPI - Windows kurulum (winws/WinDivert + DoH + tray).
# Yonetici PowerShell'de calistir:
#   Set-ExecutionPolicy -Scope Process Bypass -Force; .\install.ps1
#
# Yaptigi: zapret-win-bundle indir (winws.exe + WinDivert + blockcheck), Program Files'a kur,
# kullanici config'i olustur, tray'i logon'da YONETICI olarak baslatan gorev ekle (UAC'siz),
# Python + PySide6 kontrol.
#Requires -RunAsAdministrator
# NOT: $ErrorActionPreference'i STOP yapMIYORUZ - winget/git/python/pip stderr'e yazinca
# PS 5.1 scripti oldururdu. Kritik adimlari asagida acikca 'Die' ile kontrol ediyoruz.

$Bundle     = "https://github.com/bol-van/zapret-win-bundle"
$InstallDir = "$env:ProgramFiles\AsenaDPI"
$Cfg        = "$env:APPDATA\AsenaDPI"
$RepoDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $RepoDir

function Say($m) { Write-Host ">> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "!! $m" -ForegroundColor Red; exit 1 }
# native komutu calistir, tum ciktiyi (stdout+stderr) yut, exit code don
function Nat { param([string]$File, [string[]]$Args)
    & $File @Args 2>&1 | Out-Null
    return $LASTEXITCODE
}
function Stop-AsenaDPI {
    # calisan tray (pythonw asena-dpi-tray) + winws'i durdur -> WinDivert64.sys kilidi kalmasin
    Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*asena-dpi-tray*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
}

# --- 0) git ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Say "git yok -> winget ile kuruluyor..."
    Nat "winget" @("install","--id","Git.Git","-e","--accept-package-agreements","--accept-source-agreements") | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "git kurulamadi. Elle kur ve tekrar calistir." }

# --- 0b) python (mutlak yolla bul + GERCEKTEN calistigini dogrula) ---
# Store'un 0-byte stub'i ('WindowsApps\python.exe') "gecerli bir uygulama degil" hatasi verir;
# bu yuzden her adayi hem boyut hem de "-c import sys" ile SINA.
function Test-Py {
    param([string]$exe)
    if (-not $exe) { return $false }
    try {
        if (-not (Test-Path $exe)) { return $false }
        if ((Get-Item $exe).Length -lt 20000) { return $false }   # 0-byte Store stub -> ele
        # SADECE CPython: PyPy vb.'de PySide6 wheel'i yok (exit 0 sadece cpython'da)
        & $exe -c "import sys; sys.exit(0 if sys.implementation.name=='cpython' else 3)" 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}
function Find-Python {
    $cands = @()
    foreach ($n in @("python", "python3")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source -and $c.Source -notmatch "WindowsApps") { $cands += $c.Source }
    }
    $pl = Get-Command py -ErrorAction SilentlyContinue
    if ($pl) { $p = (& $pl.Source -c "import sys;print(sys.executable)" 2>$null); if ($p) { $cands += "$p".Trim() } }
    foreach ($g in @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                     "$env:ProgramFiles\Python3*\python.exe", "C:\Python3*\python.exe")) {
        Get-ChildItem $g -ErrorAction SilentlyContinue | ForEach-Object { $cands += $_.FullName }
    }
    foreach ($c in $cands) { if (Test-Py $c) { return $c } }
    return $null
}

$pyExe = Find-Python
if (-not $pyExe) {
    Say "Calisan Python yok -> winget ile kuruluyor..."
    Nat "winget" @("install","--id","Python.Python.3.12","-e","--accept-package-agreements","--accept-source-agreements") | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
    $pyExe = Find-Python
}
if (-not $pyExe) { Die "Calisan Python bulunamadi. python.org'dan kur ('Add python to PATH' isaretli) ve tekrar dene. (Ipucu: Ayarlar > Uygulamalar > Uygulama takma adlari > python.exe KAPAT.)" }
$pyDir = Split-Path $pyExe
$pyw = Join-Path $pyDir "pythonw.exe"
if (-not (Test-Path $pyw)) { $pyw = $pyExe }
Say "Python: $pyExe"

# --- 0c) PySide6 (exit code ile kontrol; traceback scripti oldurmez) ---
# PySide6 - import KONTROLU YOK (Qt DLL yuklemesi Defender ile dakikalarca asili kalabiliyordu).
# Dogrudan pip: kuruluysa "already satisfied" deyip ~2sn'de gecer, degilse kurar. Qt yuklenmez.
Say "PySide6 (pip - kuruluysa aninda gecer, degilse ~250 MB indirir)..."
& $pyExe -m pip install --upgrade pip
$pysideOk = $false
for ($i = 1; $i -le 4 -and -not $pysideOk; $i++) {
    if ($i -gt 1) { Say "PySide6 tekrar deneniyor ($i/4) - baglanti kopmustu..." }
    & $pyExe -m pip install --timeout 120 --retries 8 PySide6
    & $pyExe -m pip show PySide6 2>&1 | Out-Null   # Qt DLL YUKLEMEDEN kurulu mu bak
    $pysideOk = ($LASTEXITCODE -eq 0)
}
# pip dogrudan inmediyse: bu genelde DPI'in PyPI (files.pythonhosted.org) akisini kesmesi
# (hep ayni bytede IncompleteRead). winws'i (DPI-bypass) GECICI calistirip pip'i tekrar dene.
if (-not $pysideOk) {
    $winwsExe = "$InstallDir\zapret-winws\winws.exe"
    if (Test-Path $winwsExe) {
        Say "PySide6 DPI tarafindan kesiliyor gibi -> winws (DPI-bypass) acilip tekrar deneniyor..."
        $wp = Start-Process $winwsExe -WorkingDirectory "$InstallDir\zapret-winws" -WindowStyle Hidden -PassThru `
            -ArgumentList @("--wf-tcp=443","--filter-tcp=443","--dpi-desync=fakedsplit",
                            "--dpi-desync-fooling=md5sig","--dpi-desync-split-pos=1")
        Start-Sleep -Seconds 2
        for ($i = 1; $i -le 3 -and -not $pysideOk; $i++) {
            Say "PySide6 (winws acikken) deneme $i/3..."
            & $pyExe -m pip install --timeout 120 --retries 8 PySide6
            & $pyExe -m pip show PySide6 2>&1 | Out-Null; $pysideOk = ($LASTEXITCODE -eq 0)
        }
        try { Stop-Process -Id $wp.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}
# hala olmadiysa: MIRROR dene (bolgesel PyPI engelini asar - Tsinghua CDN, guvenilir)
if (-not $pysideOk) {
    Say "PySide6 mirror'dan deneniyor (pypi.tuna.tsinghua.edu.cn)..."
    & $pyExe -m pip install --timeout 120 --retries 8 -i https://pypi.tuna.tsinghua.edu.cn/simple PySide6
    & $pyExe -m pip show PySide6 2>&1 | Out-Null; $pysideOk = ($LASTEXITCODE -eq 0)
}
if ($pysideOk) {
    Say "PySide6 hazir."
} else {
    Say "UYARI: PySide6 indirilemedi (DPI/baglanti) -> TRAY ACILMAZ."
    Say "Internet duzelince su komutu dene, sonra tray'i baslat:"
    Write-Host "   & `"$pyExe`" -m pip install PySide6 ; schtasks /run /tn AsenaDPI-Tray" -ForegroundColor Yellow
}

# --- 1) zapret-win-bundle indir (winws + WinDivert + blockcheck + cygwin) ---
# TUM bundle'i kopyala: blockcheck.cmd kardes ..\cygwin ve ..\tools'a baglidir; yapiyi korumazsak
# "sistem belirtilen yolu bulamiyor" der. Yapi: zapret-winws\winws.exe, blockcheck\, cygwin\, tools\
# NOT: git ciktisi GORUNUR (hata gizlenmesin). TEMP bozuksa Windows\Temp'e dus.
$tmp = "$env:TEMP\zapret-win-bundle"
try { New-Item -ItemType Directory -Force -Path (Split-Path $tmp) -ErrorAction Stop | Out-Null }
catch { $tmp = "$env:SystemRoot\Temp\zapret-win-bundle" }

if (Test-Path "$tmp\.git") {
    Say "bundle guncelleniyor..."; & git -C $tmp pull --ff-only
} else {
    Say "zapret-win-bundle indiriliyor (~60 MB, biraz surer)..."
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    & git clone --depth 1 $Bundle $tmp
}
if (-not (Test-Path "$tmp\zapret-winws\winws.exe")) {
    Say "bundle eksik -> temiz yeniden indiriliyor..."
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    & git clone --depth 1 $Bundle $tmp
}
if (-not (Test-Path "$tmp\zapret-winws\winws.exe")) {
    Die "Bundle indirilemedi ($tmp). Yukaridaki git hatasina bak. github.com'a erisim / disk / '$tmp' izni kontrol et."
}

Stop-AsenaDPI   # kopyalamadan ONCE winws+tray durdur (yoksa WinDivert64.sys kilitli -> kopya hatasi)
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Say "Bundle kopyalaniyor -> $InstallDir (zapret-winws + blockcheck + cygwin + tools)..."
Get-ChildItem -Path $tmp -Force | Where-Object { $_.Name -ne ".git" -and $_.Name -ne ".github" } |
    ForEach-Object { Copy-Item $_.FullName $InstallDir -Recurse -Force }
if (-not (Test-Path "$InstallDir\zapret-winws\winws.exe")) { Die "Kopyalama basarisiz -> $InstallDir\zapret-winws" }

# --- 2) tray + config + ikon ---
Say "Tray -> $InstallDir"
Copy-Item "$RepoDir\asena-dpi-tray.pyw" "$InstallDir\asena-dpi-tray.pyw" -Force
$Ico = "$InstallDir\asena-dpi.ico"
if (Test-Path "$RepoDir\asena-dpi.ico") { Copy-Item "$RepoDir\asena-dpi.ico" $Ico -Force }

New-Item -ItemType Directory -Force -Path $Cfg | Out-Null
Set-Content "$Cfg\repo_dir" -Value $RepoRoot -Encoding ascii   # 'Guncelle' bunu kullanir (git pull)
if (-not (Test-Path "$Cfg\blacklist.txt")) { Copy-Item "$RepoRoot\config\blacklist.txt" "$Cfg\blacklist.txt" -Force }
if (-not (Test-Path "$Cfg\settings.conf")) {
@"
# AsenaDPI ayarlari (tray yazar)
MODE=blacklist
HTTP=1
HTTP2=1
HTTP3=bypass
"@ | Set-Content "$Cfg\settings.conf" -Encoding ascii
}
if (-not (Test-Path "$Cfg\tcp443.conf")) {
    "--dpi-desync=fakedsplit --dpi-desync-fooling=md5sig --dpi-desync-split-pos=1" | Set-Content "$Cfg\tcp443.conf" -Encoding ascii
}

# --- 3) tray'i logon'da YONETICI olarak baslatan gorev (UAC'siz) ---
Say "Autostart gorevi (logon, en yuksek yetki)..."
try {
    $act = New-ScheduledTaskAction -Execute $pyw -Argument "`"$InstallDir\asena-dpi-tray.pyw`""
    $trg = New-ScheduledTaskTrigger -AtLogOn
    $prn = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType Interactive
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "AsenaDPI-Tray" -Action $act -Trigger $trg -Principal $prn -Settings $set -Force -ErrorAction Stop | Out-Null
} catch {
    Say "UYARI: autostart gorevi kurulamadi ($($_.Exception.Message)). Tray'i elle baslatabilirsin:"
    Write-Host "   `"$pyw`" `"$InstallDir\asena-dpi-tray.pyw`"" -ForegroundColor Yellow
}

# --- 3b) Baslat menusu + masaustu kisayolu (aranabilir, ikonlu) ---
# Kisayol schtasks /run ile tray'i YONETICI gorevle baslatir (UAC sormaz). Ikon = kurt+DPI.
Say "Kisayollar (Baslat menusu + masaustu)..."
try {
    $ws = New-Object -ComObject WScript.Shell
    $iconRef = $(if (Test-Path $Ico) { "$Ico,0" } else { "$pyw,0" })
    $targets = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\AsenaDPI.lnk",
        "$([Environment]::GetFolderPath('Desktop'))\AsenaDPI.lnk"
    )
    foreach ($lnk in $targets) {
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = "$env:SystemRoot\System32\schtasks.exe"
        $sc.Arguments = "/run /tn AsenaDPI-Tray"
        $sc.IconLocation = $iconRef
        $sc.Description = "AsenaDPI - DPI/DNS bypass"
        $sc.WindowStyle = 7        # minimized -> schtasks konsol parlamasi minimum
        $sc.Save()
    }
} catch {
    Say "UYARI: kisayol olusturulamadi ($($_.Exception.Message))."
}

# --- 4) tray'i SIMDI baslat (sonraki acilista gorev zaten baslatir) ---
Say "Tray baslatiliyor..."
Stop-AsenaDPI   # eski tray kalmadigindan emin ol (cift tray olmasin)
if ((Nat "schtasks" @("/run","/tn","AsenaDPI-Tray")) -ne 0) {
    Start-Process $pyw -ArgumentList "`"$InstallDir\asena-dpi-tray.pyw`""   # gorev yoksa dogrudan
}

Say "KURULUM TAMAM."
Write-Host "   Tray sistem tepsisinde (AsenaDPI ikonu) - SOL tik = ac/kapat, SAG tik = menu" -ForegroundColor Gray
Write-Host "   Sonraki her acilista otomatik baslar (yonetici, UAC'siz)." -ForegroundColor Gray
