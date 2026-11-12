#ifndef AppVersion
  #define AppVersion "0.7.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\v0.7.0"
#endif
#ifndef OutputDir
  #define OutputDir SourceDir
#endif

[Setup]
AppId={{A6F7EAF4-57F8-4D1D-87E8-0E7DAD668F5E}
AppName=专家云盘小助手
AppVersion={#AppVersion}
AppVerName=专家云盘小助手 {#AppVersion}
AppPublisher=专家云盘
AppPublisherURL=https://ed.lorne.top
AppSupportURL=https://ed.lorne.top/helper
AppUpdatesURL=https://ed.lorne.top/helper
DefaultDirName={localappdata}\ExpertDock
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=ExpertDock-Helper-Setup-{#AppVersion}
SetupIconFile={#SourceDir}\expertdock.ico
UninstallDisplayIcon={app}\expertdock.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
ChangesAssociations=yes
CloseApplications=no
RestartApplications=no
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=专家云盘
VersionInfoDescription=专家云盘小助手安装程序
VersionInfoProductName=专家云盘小助手
VersionInfoProductVersion={#AppVersion}
VersionInfoCopyright=Copyright (C) 2026 ExpertDock
#ifdef SignToolName
SignTool={#SignToolName}
SignedUninstaller=yes
#endif

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#SourceDir}\expertdock-helper.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\helper-ui.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\expertdock.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\helper-env.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\node-runtime-win-x64.zip"; DestDir: "{app}"; Flags: ignoreversion

[Registry]
Root: HKCU; Subkey: "Software\Classes\expertdock"; ValueType: string; ValueName: ""; ValueData: "URL:ExpertDock Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\expertdock"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\expertdock\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\expertdock.ico"
Root: HKCU; Subkey: "Software\Classes\expertdock\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{sys}\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\helper-ui.ps1"" -Url ""%1"""
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "ExpertDock Helper"; ValueData: """{sys}\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\helper-ui.ps1"" -Startup"; Flags: uninsdeletevalue

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\helper-ui.ps1"" -Shutdown"; Flags: runhidden waituntilterminated
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\helper-ui.ps1"""; Description: "启动专家云盘小助手"; Flags: postinstall nowait skipifsilent runhidden

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\helper-ui.ps1"" -Shutdown"; Flags: runhidden waituntilterminated; RunOnceId: "StopExpertDockHelper"

[UninstallDelete]
Type: files; Name: "{app}\install.cmd"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := '正在准备 Node.js / npm / npx 运行环境…';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\helper-ui.ps1') + '" -PrepareEnvironment',
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('无法启动运行环境准备程序，请重新运行安装器。');
    if ResultCode <> 0 then
      RaiseException('运行环境准备失败，请查看 %APPDATA%\ExpertDock\logs 后重新运行安装器。');
  end;
end;

