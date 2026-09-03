; Inno Setup script for the MediaHub Windows installer.
;
; Built by .github/workflows/windows-build.yml after `flutter build windows
; --release`, and attached to every tagged GitHub Release alongside the
; portable zip. Compile locally with:
;
;   iscc /DMyAppVersion=0.5.0 windows\installer\mediahub.iss
;
; The version is passed in rather than hard-coded here, so pubspec.yaml stays
; the single place a release number is written down.

#define MyAppName "MediaHub"
#define MyAppPublisher "MediaHub"
#define MyAppURL "https://github.com/Moka143/mediahub"
#define MyAppExeName "mediahub.exe"

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
; Never change AppId. Windows identifies an installed app by it, so a new
; value would install alongside the old copy instead of upgrading it, leaving
; two entries in Apps & Features and two Start Menu shortcuts.
AppId={{8F3A1C2E-5B47-4D9A-9E14-7C2B6A0F3D58}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
VersionInfoVersion={#MyAppVersion}

; Per-user install, deliberately. `lowest` puts the app under
; %LOCALAPPDATA%\Programs and skips the UAC prompt entirely — which matters
; more than usual here, because the installer is unsigned and users already
; have to click past SmartScreen. Asking them to approve an admin prompt for
; an unrecognised publisher on top of that is a step too many. Nothing in the
; app needs to write outside the user profile.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes

; The app is x64-only: media_kit ships x64 libmpv and the Flutter build is
; x64. Without this, the installer would happily run on ARM64/x86 and produce
; something that cannot start.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Offer to shut a running copy down rather than failing on locked files,
; which is what an in-place upgrade would otherwise hit.
CloseApplications=yes
RestartApplications=no

SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir=..\..\build\windows\installer
OutputBaseFilename=mediahub-{#MyAppVersion}-windows-setup
; No LicenseFile: the README says MIT but the repository has no LICENSE file,
; and pointing at a missing one fails the compile. Add `LicenseFile=..\..\LICENSE`
; here once that file exists, to show the terms during install.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Flutter release output: the exe, the plugin DLLs, libmpv, and the
; data/ tree with the Flutter assets. recursesubdirs is not optional — the
; app will not start without data\.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Flutter and media_kit drop caches next to the executable at runtime; leave
; nothing behind. The user's settings and credentials live in
; %APPDATA%\MediaHub and under DPAPI, and are deliberately kept — an
; uninstall/reinstall cycle should not sign anyone out.
Type: filesandordirs; Name: "{app}"
