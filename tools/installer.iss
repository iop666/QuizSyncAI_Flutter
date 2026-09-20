; AI 双端搜题（QuizSync AI）- Inno Setup 6 installer script
; Build: "<Inno Setup>\ISCC.exe" tools\installer.iss
; 用户数据（数据库/图片缓存/日志/备份）在软件自己的 userdata 下，卸载不删除。
; 注意：本文件含中文，必须存成 **UTF-8 with BOM**（Inno Setup 6 认 BOM；
; 无 BOM 时会按系统 ANSI 码页读，中文会变乱码）。

#define AppName "AI 双端搜题"
#define AppVersion "1.0.0"
#define AppExeName "quizsync_desktop.exe"
#define ReleaseDir "..\apps\desktop\build\windows\x64\runner\Release"

[Setup]
AppId={{7C6E1F42-9A3B-4D8E-B5C7-1A2D4F6E8B90}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=AI 双端搜题 (QuizSync AI)
DefaultDirName={autopf}\AI 双端搜题
DefaultGroupName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
SetupIconFile=..\apps\desktop\windows\runner\resources\app_icon.ico
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
CloseApplications=yes
CloseApplicationsFilter={#AppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
OutputDir=..\dist
OutputBaseFilename=quizsync-windows-setup-{#AppVersion}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Excludes userdata：那是运行时生成的用户数据（库/截图/密钥），绝不能进安装包。
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Excludes: "userdata\*,userdata"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
