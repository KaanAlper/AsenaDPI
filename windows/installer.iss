; AsenaDPI - Windows kurulum sihirbazi (Inno Setup 6).
; CI derler (.github/workflows/windows-release.yml):
;   iscc /DAppVersion=1.2.0 /DBundleDir=<zapret-win-bundle yolu> windows\installer.iss
; Girdi: dist\AsenaDPI\ (PyInstaller onedir) + zapret-win-bundle (winws + WinDivert + blockcheck + cygwin)
; Cikti: dist\AsenaDPI-Setup.exe
;
; Python/PySide6/git GEREKMEZ, kurulumda internet GEREKMEZ (bundle icinde -> DPI'a takilmaz).
; Sessiz guncelleme: AsenaDPI-Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART  (tray bunu cagirir)

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BundleDir
  #define BundleDir "..\build\zapret-win-bundle"
#endif

[Setup]
AppId={{9470A0DB-A82D-4627-B054-40BC61F0DBF3}
AppName=AsenaDPI
AppVersion={#AppVersion}
AppVerName=AsenaDPI {#AppVersion}
AppPublisher=Kaan Alper
AppPublisherURL=https://github.com/KaanAlper/AsenaDPI
AppSupportURL=https://github.com/KaanAlper/AsenaDPI/issues
DefaultDirName={autopf}\AsenaDPI
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=AsenaDPI-Setup
SetupIconFile=asena-dpi.ico
UninstallDisplayIcon={app}\AsenaDPI.exe
UninstallDisplayName=AsenaDPI
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Kapatmayi biz yapiyoruz (PrepareToInstall) - Restart Manager WinDivert surucusunu bilmez
CloseApplications=no
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName=AsenaDPI

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; eski Python tabanli kurulumdan kalanlar
Type: files; Name: "{app}\asena-dpi-tray.pyw"
Type: filesandordirs; Name: "{app}\_internal"

[Files]
Source: "..\dist\AsenaDPI\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleDir}\zapret-winws\*"; DestDir: "{app}\zapret-winws"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleDir}\blockcheck\*"; DestDir: "{app}\blockcheck"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleDir}\cygwin\*"; DestDir: "{app}\cygwin"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleDir}\tools\*"; DestDir: "{app}\tools"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "asena-dpi.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\config\blacklist.txt"; DestDir: "{app}\defaults"; Flags: ignoreversion

[Icons]
; Kisayol exe'yi dogrudan acar: yonetici degilse gorevi (UAC'siz) baslatip paneli acar.
Name: "{autoprograms}\AsenaDPI"; Filename: "{app}\AsenaDPI.exe"; IconFilename: "{app}\asena-dpi.ico"; Comment: "AsenaDPI - DPI/DNS bypass"
Name: "{autodesktop}\AsenaDPI"; Filename: "{app}\AsenaDPI.exe"; IconFilename: "{app}\asena-dpi.ico"; Comment: "AsenaDPI - DPI/DNS bypass"; Tasks: desktopicon

[Run]
; logon gorevi (bu kullanici, en yuksek yetki, sure siniri yok) -> sonraki acilislarda UAC'siz
Filename: "{app}\AsenaDPI.exe"; Parameters: "--install-task"; Flags: runhidden waituntilterminated; StatusMsg: "Baslangic gorevi ayarlaniyor..."
; tray'i simdi baslat (sessiz guncellemede de calisir)
Filename: "{sys}\schtasks.exe"; Parameters: "/run /tn AsenaDPI-Tray"; Flags: runhidden nowait

[UninstallRun]
; winws durdur + DNS/QUIC kuralini geri al + gorevi sil + calisan tray'i kapat
Filename: "{app}\AsenaDPI.exe"; Parameters: "--uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "AsenaCleanup"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
procedure RunHidden(const Exe, Params: String);
var
  Rc: Integer;
begin
  Exec(Exe, Params, '', SW_HIDE, ewWaitUntilTerminated, Rc);
end;

{ Kopyalamadan ONCE tray + winws + WinDivert surucusu durmali; yoksa WinDivert64.sys kilitli kalir. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Sys: String;
begin
  Sys := ExpandConstant('{sys}');
  RunHidden(Sys + '\taskkill.exe', '/f /im AsenaDPI.exe');
  RunHidden(Sys + '\taskkill.exe', '/f /im winws.exe');
  { eski Python tabanli tray (pythonw asena-dpi-tray.pyw) }
  RunHidden(Sys + '\WindowsPowerShell\v1.0\powershell.exe',
      '-NoProfile -NonInteractive -Command "Get-CimInstance Win32_Process | ' +
      'Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like ''*asena-dpi-tray.pyw*'' } | ' +
      'ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"');
  RunHidden(Sys + '\sc.exe', 'stop WinDivert');
  RunHidden(Sys + '\sc.exe', 'stop WinDivert1.4');
  RunHidden(Sys + '\sc.exe', 'stop windivert');
  Sleep(1500);
  Result := '';
end;
