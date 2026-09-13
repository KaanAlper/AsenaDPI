# AsenaDPI - Windows tek-komut kurulum bootstrap'i.
# NORMAL PowerShell'de (yonetici gerekmez, install.ps1 kendi UAC'sini ister):
#   irm https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/windows/get.ps1 | iex
#
# Yaptigi: git yoksa winget ile kur -> repoyu klonla/guncelle -> install.ps1'i YONETICI baslat.
# NOT: $ErrorActionPreference STOP DEGIL (winget/git stderr'e yazinca abort etmesin).

$Repo = "https://github.com/KaanAlper/AsenaDPI.git"
$Dir  = "$env:USERPROFILE\AsenaDPI"

Write-Host ">> AsenaDPI kurulumu basliyor..." -ForegroundColor Cyan

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls13'
$ZipUrl = "https://github.com/KaanAlper/AsenaDPI/archive/refs/heads/master.zip"

if (Get-Command git -ErrorAction SilentlyContinue) {
    if (Test-Path "$Dir\.git") {
        Write-Host ">> Mevcut kurulum guncelleniyor: $Dir" -ForegroundColor Cyan
        git -C $Dir pull --ff-only 2>&1 | Out-Null
    } else {
        Write-Host ">> Klonlaniyor -> $Dir" -ForegroundColor Cyan
        git clone --depth 1 $Repo $Dir 2>&1 | Out-Null
    }
} else {
    Write-Host ">> AsenaDPI dosyalari indiriliyor..." -ForegroundColor Cyan
    $zipPath = "$env:TEMP\AsenaDPI-master.zip"
    $downloaded = $false
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -f -sSL -o $zipPath $ZipUrl 2>&1 | Out-Null
        if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 1000) { $downloaded = $true }
    }
    if (-not $downloaded) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0")
            $wc.DownloadFile($ZipUrl, $zipPath)
            if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 1000) { $downloaded = $true }
        } catch {}
    }
    if (-not $downloaded) {
        try {
            Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 1000) { $downloaded = $true }
        } catch {}
    }
    if ($downloaded) {
        $extractTmp = "$env:TEMP\AsenaDPI-extract"
        Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        if (Test-Path "$extractTmp\AsenaDPI-master") {
            New-Item -ItemType Directory -Force -Path $Dir | Out-Null
            Copy-Item "$extractTmp\AsenaDPI-master\*" $Dir -Recurse -Force
            Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not (Test-Path "$Dir\windows\install.ps1")) {
    Write-Host "!! Kurulum dosyalari alinamadi ($Dir). Internet baglantinizi kontrol edin." -ForegroundColor Red
    return
}

Write-Host ">> Kurulum YONETICI olarak baslatiliyor (UAC onayi cikacak)..." -ForegroundColor Yellow
# -NoExit: kurulum bitince/hata verince pencere ACIK kalsin (kullanici gorsun)
Start-Process powershell -Verb RunAs -ArgumentList @(
    "-NoProfile","-NoExit","-ExecutionPolicy","Bypass","-File","`"$Dir\windows\install.ps1`""
)
Write-Host ">> Yonetici penceresinde kurulum devam ediyor. Bitince tray tepsiden acilir." -ForegroundColor Green
