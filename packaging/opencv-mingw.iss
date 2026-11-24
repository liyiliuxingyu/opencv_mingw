; Compile with scripts/package-opencv.ps1 after building and staging the SDK.
; No system-wide PATH or registry environment variables are changed.
#ifndef PackageDir
  #error PackageDir must point to the staged OpenCV + MinGW package
#endif
#ifndef OutputDir
  #error OutputDir must be supplied
#endif
#ifndef PackageName
  #error PackageName must be supplied
#endif
#ifndef OpenCVVersion
  #error OpenCVVersion must be supplied
#endif
#ifndef GccVersion
  #error GccVersion must be supplied
#endif
#ifndef BuildConfiguration
  #define BuildConfiguration "Release"
#endif
#ifndef PythonEnabled
  #define PythonEnabled 0
#endif
#if BuildConfiguration == "Debug"
  #define ConfigurationSuffix "-Debug"
  #define ConfigurationLabel " (Debug)"
#elif BuildConfiguration == "Release"
  #define ConfigurationSuffix ""
  #define ConfigurationLabel ""
#else
  #error BuildConfiguration must be Release or Debug
#endif
#if PythonEnabled == 1
  #ifndef PythonAbi
    #error PythonAbi must be supplied for Python packages
  #endif
  #define ConfigurationSuffix "-Python-" + PythonAbi
  #define ConfigurationLabel " (Python " + PythonAbi + ")"
#endif

[Setup]
AppId=OpenCVMinGW-{#OpenCVVersion}-GCC-{#GccVersion}-x64-ucrt{#ConfigurationSuffix}
AppName=OpenCV + MinGW-w64{#ConfigurationLabel}
AppVersion={#OpenCVVersion}
AppVerName=OpenCV {#OpenCVVersion} + MinGW-w64 GCC {#GccVersion} (x64 UCRT, {#BuildConfiguration})
AppPublisher=liyiliuxingyu
AppPublisherURL=https://github.com/liyiliuxingyu/opencv_mingw
AppSupportURL=https://github.com/liyiliuxingyu/opencv_mingw/issues
AppUpdatesURL=https://github.com/liyiliuxingyu/opencv_mingw/releases
DefaultDirName={localappdata}\Programs\OpenCV-MinGW\{#PackageName}
DefaultGroupName=OpenCV {#OpenCVVersion} - MinGW GCC {#GccVersion}{#ConfigurationLabel}
UsePreviousAppDir=no
DisableProgramGroupPage=yes
DisableWelcomePage=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible and not arm64
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename={#PackageName}-setup
Compression=lzma2/normal
SolidCompression=yes
LZMANumBlockThreads=2
LZMAUseSeparateProcess=yes
WizardStyle=modern
UninstallDisplayName=OpenCV {#OpenCVVersion} + MinGW-w64 GCC {#GccVersion}{#ConfigurationLabel}
UninstallDisplayIcon={sys}\cmd.exe
CloseApplications=no
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut for the developer command prompt"; Flags: unchecked

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Developer Command Prompt"; Filename: "{cmd}"; Parameters: "/D /K """"{app}\activate.cmd"""""; WorkingDir: "{app}"
Name: "{group}\Readme"; Filename: "{app}\README.txt"; WorkingDir: "{app}"
#if PythonEnabled == 1
Name: "{group}\Install Python cv2"; Filename: "{cmd}"; Parameters: "/D /K """"{app}\install-python.cmd"""""; WorkingDir: "{app}"
#endif
Name: "{group}\Package Folder"; Filename: "{app}"; WorkingDir: "{app}"
Name: "{group}\Uninstall"; Filename: "{uninstallexe}"
Name: "{autodesktop}\OpenCV {#OpenCVVersion} - MinGW Developer Prompt{#ConfigurationLabel}"; Filename: "{cmd}"; Parameters: "/D /K """"{app}\activate.cmd"""""; WorkingDir: "{app}"; Tasks: desktopicon
