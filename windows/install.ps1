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

# --- 0) git ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Say "git yok -> winget ile kuruluyor..."
    Nat "winget" @("install","--id","Git.Git","-e","--accept-package-agreements","--accept-source-agreements") | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "git kurulamadi. Elle kur ve tekrar calistir." }

# --- 0b) python (mutlak yolla bul; PATH'e guvenme) ---
function Find-Python {
    foreach ($n in @("python", "python3")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source -and (Test-Path $c.Source) -and $c.Source -notmatch "WindowsApps") { return $c.Source }
    }
    $pl = Get-Command py -ErrorAction SilentlyContinue
    if ($pl) { $p = (& $pl.Source -c "import sys;print(sys.executable)" 2>$null); if ($p) { return "$p".Trim() } }
    foreach ($g in @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                     "$env:ProgramFiles\Python3*\python.exe", "C:\Python3*\python.exe")) {
        $f = Get-ChildItem $g -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

$pyExe = Find-Python
if (-not $pyExe) {
    Say "Python yok -> winget ile kuruluyor..."
    Nat "winget" @("install","--id","Python.Python.3.12","-e","--accept-package-agreements","--accept-source-agreements") | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
    $pyExe = Find-Python
}
if (-not $pyExe) { Die "Python bulunamadi. Elle kur (python.org, 'Add python to PATH') ve tekrar calistir." }
$pyDir = Split-Path $pyExe
$pyw = Join-Path $pyDir "pythonw.exe"
if (-not (Test-Path $pyw)) { $pyw = $pyExe }
Say "Python: $pyExe"

# --- 0c) PySide6 (exit code ile kontrol; traceback scripti oldurmez) ---
# PySide6 KURULU MU? find_spec ile bak -> Qt DLL'i YUKLEMEZ (Defender taramasi/donma yok, aninda)
$pyChk = "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('PySide6') else 1)"
Say "PySide6 kontrol..."
if ((Nat $pyExe @("-c",$pyChk)) -ne 0) {
    Say "PySide6 indiriliyor (~250 MB - baglantiya gore birkac dakika, ILERLEME asagida)..."
    & $pyExe -m pip install --upgrade pip
    & $pyExe -m pip install PySide6      # ciktiyi GOSTER (kara kutu olmasin)
    if ((Nat $pyExe @("-c",$pyChk)) -ne 0) {
        Say "UYARI: PySide6 kurulamadi (tray acilmaz). Elle: `"$pyExe`" -m pip install PySide6"
    }
} else { Say "PySide6 zaten kurulu." }

# --- 1) zapret-win-bundle indir (winws + WinDivert + blockcheck) ---
$tmp = "$env:TEMP\zapret-win-bundle"
if (Test-Path "$tmp\.git") { Say "bundle guncelleniyor..."; Nat "git" @("-C",$tmp,"pull","--ff-only") | Out-Null }
else { Say "zapret-win-bundle indiriliyor..."; Nat "git" @("clone","--depth","1",$Bundle,$tmp) | Out-Null }

$winws = Get-ChildItem -Path $tmp -Recurse -Filter winws.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $winws) { Die "winws.exe bulunamadi (bundle indirilemedi ya da yapisi degisti): $tmp" }
$winwsDir = $winws.Directory.FullName

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Say "winws + WinDivert -> $InstallDir"
Copy-Item "$winwsDir\*" $InstallDir -Recurse -Force
if (-not (Test-Path "$InstallDir\winws.exe")) { Die "winws.exe kopyalanamadi -> $InstallDir" }

# blockcheck (optimize icin) - bundle'da varsa
$bc = Get-ChildItem -Path $tmp -Recurse -Filter "blockcheck.cmd" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bc) { Copy-Item $bc.Directory.FullName "$InstallDir\blockcheck" -Recurse -Force }

# --- 2) tray + config ---
Say "Tray -> $InstallDir"
Copy-Item "$RepoDir\asena-dpi-tray.pyw" "$InstallDir\asena-dpi-tray.pyw" -Force

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

Say "KURULUM TAMAM. Tray'i simdi baslat:"
Write-Host "   schtasks /run /tn AsenaDPI-Tray" -ForegroundColor Yellow
Write-Host "   (ya da: `"$pyw`" `"$InstallDir\asena-dpi-tray.pyw`")" -ForegroundColor Gray
Write-Host ""
Write-Host "   Tray: SOL tik = ac/kapat  SAG tik = menu (ayarlar, en iyi strateji, guncelle)" -ForegroundColor Gray
