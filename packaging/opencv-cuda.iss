#ifndef PackageDir
  #error PackageDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef PackageName
  #error PackageName is required
#endif
#ifndef OpenCVVersion
  #error OpenCVVersion is required
#endif
#ifndef CudaVersion
  #error CudaVersion is required
#endif
[Setup]
AppId=OpenCVCuda-{#PackageName}
AppName=OpenCV CUDA SDK (MSVC)
AppVersion={#OpenCVVersion}
AppVerName=OpenCV {#OpenCVVersion} CUDA {#CudaVersion} (MSVC x64)
AppPublisher=liyiliuxingyu
AppPublisherURL=https://github.com/liyiliuxingyu/opencv_mingw
DefaultDirName={localappdata}\Programs\OpenCV-CUDA\{#PackageName}
DefaultGroupName=OpenCV CUDA {#OpenCVVersion} - {#CudaVersion}
UsePreviousAppDir=no
DisableProgramGroupPage=yes
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
CloseApplications=no
RestartApplications=no
SetupLogging=yes
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Developer Command Prompt"; Filename: "{cmd}"; Parameters: "/D /K """"{app}\activate.cmd"""""; WorkingDir: "{app}"
Name: "{group}\Install Python cv2 in an isolated environment"; Filename: "{cmd}"; Parameters: "/D /K """"{app}\install-python.cmd"""""; WorkingDir: "{app}"
Name: "{group}\Readme"; Filename: "{app}\README.txt"
Name: "{group}\Uninstall"; Filename: "{uninstallexe}"
