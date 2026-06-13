#define MyAppName "VoiceStick"
#define MyAppPublisher "TenClass"
#define MyAppExeName "VoiceStick.exe"
#ifndef MyAppVersion
#define MyAppVersion "0.0.0"
#endif
#ifndef BuildDir
#define BuildDir "..\build-msi-x64"
#endif
#ifndef ProjectDir
#define ProjectDir "..\..\.."
#endif

[Setup]
AppId={{EA755DA7-1A4E-4ED2-8051-4E31B55FCA6B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#BuildDir}
OutputBaseFilename=VoiceStickSetup-{#MyAppVersion}
SetupIconFile={#ProjectDir}\desktop\windows\resources\app.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\{#MyAppExeName}
LicenseFile={#ProjectDir}\desktop\windows\installer\license.rtf
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimp"; MessagesFile: "{#ProjectDir}\desktop\windows\installer\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："; Flags: unchecked

[Files]
Source: "{#BuildDir}\VoiceStick.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\WinSparkle.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\VoiceStick"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\卸载 VoiceStick"; Filename: "{uninstallexe}"
Name: "{autodesktop}\VoiceStick"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 VoiceStick"; Flags: nowait postinstall skipifsilent