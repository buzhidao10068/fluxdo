#define MyAppName "FluxDO"
#define MyAppExeName "fluxdo-nodeloc.exe"
#define MyAppInstallName "FluxDO NodeLoc"
#define MyAppPublisher "FluxDO"
#define MyAppURL "https://github.com/buzhidao10068/fluxdo"

[Setup]
AppId={{F9CB3564-FA04-4AF3-88E7-35D2B77A09B2}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppInstallName}
DefaultGroupName={#MyAppInstallName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=fluxdo-windows-x86_64-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
; 不能追加旧版 uninsdeletekey 动作，否则会绕过新的 scheme 归属检查。
; 当前包完整重装自身文件；只存在于旧版日志的文件可能残留，见 docs/release.md。
UninstallLogMode=overwrite
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppInstallName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppInstallName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

; 注册 URL scheme（与 windows/fluxdo_url_scheme.reg 保持同步）。
; - fluxdo://    应用自有深链（话题 / 用户 / 设置等）
; - discourse:// Discourse User API Key 授权回调
;                缺了它，Windows 上授权登录会断在最后一步。
; HKA 默认写 HKCU；用户选择管理员安装时写 HKLM。
; 共用 scheme 不记录无条件卸载删除，交由下方代码核对当前归属。
; {app} 会展开为实际安装目录（默认 {autopf}\FluxDO NodeLoc）。
[Registry]
Root: HKA; Subkey: "Software\Classes\fluxdo"; ValueType: string; ValueName: ""; ValueData: "URL:FluxDO Protocol"
Root: HKA; Subkey: "Software\Classes\fluxdo"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\fluxdo\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""
Root: HKA; Subkey: "Software\Classes\discourse"; ValueType: string; ValueName: ""; ValueData: "URL:Discourse Protocol"
Root: HKA; Subkey: "Software\Classes\discourse"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\discourse\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
procedure RemoveOwnedProtocol(const RootKey: Integer; const Scheme: String);
var
  Subkey, Command, ExpectedCommand: String;
begin
  Subkey := 'Software\Classes\' + Scheme;
  ExpectedCommand := ExpandConstant('"{app}\{#MyAppExeName}" "%1"');
  if RegQueryStringValue(RootKey, Subkey + '\shell\open\command', '', Command) then
  begin
    { 安装器与 Dart 注册器都写同一命令。保守地比较完整命令和安装路径，
      不按 exe 文件名或子串判断，以免删掉另一安装位置或别的应用。 }
    if CompareText(Trim(Command), ExpectedCommand) = 0 then
    begin
      if not RegDeleteKeyIncludingSubkeys(RootKey, Subkey) then
        Log('Could not remove owned protocol: ' + Scheme);
    end
    else
      Log('Preserving protocol owned by another handler: ' + Scheme);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    { 应用运行时总是写 HKCU，即使安装器曾以管理员模式写入 HKLM。 }
    RemoveOwnedProtocol(HKCU, 'fluxdo');
    RemoveOwnedProtocol(HKCU, 'discourse');
    if IsAdminInstallMode then
    begin
      RemoveOwnedProtocol(HKLM, 'fluxdo');
      RemoveOwnedProtocol(HKLM, 'discourse');
    end;
  end;
end;

procedure KillProcesses;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/f /im {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function InitializeSetup(): Boolean;
begin
  KillProcesses;
  Result := True;
end;

function InitializeUninstall(): Boolean;
begin
  KillProcesses;
  Result := True;
end;
