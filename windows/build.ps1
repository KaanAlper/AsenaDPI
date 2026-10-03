# Windows: AsenaDPI-Setup.exe derle (PyInstaller onedir + zapret-win-bundle + Inno Setup).
# Cikti: dist\AsenaDPI-Setup.exe ve dist\AsenaDPI-Setup.exe.sha256 (tray'in 'Guncelle'si ve install.ps1 bu adlari arar).
#   pwsh ./windows/build.ps1 -Version 1.2.3
# Gerekenler: Python 3.12 (pip), git; Inno Setup 6 yoksa choco ile kurulur.
param([string]$Version = '0.0.0')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Surum x.y.z olmali, gelen: $Version" }
Set-Location (Split-Path $PSScriptRoot -Parent)

python -m pip install --upgrade pip "pyinstaller>=6.10,<7" "pyside6-essentials>=6.7,<7"
if ($LASTEXITCODE) { throw "pip exit $LASTEXITCODE" }

# Surumu koda damgala (kopyada degil: PyInstaller bu dosyayi paketler; is bitince geri alinir)
$f = 'windows/asena-dpi-tray.pyw'
$orig = Get-Content $f -Raw -Encoding utf8
$new = $orig -replace '(?m)^APP_VERSION = "dev"', "APP_VERSION = `"$Version`""
if ($new -eq $orig) { throw 'APP_VERSION satiri bulunamadi' }
[IO.File]::WriteAllText((Resolve-Path $f), $new, [Text.UTF8Encoding]::new($false))
try {
    pyinstaller --noconfirm --clean --windowed --onedir --name AsenaDPI `
        --icon windows/asena-dpi.ico `
        --exclude-module tkinter --exclude-module unittest --exclude-module pydoc `
        windows/asena-dpi-tray.pyw
    if ($LASTEXITCODE) { throw "pyinstaller exit $LASTEXITCODE" }
}
finally { [IO.File]::WriteAllText((Resolve-Path $f), $orig, [Text.UTF8Encoding]::new($false)) }
# Widget uygulamasi icin gereksiz: yazilim OpenGL (~20 MB) + Qt ceviri dosyalari
Get-ChildItem dist/AsenaDPI -Recurse -Include opengl32sw.dll | Remove-Item -Force
Get-ChildItem dist/AsenaDPI -Recurse -Directory -Filter translations | Remove-Item -Recurse -Force
'{0:N1} MB' -f ((Get-ChildItem dist/AsenaDPI -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)

# Exe acilis testi
$out = Join-Path ([IO.Path]::GetTempPath()) 'asenadpi-selftest.txt'
Remove-Item $out -Force -ErrorAction SilentlyContinue
$p = Start-Process dist/AsenaDPI/AsenaDPI.exe -ArgumentList '--selftest', "`"$out`"" -Wait -PassThru
if ($p.ExitCode -ne 0 -or -not (Test-Path $out)) { throw "selftest basarisiz (exit $($p.ExitCode))" }
$got = Get-Content $out
if ($got -ne "ok $Version") { throw "selftest beklenmeyen cikti: $got" }
"selftest: $got"

# zapret-win-bundle
$bundle = 'build/zapret-win-bundle'
Remove-Item $bundle -Recurse -Force -ErrorAction SilentlyContinue
git clone --depth 1 https://github.com/bol-van/zapret-win-bundle $bundle
if ($LASTEXITCODE) { throw "git clone exit $LASTEXITCODE" }
git -C $bundle log -1 --format='bundle commit: %H %cd'
# blockcheck ('En iyi ayar') + baglanti icin SART dosyalar; eksikse build kirilsin
$need = @(
    'zapret-winws/winws.exe', 'zapret-winws/WinDivert64.sys', 'zapret-winws/WinDivert.dll',
    'cygwin/bin/bash.exe', 'blockcheck/zapret/blockcheck.sh',
    'blockcheck/zapret/nfq/winws.exe', 'blockcheck/zapret/mdig/mdig.exe',
    'blockcheck/zapret/ip2net/ip2net.exe'
)
$miss = $need | Where-Object { -not (Test-Path "$bundle/$_") }
if ($miss) { throw "bundle'da eksik: $($miss -join ', ')" }

# Inno Setup
$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) { choco install innosetup -y --no-progress | Out-Null }
& $iscc "/DAppVersion=$Version" "/DBundleDir=$((Resolve-Path $bundle).Path)" windows\installer.iss
if ($LASTEXITCODE) { throw "ISCC exit $LASTEXITCODE" }
$h = (Get-FileHash dist/AsenaDPI-Setup.exe -Algorithm SHA256).Hash.ToLower()
"$h  AsenaDPI-Setup.exe" | Set-Content dist/AsenaDPI-Setup.exe.sha256 -Encoding ascii
'{0:N1} MB  sha256={1}' -f ((Get-Item dist/AsenaDPI-Setup.exe).Length / 1MB), $h
