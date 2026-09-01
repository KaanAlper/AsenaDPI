# AsenaDPI — Windows kurulum (winws/WinDivert + DoH + tray).
# Yonetici PowerShell'de calistir:
#   Set-ExecutionPolicy -Scope Process Bypass -Force; .\install.ps1
#
# Yaptigi: zapret-win-bundle indir (winws.exe + WinDivert + blockcheck), Program Files'a kur,
# kullanici config'i olustur, tray'i logon'da YONETICI olarak baslatan gorev ekle (UAC'siz),
# Python + PySide6 kontrol.
#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$Bundle   = "https://github.com/bol-van/zapret-win-bundle"
$InstallDir = "$env:ProgramFiles\AsenaDPI"
$Cfg      = "$env:APPDATA\AsenaDPI"
$RepoDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $RepoDir

function Say($m) { Write-Host ">> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "!! $m" -ForegroundColor Red; exit 1 }

# --- 0) git + python var mi ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Say "git yok -> winget ile kuruluyor..."
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements | Out-Null
}
$py = (Get-Command pythonw -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) {
    Say "Python yok -> winget ile kuruluyor..."
    winget install --id Python.Python.3.12 -e --accept-package-agreements --accept-source-agreements | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
}
Say "PySide6 kontrol..."
try { python -c "import PySide6.QtWidgets" 2>$null } catch {}
if ($LASTEXITCODE -ne 0) {
    Say "PySide6 kuruluyor (pip)..."
    python -m pip install --upgrade pip | Out-Null
    python -m pip install PySide6 | Out-Null
}

# --- 1) zapret-win-bundle indir (winws + WinDivert + blockcheck) ---
$tmp = "$env:TEMP\zapret-win-bundle"
if (Test-Path "$tmp\.git") { git -C $tmp pull --ff-only | Out-Null }
else { Say "zapret-win-bundle indiriliyor..."; git clone --depth 1 $Bundle $tmp | Out-Null }

# bundle icinde winws.exe + WinDivert dosyalari (surumden bagimsiz bul)
$winws = Get-ChildItem -Path $tmp -Recurse -Filter winws.exe | Select-Object -First 1
if (-not $winws) { Die "winws.exe bulunamadi (bundle yapisi degismis olabilir)." }
$winwsDir = $winws.Directory.FullName

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Say "winws + WinDivert -> $InstallDir"
Copy-Item "$winwsDir\*" $InstallDir -Recurse -Force   # winws.exe + WinDivert64.sys + WinDivert.dll vb.

# blockcheck (optimize icin) — bundle'da varsa kopyala
$bc = Get-ChildItem -Path $tmp -Recurse -Filter "blockcheck.cmd" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bc) { Copy-Item $bc.Directory.FullName "$InstallDir\blockcheck" -Recurse -Force }

# --- 2) tray + config ---
Say "Tray -> $InstallDir"
Copy-Item "$RepoDir\asena-dpi-tray.pyw" "$InstallDir\asena-dpi-tray.pyw" -Force

New-Item -ItemType Directory -Force -Path $Cfg | Out-Null
if (-not (Test-Path "$Cfg\blacklist.txt")) { Copy-Item "$RepoRoot\config\blacklist.txt" "$Cfg\blacklist.txt" -Force }
if (-not (Test-Path "$Cfg\settings.conf")) {
@"
# AsenaDPI ayarlari (tray yazar)
MODE=blacklist
HTTP=1
HTTP2=1
HTTP3=bypass
"@ | Set-Content "$Cfg\settings.conf" -Encoding utf8
}
if (-not (Test-Path "$Cfg\tcp443.conf")) {
    "--dpi-desync=fakedsplit --dpi-desync-fooling=md5sig --dpi-desync-split-pos=1" | Set-Content "$Cfg\tcp443.conf" -Encoding utf8
}

# --- 3) tray'i logon'da YONETICI olarak baslatan gorev (UAC'siz) ---
Say "Autostart gorevi (logon, en yuksek yetki)..."
$pyw = (Get-Command pythonw).Source
$act = New-ScheduledTaskAction -Execute $pyw -Argument "`"$InstallDir\asena-dpi-tray.pyw`""
$trg = New-ScheduledTaskTrigger -AtLogOn
$prn = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType Interactive
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "AsenaDPI-Tray" -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null

Say "KURULUM TAMAM. Tray'i simdi baslat:"
Write-Host "   schtasks /run /tn AsenaDPI-Tray" -ForegroundColor Yellow
Write-Host "   (sonraki her acilista otomatik, yonetici olarak, UAC'siz)"
Write-Host ""
Write-Host "   Tray: SOL tik = ayarlar · SAG tik = menu · 'En iyi strateji' = blockcheck" -ForegroundColor Gray
