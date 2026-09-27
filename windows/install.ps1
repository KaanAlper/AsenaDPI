# AsenaDPI - Windows kurulum (winws/WinDivert + DoH + tray).
# Yonetici PowerShell'de calistir:
#   Set-ExecutionPolicy -Scope Process Bypass -Force; .\install.ps1
#Requires -RunAsAdministrator
[System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Bundle     = "https://github.com/bol-van/zapret-win-bundle"
$InstallDir = "$env:ProgramFiles\AsenaDPI"
$Cfg        = "$env:APPDATA\AsenaDPI"
$RepoDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $RepoDir

. (Join-Path $RepoDir 'tui.ps1')
Clear-Host
Banner

$ans = Confirm "AsenaDPI Kurulumunu baslatmak istiyor musun?" "Evet, kur" "Iptal" $true
if (-not $ans) { Write-Host "`nIptal edildi."; exit 0 }
Write-Host ""

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
    # WinDivert KERNEL surucusu winws olunce hemen unload olmayabilir -> WinDivert64.sys kilitli kalir.
    foreach ($svc in @("WinDivert", "WinDivert1.4", "windivert")) { & sc.exe stop $svc 2>&1 | Out-Null }
    Start-Sleep -Milliseconds 1500
}

# Guvenli indirme yardimcisi: TLS 1.2/1.3 zorlar, sirasiyla curl.exe, WebClient ve Invoke-WebRequest dener
function Download-File {
    param([string]$Url, [string]$Dest)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls13'
    # 1. curl.exe (Windows 10 1803+ yerleşik gelir)
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -f -sSL -o $Dest $Url 2>&1 | Out-Null
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 1000) { return $true }
    }
    # 2. WebClient (.NET)
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        $wc.DownloadFile($Url, $Dest)
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 1000) { return $true }
    } catch {}
    # 3. Invoke-WebRequest (PowerShell)
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 1000) { return $true }
    } catch {}
    return $false
}

function Refresh-EnvPath {
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
    foreach ($d in @(
        "$env:ProgramFiles\Python312",
        "$env:ProgramFiles\Python312\Scripts",
        "$env:ProgramFiles\Python311",
        "$env:ProgramFiles\Python311\Scripts",
        "$env:ProgramFiles\Git\cmd",
        "$env:LOCALAPPDATA\Programs\Python\Python312",
        "$env:LOCALAPPDATA\Programs\Python\Python312\Scripts"
    )) {
        if ((Test-Path $d) -and ($env:Path -notlike "*$d*")) {
            $env:Path = "$d;$env:Path"
        }
    }
}

# --- 0) git (varsa kullanilir, yoksa winget ile denenir; bulunamazsa ZIP ile devam edilir) ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say "git yok -> winget ile sessiz kuruluyor..."
        Nat "winget" @("install","--id","Git.Git","-e","--silent","--accept-package-agreements","--accept-source-agreements") | Out-Null
        Refresh-EnvPath
    }
}

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
    # 1. Oncelikle gercek kurulu dizinlere bak (Store'un WindowsApps sahte stub'larina takilmasin)
    foreach ($g in @(
        "$env:ProgramFiles\Python3*\python.exe",
        "${env:ProgramFiles(x86)}\Python3*\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "C:\Python3*\python.exe",
        "C:\Program Files\Python3*\python.exe"
    )) {
        Get-ChildItem $g -ErrorAction SilentlyContinue | ForEach-Object { $cands += $_.FullName }
    }
    # 2. py launcher
    $pl = Get-Command py -ErrorAction SilentlyContinue
    if ($pl) {
        $p = (& $pl.Source -c "import sys;print(sys.executable)" 2>$null)
        if ($p) { $cands += "$p".Trim() }
    }
    # 3. PATH uzerindeki python
    foreach ($n in @("python", "python3")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source -and $c.Source -notmatch "WindowsApps") { $cands += $c.Source }
    }
    foreach ($c in ($cands | Select-Object -Unique)) {
        if (Test-Py $c) { return $c }
    }
    return $null
}

function Install-PythonSilently {
    Say "Calisan Python yok -> Resmi sessiz kurulum baslatiliyor..."
    $pyVer = "3.12.9"
    $is64 = [Environment]::Is64BitOperatingSystem
    $urls = if ($is64) {
        @(
            "https://www.python.org/ftp/python/$pyVer/python-$pyVer-amd64.exe",
            "https://cdn.npmmirror.com/binaries/python/$pyVer/python-$pyVer-amd64.exe"
        )
    } else {
        @(
            "https://www.python.org/ftp/python/$pyVer/python-$pyVer.exe",
            "https://cdn.npmmirror.com/binaries/python/$pyVer/python-$pyVer.exe"
        )
    }

    $installerPath = "$env:TEMP\python-$pyVer-setup.exe"
    $downloaded = $false
    foreach ($u in $urls) {
        try {
            Get-WithBar $u $installerPath "Python $pyVer" 0
            $downloaded = $true
            break
        } catch { }
    }

    if ($downloaded) {
        Say "Python $pyVer sessizce kuruluyor (arkaplanda, kullanici onayi gerektirmez)..."
        # /quiet: tamamen sessiz, hicbir pencere/onay sormaz
        # InstallAllUsers=1: Program Files altina tum kullanicilar icin kurar
        # PrependPath=1: Otomatik PATH ortam degiskenine ekler
        # Include_pip=1: pip'i hazir kurar
        # Include_test=0, Include_doc=0, Include_tcltk=0: gereksiz dosya yuklemez
        $pyArgs = "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1 Include_test=0 Include_doc=0 Include_tcltk=0 SimpleInstall=1"
        $proc = Start-Process -FilePath $installerPath -ArgumentList $pyArgs -Wait -PassThru
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
    } else {
        # Dogrudan indirme basarisiz olursa alternatif olarak winget ile sessizce dene
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Say "Resmi sunucudan alinamadi -> winget ile sessiz kuruluyor..."
            Nat "winget" @("install","--id","Python.Python.3.12","-e","--silent","--accept-package-agreements","--accept-source-agreements","--override","/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1") | Out-Null
        }
    }

    Refresh-EnvPath
}

$pyExe = Find-Python
if (-not $pyExe) {
    Install-PythonSilently
    for ($attempt = 1; $attempt -le 5 -and -not $pyExe; $attempt++) {
        Refresh-EnvPath
        $pyExe = Find-Python
        if (-not $pyExe) { Start-Sleep -Seconds 1 }
    }
}
if (-not $pyExe) { Die "Python otomatik olarak kurulamadi. Internet baglantinizi kontrol edip tekrar deneyin." }
$pyDir = Split-Path $pyExe
$pyw = Join-Path $pyDir "pythonw.exe"
if (-not (Test-Path $pyw)) { $pyw = $pyExe }
Say "Python: $pyExe"

# --- 0c) PySide6 (exit code ile kontrol; traceback scripti oldurmez) ---
# PySide6 - import KONTROLU YOK (Qt DLL yuklemesi Defender ile dakikalarca asili kalabiliyordu).
# Dogrudan pip: kuruluysa "already satisfied" deyip ~2sn'de gecer, degilse kurar. Qt yuklenmez.
Say "PySide6 (pip - kuruluysa aninda gecer, degilse ~250 MB indirir)..."
& $pyExe -m pip install --upgrade pip --quiet 2>&1 | Out-Null
$pysideOk = $false
for ($i = 1; $i -le 4 -and -not $pysideOk; $i++) {
    if ($i -gt 1) { Say "PySide6 tekrar deneniyor ($i/4) - baglanti kopmustu..." }
    With-Spinner "PySide6 kur/guncelle" { & $pyExe -m pip install --timeout 120 --retries 8 PySide6 --quiet 2>&1 | Out-Null }
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
} elseif (Get-Command git -ErrorAction SilentlyContinue) {
    Say "zapret-win-bundle indiriliyor (~60 MB, biraz surer)..."
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    & git clone --depth 1 $Bundle $tmp
} else {
    $zipBundle = "$env:TEMP\zapret-bundle.zip"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    $bundleZipUrl = "https://github.com/bol-van/zapret-win-bundle/archive/refs/heads/master.zip"
    try {
        Get-WithBar $bundleZipUrl $zipBundle "zapret-win-bundle" 0
        $extractTmp = "$env:TEMP\zapret-extract"
        Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
        With-Spinner "ZIP ayiklaniyor" { Expand-Archive -Path $zipBundle -DestinationPath $extractTmp -Force }
        Remove-Item $zipBundle -Force -ErrorAction SilentlyContinue
        if (Test-Path "$extractTmp\zapret-win-bundle-master") {
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            Copy-Item "$extractTmp\zapret-win-bundle-master\*" $tmp -Recurse -Force
            Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}
if (-not (Test-Path "$tmp\zapret-winws\winws.exe")) {
    Say "bundle eksik -> temiz yeniden indiriliyor..."
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git clone --depth 1 $Bundle $tmp
    } else {
        $zipBundle = "$env:TEMP\zapret-bundle.zip"
        try {
            Get-WithBar "https://github.com/bol-van/zapret-win-bundle/archive/refs/heads/master.zip" $zipBundle "zapret-win-bundle (fallback)" 0
            $extractTmp = "$env:TEMP\zapret-extract"
            Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
            With-Spinner "ZIP ayiklaniyor" { Expand-Archive -Path $zipBundle -DestinationPath $extractTmp -Force }
            Remove-Item $zipBundle -Force -ErrorAction SilentlyContinue
            if (Test-Path "$extractTmp\zapret-win-bundle-master") {
                New-Item -ItemType Directory -Force -Path $tmp | Out-Null
                Copy-Item "$extractTmp\zapret-win-bundle-master\*" $tmp -Recurse -Force
                Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}
if (-not (Test-Path "$tmp\zapret-winws\winws.exe")) {
    Die "Bundle indirilemedi ($tmp). github.com'a erisim / disk / '$tmp' iznini kontrol edin."
}

Stop-AsenaDPI   # kopyalamadan ONCE winws+tray durdur (yoksa WinDivert64.sys kilitli -> kopya hatasi)
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
With-Spinner "Dosyalar kopyalaniyor ($InstallDir)" {
    Get-ChildItem -Path $tmp -Force | Where-Object { $_.Name -ne ".git" -and $_.Name -ne ".github" } |
        ForEach-Object { Copy-Item $_.FullName $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
}
if (-not (Test-Path "$InstallDir\zapret-winws\winws.exe")) { Die "Kopyalama basarisiz -> $InstallDir\zapret-winws" }
# blockcheck ('En iyi ayar') prerequisites: winws.exe + mdig.exe SART. Eksik kopyalanmissa
# (kismi kopya) blockcheck saniyelerde cikip yanlis 'DNS yeter' der -> eksik dosyalari tekrar kopyala.
ForEach ($need in @("blockcheck\zapret\nfq\winws.exe", "blockcheck\zapret\mdig\mdig.exe", "blockcheck\zapret\ip2net\ip2net.exe")) {
    $dst = Join-Path $InstallDir $need
    if (-not (Test-Path $dst)) {
        $srcf = Join-Path $tmp $need
        if (Test-Path $srcf) {
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item $srcf $dst -Force -ErrorAction SilentlyContinue
        }
    }
}
if (-not (Test-Path "$InstallDir\blockcheck\zapret\mdig\mdig.exe")) {
    Say "UYARI: mdig.exe kopyalanamadi -> 'En iyi ayar' (blockcheck) calismayabilir. install.ps1'i tekrar calistir."
}

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
try {
    With-Spinner "Otomatik baslatma gorevi (Yonetici)" {
        $act = New-ScheduledTaskAction -Execute $pyw -Argument "`"$InstallDir\asena-dpi-tray.pyw`""
        $trg = New-ScheduledTaskTrigger -AtLogOn
        $prn = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType Interactive
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName "AsenaDPI-Tray" -Action $act -Trigger $trg -Principal $prn -Settings $set -Force -ErrorAction Stop | Out-Null
    }
} catch {
    Say "UYARI: autostart gorevi kurulamadi ($($_.Exception.Message)). Tray'i elle baslatabilirsin:"
    Write-Host "   `"$pyw`" `"$InstallDir\asena-dpi-tray.pyw`"" -ForegroundColor Yellow
}

# --- 3b) Baslat menusu + masaustu kisayolu (aranabilir, ikonlu) ---
try {
    With-Spinner "Kisayollar (Masaustu & Baslat)" {
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
    }
} catch {
    Say "UYARI: kisayol olusturulamadi ($($_.Exception.Message))."
}

# --- 4) tray'i SIMDI baslat (sonraki acilista gorev zaten baslatir) ---
With-Spinner "AsenaDPI Tray baslatiliyor" {
    Stop-AsenaDPI   # eski tray kalmadigindan emin ol (cift tray olmasin)
    if ((Nat "schtasks" @("/run","/tn","AsenaDPI-Tray")) -ne 0) {
        Start-Process $pyw -ArgumentList "`"$InstallDir\asena-dpi-tray.pyw`""   # gorev yoksa dogrudan
    }
}

Write-Host ""
Box $C.ok "Kurulum Tamamlandi" "Tray sistem tepsisinde (AsenaDPI ikonu). SOL tik = ac/kapat, SAG tik = menu`nSonraki her acilista yonetici (UAC'siz) olarak otomatik baslar."
Write-Host ""
