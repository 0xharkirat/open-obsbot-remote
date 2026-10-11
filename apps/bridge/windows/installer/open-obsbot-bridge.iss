; Inno Setup script for the Windows bridge. Built by
;   scripts\build-bridge-windows.ps1 -Installer
; which passes /DAppVersion=<pubspec version> and /DBundleDir=<release bundle>.
;
; What it does that a zip cannot:
;   - installs to Program Files with a Start menu entry and an uninstaller
;   - adds the Windows Firewall rule for obsbot-bridge.exe, so phones on the
;     Wi-Fi can connect without the user ever answering a firewall prompt
;     (and removes it on uninstall)
;   - optional "start at login", for a bridge PC that should just be ready
;   - closes a running bridge before upgrading over it
;
; Unsigned, like 7-Zip: SmartScreen shows "Windows protected your PC" until
; the download has reputation; users click More info > Run anyway.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BundleDir
  #define BundleDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\..\..\dist"
#endif

#define AppName "Open OBSBOT Bridge"
#define AppExe "open_obsbot_bridge.exe"
#define BridgeExe "obsbot-bridge.exe"
#define FirewallRule "Open OBSBOT Bridge"

[Setup]
; Never change AppId: it is how upgrades find the installed copy.
AppId={{4F6C76C0-53FE-4732-A71A-112D9A8A61A5}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Open OBSBOT Remote
AppPublisherURL=https://github.com/0xharkirat/open-obsbot-remote
AppSupportURL=https://github.com/0xharkirat/open-obsbot-remote/issues
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Admin, because the firewall rule needs it. Program Files also keeps the
; binaries out of user-writable space.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Open-OBSBOT-Bridge-Setup-{#AppVersion}-x64
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; The app holds this mutex (windows/runner/main.cpp); Setup waits for or
; offers to close it instead of failing on in-use files.
AppMutex=Local\OpenOBSBOTBridge
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked
Name: "startup"; Description: "Start the bridge when I sign in to Windows"; Flags: unchecked

[Files]
; The whole self-contained bundle: runner, obsbot-bridge.exe, libdev.dll,
; w32-pthreads.dll, the VC++ runtime DLLs, data\ and the web remote.
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: startup

[Run]
; Private AND public: venue Wi-Fi (a gurdwara, a church hall) is usually
; classed Public by Windows, and a Private-only rule silently blocks every
; phone there. The bridge is PIN-gated, and the rule is scoped to this one
; program. Delete first so reinstalls do not stack duplicate rules.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FirewallRule}"""; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#FirewallRule}"" dir=in action=allow program=""{app}\{#BridgeExe}"" enable=yes profile=private,public"; Flags: runhidden
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExe}"; Flags: runhidden; RunOnceId: "KillApp"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#BridgeExe}"; Flags: runhidden; RunOnceId: "KillBridge"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FirewallRule}"""; Flags: runhidden; RunOnceId: "DelFirewall"

; Pairing state, sequences and logs in %APPDATA% / %LOCALAPPDATA% are left in
; place on uninstall, so a reinstall keeps every paired phone.
