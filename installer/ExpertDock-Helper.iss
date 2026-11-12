#ifndef AppVersion
  #define AppVersion "0.8.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\release\v0.8.0"
#endif
#ifndef OutputDir
  #define OutputDir SourceDir
#endif

; v0.8.0 起 Helper 为纯 Go 应用：Setup 只装 exe/图标/受管 Node 运行时，
; 协议与自启动直接指向 exe（不再经 powershell/helper-ui.ps1）；
; 从 v0.7.x 升级时，残留的 ps1 文件由新 exe 首次启动自动清扫（takeOverLegacyInstall）。

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
Source: "{#SourceDir}\expertdock.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\node-runtime-win-x64.zip"; DestDir: "{app}"; Flags: ignoreversion

[Registry]
Root: HKCU; Subkey: "Software\Classes\expertdock"; ValueType: string; ValueName: ""; ValueData: "URL:ExpertDock Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\expertdock"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\expertdock\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\expertdock.ico"
Root: HKCU; Subkey: "Software\Classes\expertdock\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\expertdock-helper.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "ExpertDock Helper"; ValueData: """{app}\expertdock-helper.exe"""; Flags: uninsdeletevalue

[Run]
Filename: "{app}\expertdock-helper.exe"; Description: "启动专家云盘小助手"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "taskkill.exe"; Parameters: "/IM expertdock-helper.exe /F"; Flags: runhidden; RunOnceId: "StopExpertDockHelper"

[Code]
// 安装前停止旧实例：v0.7.x 的 ps1 托盘（按命令行匹配，避免误伤其他 powershell）
// 与任何 expertdock-helper.exe（旧 0.2.5 core 或上一版 v0.8.x GUI）。失败不阻断——
// 文件被占用时 Inno 会按 ignoreversion 排队替换，最坏情况是旧托盘多挂几分钟。
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match ''helper-ui\.ps1'' -or $_.Name -eq ''expertdock-helper.exe'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := '正在准备 Node.js / npm / npx 运行环境…';
    if not Exec(ExpandConstant('{app}\expertdock-helper.exe'),
      '--prepare-env', ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('无法启动运行环境准备程序，请重新运行安装器。');
    if ResultCode <> 0 then
      RaiseException('运行环境准备失败，请查看 %APPDATA%\ExpertDock\logs 后重新运行安装器。');
  end;
end;
