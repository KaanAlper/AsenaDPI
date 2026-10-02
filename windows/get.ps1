# AsenaDPI - Windows tek-komut kurulum.
# NORMAL PowerShell'de (yonetici gerekmez, Setup kendi UAC'sini ister):
#   irm https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/windows/get.ps1 | iex
#
# Yaptigi: GitHub Releases'tan son AsenaDPI-Setup.exe'yi indir -> calistir.
# Python / PySide6 / git GEREKMEZ (hepsi Setup'in icinde).

$Url  = "https://github.com/KaanAlper/AsenaDPI/releases/latest/download/AsenaDPI-Setup.exe"
$Dest = Join-Path $env:TEMP "AsenaDPI-Setup.exe"

Write-Host ">> AsenaDPI indiriliyor..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls13'
Remove-Item $Dest -Force -ErrorAction SilentlyContinue

function Test-Download { (Test-Path $Dest) -and (Get-Item $Dest).Length -gt 1MB }

if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    & curl.exe -f -L --retry 3 -o $Dest $Url
}
if (-not (Test-Download)) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "AsenaDPI-get")
        $wc.DownloadFile($Url, $Dest)
    } catch {}
}
if (-not (Test-Download)) {
    try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop } catch {}
}
if (-not (Test-Download)) {
    Write-Host "!! Indirilemedi. Elle indir: https://github.com/KaanAlper/AsenaDPI/releases/latest" -ForegroundColor Red
    return
}

Write-Host ">> Kurulum baslatiliyor (UAC onayi cikacak)..." -ForegroundColor Yellow
Start-Process -FilePath $Dest -ArgumentList "/SILENT", "/SP-", "/NORESTART" -Wait
Write-Host ">> Tamam. AsenaDPI sistem tepsisinde (sol tik = ac/kapat, sag tik = menu)." -ForegroundColor Green
