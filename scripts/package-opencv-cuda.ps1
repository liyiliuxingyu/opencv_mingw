#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateFile,
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$OutputDir,
    [string]$IsccPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'CUDA SDK packaging requires Windows.' }
$state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
if ($state.toolchain_kind -ne 'msvc' -or $state.configuration -ne 'Release') {
    throw 'This installer distributes the MSVC CUDA Release SDK; use the independent MinGW Debug package for the Debug SDK.'
}
$name = [string]$state.package_name
if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$') { throw 'Invalid package name.' }
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$repo = Split-Path -Parent $PSScriptRoot
function Relative([string]$path) {
    $r = [IO.Path]::GetRelativePath($PackageRoot, [IO.Path]::GetFullPath($path))
    if ([IO.Path]::IsPathRooted($r) -or $r -match '^\.\.(?:[\\/]|$)') { throw "Path is outside SDK: $path" }
    return $r.Replace('\', '/')
}
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false)) }
$bin = (Resolve-Path -LiteralPath $state.opencv_bin_dir).Path
$binRelative = Relative $bin
$cmakeRelative = Relative $state.opencv_cmake_dir
if (-not (Test-Path (Join-Path $state.opencv_cmake_dir 'OpenCVConfig.cmake'))) { throw 'Missing OpenCV CMake package.' }
$vs = & (Join-Path $PSScriptRoot 'enter-msvc.ps1')
$runtime = foreach ($component in @('CRT','OpenMP')) {
    $dirs = @(Get-ChildItem -LiteralPath (Join-Path $vs.redist_root 'x64') -Directory -Filter "Microsoft.VC*.$component")
    if ($dirs.Count -eq 0) { throw "The official MSVC x64 redistributable $component directory is missing." }
    $selected = $dirs | Sort-Object Name -Descending | Select-Object -First 1
    foreach ($dll in Get-ChildItem -LiteralPath $selected.FullName -File -Filter '*.dll') {
        Copy-Item -LiteralPath $dll.FullName -Destination $bin -Force
        [ordered]@{name=$dll.Name; source="Visual Studio x64 redistributable $component"; sha256=(Get-FileHash $dll.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
}
New-Item -ItemType Directory -Force -Path (Join-Path $PackageRoot 'examples') | Out-Null
foreach ($example in @('smoke','cuda','python')) {
    Copy-Item -LiteralPath (Join-Path $repo "examples/$example") -Destination (Join-Path $PackageRoot 'examples') -Recurse -Force
}
$licenses = Join-Path $PackageRoot 'licenses'
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
if ($state.PSObject.Properties['runtime_license_files']) {
    $index = 0
    foreach ($license in $state.runtime_license_files) {
        if (Test-Path -LiteralPath $license -PathType Leaf) {
            $index++
            Copy-Item -LiteralPath $license -Destination (Join-Path $licenses ("runtime-$index-" + [IO.Path]::GetFileName($license)))
        }
    }
}
$lock = Get-Content -LiteralPath $state.lock_file -Raw | ConvertFrom-Json
if ($lock.package_name -ne $name) { throw 'CUDA source lock and state disagree.' }
Copy-Item -LiteralPath $state.lock_file -Destination (Join-Path $PackageRoot 'build-lock.json')
$python = if ($state.PSObject.Properties['python']) { $state.python } else { $null }
$metadata = [ordered]@{
    schema_version=1; package_name=$name; opencv_version=$state.opencv_version
    opencv_commit=$state.opencv_commit; contrib_commit=$state.contrib_commit
    toolchain_kind='msvc'; msvc_version=$state.msvc_version; target='x86_64-pc-windows-msvc'
    configuration='Release'; shared_libraries=$true
    cuda_version=$state.cuda_version; cudnn_version=$state.cudnn_version
    opencv_bin_dir=$binRelative; opencv_cmake_dir=$cmakeRelative
    python_bindings=($null -ne $python); python=$python
    external_cuda_runtime=$true; cuda_python_runtime_packages=$state.cuda_python_runtime_packages
    runtime_dlls_copied=@($runtime)
    gpu_execution='not-tested'; features=@{cuda=$true;cudnn=$true;ffmpeg=$true}
    source_lock='build-lock.json'; packaged_at_utc=[DateTime]::UtcNow.ToString('o')
}
Write-Text (Join-Path $PackageRoot 'build-info.json') ($metadata | ConvertTo-Json -Depth 20)
$activation = @'
@echo off
set "OPENCV_CUDA_ROOT=%~dp0"
set "OpenCV_DIR=%~dp0@CMAKE@"
set "PATH=%~dp0@BIN@;%PATH%"
if defined CUDA_PATH set "PATH=%CUDA_PATH%\bin\x64;%CUDA_PATH%\bin;%PATH%"
if defined CUDNN_PATH set "PATH=%CUDNN_PATH%\bin\x64;%CUDNN_PATH%\bin;%PATH%"
set "CC=cl"
set "CXX=cl"
echo OpenCV CUDA SDK: MSVC x64 Release. Use an x64 Visual Studio 2022 developer command prompt.
echo C++ prerequisites: Visual Studio C++ Build Tools, CMake, Ninja, CUDA @CUDA@ and cuDNN @CUDNN@.
echo Set CUDA_PATH and CUDNN_PATH to their installation roots before calling this file.
echo For Python run install-python.cmd; it creates an isolated environment and installs pinned runtime dependencies.
exit /b 0
'@
$activation = $activation.Replace('@CMAKE@', $cmakeRelative.Replace('/','\')).Replace('@BIN@', $binRelative.Replace('/','\')).Replace('@CUDA@',[string]$state.cuda_version).Replace('@CUDNN@',[string]$state.cudnn_version)
Write-Text (Join-Path $PackageRoot 'activate.cmd') ($activation -replace '\r?\n',"`r`n")
$buildExample = @'
@echo off
setlocal
call "%~dp0activate.cmd"
if errorlevel 1 exit /b 1
set "BUILD_DIR=%LOCALAPPDATA%\OpenCV-SDK\examples\@NAME@"
cmake -S "%~dp0examples\cuda" -B "%BUILD_DIR%" -G Ninja -DCMAKE_BUILD_TYPE=Release -DOpenCV_DIR="%OpenCV_DIR%"
if errorlevel 1 exit /b 1
cmake --build "%BUILD_DIR%" --parallel 2
if errorlevel 1 exit /b 1
"%BUILD_DIR%\opencv_cuda_smoke.exe" "%BUILD_DIR%\results" --expected-version @VERSION@ --expected-configuration Release --require-ffmpeg
if errorlevel 1 exit /b 1
"%BUILD_DIR%\opencv_cuda_device.exe" "%BUILD_DIR%\gpu-verification.json" --require-gpu
exit /b %ERRORLEVEL%
'@
Write-Text (Join-Path $PackageRoot 'build-example.cmd') (($buildExample.Replace('@NAME@',$name).Replace('@VERSION@',[string]$state.opencv_version)) -replace '\r?\n',"`r`n")
$readme = @"
OpenCV $($state.opencv_version) + CUDA $($state.cuda_version) + cuDNN $($state.cudnn_version)
MSVC x64 Release SDK with CPython cv2 bindings

This package uses the Visual Studio C++ ABI. Use it separately from the MinGW SDK.
The package does not install Visual Studio, an NVIDIA driver or the CUDA Toolkit.
For C++: install Visual Studio 2022 C++ Build Tools, CMake/Ninja and the exact CUDA/cuDNN versions above.
Set CUDA_PATH and CUDNN_PATH, then call activate.cmd from an x64 developer command prompt.
Run build-example.cmd on a compatible NVIDIA GPU to compile and execute the GPU checks.

For Python: run install-python.cmd. It requires matching 64-bit CPython and network access.
The included wheel installs exact NVIDIA runtime wheel dependencies into a new isolated virtual environment.
Do not install multiple distributions providing cv2 into the same Python environment.

For OpenCV 5 DNN CUDA, select the classic engine when loading the model:
net = cv2.dnn.readNetFromONNX("model.onnx", engine=cv2.dnn.ENGINE_CLASSIC)
net.setPreferableBackend(cv2.dnn.DNN_BACKEND_CUDA)
net.setPreferableTarget(cv2.dnn.DNN_TARGET_CUDA)
The new OpenCV 5 DNN engine currently supports CPU only. Test your model on the target GPU.

CUDA GPU execution requires a compatible NVIDIA GPU and driver. Build and import checks on a CPU-only CI runner
do not establish GPU correctness or performance. Read verification.json in the Release for actual test coverage.
CUDA architectures, upstream commits and library versions are recorded in build-lock.json.
This package does not include NVIDIA Video Codec SDK functionality (cudacodec), or a Debug Python interpreter.
EXE is not code-signed. Check the release SHA256SUMS before installation.
"@
Write-Text (Join-Path $PackageRoot 'README.txt') $readme
Write-Text (Join-Path $PackageRoot 'LICENSES.txt') @'
OpenCV and contrib retain their original licenses/notices under opencv/.
The source lock identifies exact upstream source revisions.
The copied Microsoft runtime DLLs come only from Visual Studio's x64 redistributable CRT directory;
and OpenMP directories; their original Microsoft license and redistribution terms apply. The MSVC compiler is not bundled.
CUDA/cuDNN runtime wheel dependencies are distributed by NVIDIA, with their own licenses and notices.
Keep the license/notice files supplied by each dependency. This SDK does not relicense those components.
'@
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if (-not $IsccPath) { $IsccPath = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe' }
& $IsccPath "/DPackageDir=$PackageRoot" "/DOutputDir=$OutputDir" "/DPackageName=$name" "/DOpenCVVersion=$($state.opencv_version)" "/DCudaVersion=$($state.cuda_version)" (Join-Path $repo 'packaging/opencv-cuda.iss')
if ($LASTEXITCODE -ne 0) { throw 'CUDA installer compilation failed.' }
$zipPath = Join-Path $OutputDir "$name.zip"
$stream = [IO.File]::Open($zipPath,[IO.FileMode]::CreateNew)
try {
    $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Force | Sort-Object FullName) {
            $entry = $archive.CreateEntry("$name/$(Relative $file.FullName)",[IO.Compression.CompressionLevel]::Optimal)
            $inputStream = [IO.File]::OpenRead($file.FullName)
            try { $out=$entry.Open(); try{$inputStream.CopyTo($out)}finally{$out.Dispose()} } finally{$inputStream.Dispose()}
        }
    } finally {$archive.Dispose()}
} finally {$stream.Dispose()}
$installer = Join-Path $OutputDir "$name-setup.exe"
$infoPath=Join-Path $OutputDir "$name-build-info.json"
$lockPath=Join-Path $OutputDir "$name-build-lock.json"
Copy-Item (Join-Path $PackageRoot 'build-info.json') $infoPath
Copy-Item (Join-Path $PackageRoot 'build-lock.json') $lockPath
$files=@($installer,$zipPath,$infoPath,$lockPath)
foreach($file in $files){if((Get-Item $file).Length -ge 2GB){throw "Release asset exceeds GitHub's 2 GiB limit: $file"}}
$sums=foreach($file in $files){"$((Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($file))"}
Write-Text (Join-Path $OutputDir 'SHA256SUMS') (($sums -join "`n")+"`n")
$result=[ordered]@{
    schema_version=1;package_name=$name;package_root=$PackageRoot;zip_path=$zipPath;installer_path=$installer
    build_info_path=$infoPath;build_lock_path=$lockPath;checksums_path=(Join-Path $OutputDir 'SHA256SUMS')
    opencv_version=$state.opencv_version;configuration='Release';toolchain_kind='msvc'
    msvc_version=$state.msvc_version;cuda_version=$state.cuda_version;cudnn_version=$state.cudnn_version
}
Write-Text (Join-Path $OutputDir 'package-result.json') ($result|ConvertTo-Json -Depth 10)
Write-Host "Created CUDA SDK installer and ZIP: $name"
