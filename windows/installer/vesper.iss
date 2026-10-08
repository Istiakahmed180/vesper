; Inno Setup script for the Vesper Windows installer.
; Build the app first (flutter build windows --release --dart-define-from-file=.env),
; then compile:  ISCC.exe /DAppVersion=0.1.0 windows\installer\vesper.iss
; Output: dist\Vesper-Setup-<version>.exe
; Relative paths are resolved from this file's folder.

#define AppName "Vesper"
#define AppExe "Vesper.exe"
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
; Stable id: lets new versions upgrade the existing installation in place.
AppId={{8F3C2A1E-5B7D-4E9A-9C21-6D4F0B7A3E52}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=tdevs
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=Vesper-Setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Install for all users by default; the wizard offers "only for me" too.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
; Windows 10 1809 or later.
MinVersion=10.0.17763
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
