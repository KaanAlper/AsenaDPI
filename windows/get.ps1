# AsenaDPI - Windows tek-komut kurulum bootstrap'i.
# NORMAL PowerShell'de (yonetici gerekmez, install.ps1 kendi UAC'sini ister):
#   irm https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/windows/get.ps1 | iex
#
# Yaptigi: git yoksa winget ile kur -> repoyu klonla/guncelle -> install.ps1'i YONETICI baslat.
# NOT: $ErrorActionPreference STOP DEGIL (winget/git stderr'e yazinca abort etmesin).

$Repo = "https://github.com/KaanAlper/AsenaDPI.git"
$Dir  = "$env:USERPROFILE\AsenaDPI"

Write-Host ">> AsenaDPI kurulumu basliyor..." -ForegroundColor Cyan

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host ">> git yok -> winget ile kuruluyor..." -ForegroundColor Cyan
        winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
    }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "!! git kurulamadi. Once git kur (https://git-scm.com) ve tekrar dene." -ForegroundColor Red
    return
}

if (Test-Path "$Dir\.git") {
    Write-Host ">> Mevcut kurulum guncelleniyor: $Dir" -ForegroundColor Cyan
    git -C $Dir pull --ff-only 2>&1 | Out-Null
} else {
    Write-Host ">> Klonlaniyor -> $Dir" -ForegroundColor Cyan
    git clone --depth 1 $Repo $Dir 2>&1 | Out-Null
}
if (-not (Test-Path "$Dir\windows\install.ps1")) {
    Write-Host "!! Klonlama basarisiz ($Dir). Internet/git kontrol et." -ForegroundColor Red
    return
}

Write-Host ">> Kurulum YONETICI olarak baslatiliyor (UAC onayi cikacak)..." -ForegroundColor Yellow
# -NoExit: kurulum bitince/hata verince pencere ACIK kalsin (kullanici gorsun)
Start-Process powershell -Verb RunAs -ArgumentList @(
    "-NoProfile","-NoExit","-ExecutionPolicy","Bypass","-File","`"$Dir\windows\install.ps1`""
)
Write-Host ">> Yonetici penceresinde kurulum devam ediyor. Bitince tray tepsiden acilir." -ForegroundColor Green
