; LocalFlow per-user installer. Inno Setup 6.3 or later (x64compatible). Built by CI only, because
; release shaders need fxc.exe:
;   iscc /DAppVersion=0.1.0 packaging\windows\localflow.iss
; scripts/check-windows-installer.py checks this file against the Cargo bin and the Run key in Rust.
; Unsigned: SignTool is deliberately not configured. Feature 028 decides signing and updates.

#ifndef AppVersion
  #error Pass the version: iscc /DAppVersion=x.y.z
#endif
#define ExeName "localflow.exe"
#define WorkerName "flow-speech-win.exe"
; A build input, not compiled here: the pinned sherpa-onnx libraries, which the worker checks against
; crates/flow-speech-win/manifest.json before loading. The CI job fetches them.
#define SherpaDir "..\..\build\sherpa-runtime"
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"
#define RunValue "LocalFlow"

[Setup]
AppId=org.localflow.LocalFlow
AppName=LocalFlow
AppVersion={#AppVersion}
AppVerName=LocalFlow {#AppVersion} (unsigned build)
AppPublisher=LocalFlow
PrivilegesRequired=lowest
; An x64 binary: arm64 Windows runs it under emulation.
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
DefaultDirName={userpf}\LocalFlow
DefaultGroupName=LocalFlow
DisableProgramGroupPage=yes
; The welcome page carries the unsigned note.
DisableWelcomePage=no
UninstallDisplayIcon={app}\{#ExeName}
CloseApplications=force
RestartApplications=no
OutputDir=..\..\build\installer
OutputBaseFilename=LocalFlow-{#AppVersion}-x64-unsigned-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Messages]
WelcomeLabel2=This installs LocalFlow [name/ver] for your account only, with no administrator prompt.%n%nThis build is unsigned, so Windows SmartScreen may warn about it.

[Tasks]
Name: runatlogin; Description: "Run LocalFlow at login"; Flags: unchecked

[Files]
Source: "..\..\build\rust\release\{#ExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\rust\release\{#WorkerName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SherpaDir}\sherpa-onnx-c-api.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SherpaDir}\onnxruntime.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\LocalFlow"; Filename: "{app}\{#ExeName}"

[Registry]
; The same value Settings writes: the quoted path of the exe.
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "{#RunValue}"; ValueData: """{app}\{#ExeName}"""; Tasks: runatlogin

[Run]
Filename: "{app}\{#ExeName}"; Description: "Open LocalFlow"; Flags: nowait postinstall skipifsilent

; Nothing lists %LOCALAPPDATA%\LocalFlow, so uninstalling keeps recordings, history and settings.
[Code]
procedure CurUninstallStepChanged(Step: TUninstallStep);
begin
  // Settings may have turned this on without the task, so the [Registry] row can't own its removal.
  if Step = usUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, '{#RunKey}', '{#RunValue}');
end;
