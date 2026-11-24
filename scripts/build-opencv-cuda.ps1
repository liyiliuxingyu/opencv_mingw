#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LockFile,
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release',
    [string]$PythonExecutable,
    [ValidateSet('3.12', '3.13', '3.14')][string]$PythonVersion = '3.13',
    [ValidatePattern('^13\.\d+\.\d+$')][string]$CudaVersion = '13.5.0',
    [ValidatePattern('^9\.\d+\.\d+$')][string]$CudnnVersion = '9.28.1',
    [string]$CudaArchBin = '7.5;8.0;8.6;8.9;9.0',
    [string]$CudaArchPtx = '9.0',
    [string]$CudaStateFile,
    [switch]$CleanupBuild,
    [ValidateRange(1, 8)][int]$ParallelJobs = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'CUDA builds require native Windows x64 and MSVC.' }
$LockFile = (Resolve-Path -LiteralPath $LockFile).Path
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$sourceLock = Get-Content -LiteralPath $LockFile -Raw | ConvertFrom-Json
if ($sourceLock.schema_version -ne 1) { throw 'Unsupported source lock schema.' }
if ($sourceLock.opencv_version -notmatch '^\d+\.\d+\.\d+$') { throw 'A stable OpenCV version is required.' }
foreach ($sha in @($sourceLock.opencv_commit, $sourceLock.contrib_commit)) {
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'OpenCV and contrib must be pinned to full commit hashes.' }
}
if ($sourceLock.opencv_repository -ne 'https://github.com/opencv/opencv.git' -or
    $sourceLock.contrib_repository -ne 'https://github.com/opencv/opencv_contrib.git') {
    throw 'Source repositories must be the official OpenCV repositories.'
}
foreach ($path in @($InstallRoot, (Join-Path $WorkRoot 'build'), (Join-Path $WorkRoot 'sources'))) {
    if ((Test-Path -LiteralPath $path) -and @(Get-ChildItem -LiteralPath $path -Force).Count -gt 0) {
        throw "Use a fresh build/install directory to keep MSVC and MinGW files separate: $path"
    }
}
$logRoot = Join-Path $WorkRoot 'logs'
$buildRoot = Join-Path $WorkRoot 'build'
$sourceRoot = Join-Path $WorkRoot 'sources'
New-Item -ItemType Directory -Force -Path $WorkRoot, $logRoot, $sourceRoot, $InstallRoot | Out-Null

function Invoke-NativeLogged {
    param([string]$File, [string[]]$ArgumentList, [string]$LogName)
    Write-Host "> $File $($ArgumentList -join ' ')"
    & $File @ArgumentList 2>&1 | Tee-Object -FilePath (Join-Path $logRoot $LogName) -Append | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE. See $LogName." }
}

function Get-CudaArchitectures([string]$Value, [string]$Name) {
    $architectures = @($Value -split '[;,\s]+' | Where-Object { $_ } | Select-Object -Unique)
    if ($architectures.Count -eq 0) { throw "$Name must contain explicit compute capabilities." }
    foreach ($arch in $architectures) {
        if ($arch -notmatch '^\d+\.\d$' -or [version]$arch -lt [version]'7.5') {
            throw "$Name contains unsupported '$arch'. CUDA 13 requires compute capability 7.5 or newer."
        }
    }
    return $architectures
}

function Get-CacheValue([string]$Name, [string]$Text) {
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + ':[^=]+=(.*)\r?$')
    if (-not $match.Success) { throw "CMake did not cache the required setting: $Name" }
    return $match.Groups[1].Value.Trim()
}

$binArchitectures = @(Get-CudaArchitectures $CudaArchBin 'CudaArchBin')
$ptxArchitectures = @(Get-CudaArchitectures $CudaArchPtx 'CudaArchPtx')
$CudaArchBin = $binArchitectures -join ';'
$CudaArchPtx = $ptxArchitectures -join ';'

# Do not mix GCC's C++ ABI with CUDA's supported Windows host compiler.
# enter-msvc captures vcvars output privately rather than printing environment
# variables, which can contain Actions credentials.
$msvc = & (Join-Path $PSScriptRoot 'enter-msvc.ps1')
$compiler = [string]$msvc.compiler
$cmake = (Get-Command cmake.exe -ErrorAction Stop).Source
$ninja = (Get-Command ninja.exe -ErrorAction Stop).Source
$git = (Get-Command git.exe -ErrorAction Stop).Source
$msvc | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $logRoot 'msvc-toolchain.json') -Encoding utf8NoBOM
Invoke-NativeLogged $cmake @('--version') 'cmake-version.txt'
Invoke-NativeLogged $ninja @('--version') 'ninja-version.txt'

$pythonEnabled = $Configuration -eq 'Release'
$python = $null
$pythonInfo = $null
$pythonBuild = $null
if ($pythonEnabled) {
    if (-not $PythonExecutable) { $PythonExecutable = (Get-Command python.exe -ErrorAction Stop).Source }
    $python = (Resolve-Path -LiteralPath $PythonExecutable).Path
    $pythonBuild = & (Join-Path $PSScriptRoot 'get-python-build-config.ps1') -PythonExecutable $python `
        -InstallRoot $InstallRoot -WorkRoot (Join-Path $WorkRoot 'python-build')
    $pythonInfo = $pythonBuild.python
    if ($pythonInfo.major_minor -ne $PythonVersion) { throw "Expected CPython $PythonVersion, found $($pythonInfo.major_minor)." }
    $pythonInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot 'python-build.json') -Encoding utf8NoBOM
}

if ($CudaStateFile) {
    $cuda = Get-Content -LiteralPath $CudaStateFile -Raw | ConvertFrom-Json
} else {
    $cuda = & (Join-Path $PSScriptRoot 'install-cuda-toolkit.ps1') -WorkRoot (Join-Path $WorkRoot 'cuda-toolkit') `
        -CudaVersion $CudaVersion -CudnnVersion $CudnnVersion
}
if ($cuda.cuda_version -ne $CudaVersion -or $cuda.cudnn_version -ne $CudnnVersion) {
    throw 'The prepared CUDA/cuDNN versions do not match the requested build.'
}
$nvcc = [string]$cuda.nvcc_executable
if (-not (Test-Path -LiteralPath $nvcc -PathType Leaf)) { throw "NVCC was not found: $nvcc" }
$env:CUDA_PATH = [string]$cuda.cuda_root
$env:CUDACXX = $nvcc
$env:PATH = (@((Join-Path $cuda.cuda_root 'bin')) + @($cuda.runtime_bin_dirs) + @($env:PATH)) -join ';'
Invoke-NativeLogged $nvcc @('--version') 'nvcc-version.txt'
$nvccVersionText = Get-Content -LiteralPath (Join-Path $logRoot 'nvcc-version.txt') -Raw
$cudaMajorMinor = ($CudaVersion -split '\.')[0..1] -join '.'
if ($nvccVersionText -notmatch ('release\s+' + [regex]::Escape($cudaMajorMinor) + '(?:,|\s)')) {
    throw 'NVCC reported a different CUDA release than the pinned toolkit.'
}
$nvccVersionMatch = [regex]::Match($nvccVersionText, '\bV(\d+\.\d+\.\d+)\b')
if (-not $nvccVersionMatch.Success -or $nvccVersionMatch.Groups[1].Value -ne $cuda.cuda_nvcc_version) {
    throw 'NVCC component version disagrees with the exact CUDA dependency lock.'
}
$actualNvccVersion = $nvccVersionMatch.Groups[1].Value
$supportedCode = (& $nvcc '--list-gpu-code' | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'NVCC cannot enumerate supported binary GPU architectures.' }
$supportedPtx = (& $nvcc '--list-gpu-arch' | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'NVCC cannot enumerate supported PTX architectures.' }
foreach ($arch in $binArchitectures) {
    if ($supportedCode -notmatch ('(?m)^\s*sm_' + $arch.Replace('.', '') + '\s*$')) { throw "NVCC does not support requested binary architecture $arch" }
}
foreach ($arch in $ptxArchitectures) {
    if ($supportedPtx -notmatch ('(?m)^\s*compute_' + $arch.Replace('.', '') + '\s*$')) { throw "NVCC does not support requested PTX architecture $arch" }
}
@{ binary = $binArchitectures; ptx = $ptxArchitectures; available_binary = $supportedCode; available_ptx = $supportedPtx } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot 'cuda-architectures.json') -Encoding utf8NoBOM

# Fail early on unsupported MSVC, missing NVVM/CCCL, or linker setup. Compiling
# a kernel does not require a GPU. This executable is intentionally not run.
$preflightRoot = Join-Path $WorkRoot 'nvcc preflight'
New-Item -ItemType Directory -Force -Path $preflightRoot | Out-Null
$preflightSource = Join-Path $preflightRoot 'compiler check.cu'
@'
#include <cuda_runtime.h>
#include <thrust/tuple.h>
__global__ void compiler_check(int* output) { *output = 7; }
int main() { thrust::tuple<int> value(7); return thrust::get<0>(value) == 7 ? 0 : 1; }
'@ | Set-Content -LiteralPath $preflightSource -Encoding utf8NoBOM
$ccclInclude = Join-Path $cuda.cuda_root 'include/cccl'
# CCCL requires MSVC's standard conforming preprocessor in both CUDA host
# phases and ordinary C++ translation units that include its headers.
Invoke-NativeLogged $nvcc @('--std=c++17', '--compiler-bindir', (Split-Path -Parent $compiler),
    '-Xcompiler=/Zc:preprocessor', '--cudart', 'shared', '-I', $ccclInclude,
    ('-arch=sm_' + $binArchitectures[0].Replace('.', '')),
    $preflightSource, '-o', (Join-Path $preflightRoot 'compiler check.exe')) 'nvcc-preflight.log'
if (-not (Test-Path -LiteralPath (Join-Path $preflightRoot 'compiler check.exe'))) { throw 'NVCC preflight produced no executable.' }

# Keep HTTPS verification enabled for OpenCV's third-party source downloads.
$caBundle = Join-Path $WorkRoot 'cmake-ca-bundle.pem'
$certificates = @(Get-ChildItem 'Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root' | Sort-Object Thumbprint -Unique)
if ($certificates.Count -eq 0) { throw 'No trusted Windows certificate roots are available.' }
$pem = [Text.StringBuilder]::new()
foreach ($certificate in $certificates) {
    [void]$pem.AppendLine('-----BEGIN CERTIFICATE-----')
    [void]$pem.AppendLine([Convert]::ToBase64String($certificate.RawData, [Base64FormattingOptions]::InsertLineBreaks))
    [void]$pem.AppendLine('-----END CERTIFICATE-----')
}
[IO.File]::WriteAllText($caBundle, $pem.ToString(), [Text.Encoding]::ASCII)

function Get-PinnedSource([string]$Name, [string]$Repository, [string]$Commit) {
    $destination = Join-Path $sourceRoot $Name
    Invoke-NativeLogged $git @('init', $destination) 'sources.log'
    Invoke-NativeLogged $git @('-C', $destination, 'config', 'core.longpaths', 'true') 'sources.log'
    Invoke-NativeLogged $git @('-C', $destination, 'remote', 'add', 'origin', $Repository) 'sources.log'
    Invoke-NativeLogged $git @('-C', $destination, 'fetch', '--depth', '1', 'origin', $Commit) 'sources.log'
    Invoke-NativeLogged $git @('-C', $destination, 'checkout', '--detach', 'FETCH_HEAD') 'sources.log'
    $actual = (& $git '-C' $destination 'rev-parse' 'HEAD' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $Commit) { throw "Source verification failed for $Name" }
    return $destination
}
$opencvSource = Get-PinnedSource 'opencv' $sourceLock.opencv_repository $sourceLock.opencv_commit
$contribSource = Get-PinnedSource 'contrib' $sourceLock.contrib_repository $sourceLock.contrib_commit
# OpenCV reparses some cache values in generated CMake code. Forward slashes
# prevent native Windows paths from becoming invalid escapes such as \h.
$cmakeCcclInclude = $ccclInclude.Replace('\', '/')
$options = @(
    '-S', $opencvSource, '-B', $buildRoot, '-G', 'Ninja',
    "-DCMAKE_MAKE_PROGRAM=$($ninja.Replace('\', '/'))",
    "-DCMAKE_C_COMPILER=$($compiler.Replace('\', '/'))", "-DCMAKE_CXX_COMPILER=$($compiler.Replace('\', '/'))",
    "-DCMAKE_CUDA_COMPILER=$($nvcc.Replace('\', '/'))", "-DCMAKE_CUDA_HOST_COMPILER=$($compiler.Replace('\', '/'))",
    "-DCUDAToolkit_ROOT=$($cuda.cuda_root.Replace('\', '/'))", "-DCUDA_PATH=$($cuda.cuda_root.Replace('\', '/'))",
    "-DCMAKE_INSTALL_PREFIX=$($InstallRoot.Replace('\', '/'))", "-DCMAKE_BUILD_TYPE=$Configuration",
    '-DCMAKE_CXX_STANDARD=17', '-DCMAKE_CUDA_STANDARD=17', '-DCMAKE_CXX_STANDARD_REQUIRED=ON',
    "-DCMAKE_CUDA_FLAGS_INIT=-Xcompiler=/Zc:preprocessor -I`"$cmakeCcclInclude`"",
    "-DCMAKE_CXX_FLAGS_INIT=/Zc:preprocessor /I`"$cmakeCcclInclude`"",
    '-DCMAKE_CUDA_RUNTIME_LIBRARY=Shared', '-DBUILD_WITH_STATIC_CRT=OFF',
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded$<$<CONFIG:Debug>:Debug>DLL',
    '-DCMAKE_DEBUG_POSTFIX=d', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
    "-DCMAKE_TLS_CAINFO=$($caBundle.Replace('\', '/'))", '-DCMAKE_TLS_VERIFY=ON',
    "-DOPENCV_EXTRA_MODULES_PATH=$($contribSource.Replace('\', '/'))/modules",
    "-DOPENCV_DOWNLOAD_PATH=$($WorkRoot.Replace('\', '/'))/opencv-download-cache",
    "-DOPENCV_VCSVERSION=$($sourceLock.opencv_version)-$($sourceLock.opencv_commit)",
    '-DWITH_CUDA=ON', '-DENABLE_CUDA_FIRST_CLASS_LANGUAGE=ON', '-DWITH_CUBLAS=ON', '-DWITH_CUFFT=ON',
    '-DWITH_CUDNN=ON', '-DWITH_CUDNNJIT=OFF', '-DOPENCV_DNN_CUDA=ON', '-DCUDA_ENABLE_DELAYLOAD=ON',
    "-DCUDNN_INCLUDE_DIR=$($cuda.cudnn_include_dir.Replace('\', '/'))", "-DCUDNN_LIBRARY=$($cuda.cudnn_library.Replace('\', '/'))",
    "-DCUDA_ARCH_BIN=$CudaArchBin", "-DCUDA_ARCH_PTX=$CudaArchPtx",
    '-DWITH_NVCUVID=OFF', '-DWITH_NVCUVENC=OFF', '-DBUILD_opencv_cudacodec=OFF',
    '-DBUILD_SHARED_LIBS=ON', '-DBUILD_opencv_world=OFF', '-DBUILD_TESTS=OFF', '-DBUILD_PERF_TESTS=OFF',
    '-DBUILD_EXAMPLES=OFF', '-DBUILD_DOCS=OFF', '-DBUILD_JAVA=OFF', '-DBUILD_opencv_python2=OFF',
    '-DINSTALL_C_EXAMPLES=OFF', '-DINSTALL_PYTHON_EXAMPLES=OFF', '-DINSTALL_TESTS=OFF',
    '-DOPENCV_ENABLE_NONFREE=OFF', '-DWITH_OPENMP=ON', '-DWITH_TBB=OFF', '-DWITH_PTHREADS_PF=OFF',
    '-DWITH_FFMPEG=ON', '-DWITH_GSTREAMER=OFF', '-DWITH_MSMF=OFF', '-DWITH_DSHOW=ON',
    '-DWITH_OPENCL=ON', '-DWITH_IPP=OFF', '-DWITH_DIRECTML=OFF', '-DWITH_OBSENSOR=OFF', '-DWITH_VTK=OFF', '-DWITH_LAPACK=OFF'
)
if ($pythonEnabled) {
    $options += @($pythonBuild.cmake_options)
} else {
    # Normal python.exe uses the release ABI and cannot consume a /MDd binding.
    $options += '-DBUILD_opencv_python3=OFF'
}
$options | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot 'cmake-options.json') -Encoding utf8NoBOM
Invoke-NativeLogged $cmake $options 'configure.log'
$configureText = Get-Content -LiteralPath (Join-Path $logRoot 'configure.log') -Raw
$cacheText = Get-Content -LiteralPath (Join-Path $buildRoot 'CMakeCache.txt') -Raw
foreach ($pattern in @('(?m)NVIDIA CUDA:\s+YES\b', '(?m)cuDNN:\s+YES\b', '(?m)FFMPEG:\s+YES\b')) {
    if ($configureText -notmatch $pattern) { throw "The configured build lacks a required feature: $pattern" }
}
foreach ($name in @('CMAKE_CUDA_COMPILER', 'CUDNN_LIBRARY', 'CUDNN_INCLUDE_DIR', 'CUDA_cublas_LIBRARY', 'CUDA_cufft_LIBRARY')) {
    $detectedPath = Get-CacheValue $name $cacheText
    if ($detectedPath -match 'NOTFOUND' -or -not (Test-Path -LiteralPath $detectedPath)) {
        throw "CMake did not resolve the required CUDA dependency: $name=$detectedPath"
    }
}
if ((Get-CacheValue 'CMAKE_BUILD_TYPE' $cacheText) -ne $Configuration) { throw 'CMake selected an unexpected configuration.' }
if ((Get-CacheValue 'OPENCV_DNN_CUDA' $cacheText) -ne 'ON') { throw 'The DNN CUDA backend was not enabled.' }
if ((Get-CacheValue 'CUDNN_VERSION' $cacheText) -ne $CudnnVersion) { throw 'CMake detected a different cuDNN version.' }
$configuredHeader = Get-Content -LiteralPath (Join-Path $buildRoot 'cvconfig.h') -Raw
foreach ($feature in @('HAVE_CUDA', 'HAVE_CUDNN')) {
    if ($configuredHeader -notmatch ('(?m)^#define\s+' + $feature + '\b')) { throw "Generated cvconfig.h does not enable $feature" }
}
$compilerFiles = @(Get-ChildItem -LiteralPath (Join-Path $buildRoot 'CMakeFiles') -Recurse -File -Filter 'CMakeCXXCompiler.cmake')
if (-not ($compilerFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'set\(CMAKE_CXX_COMPILER_ID "MSVC"\)' })) {
    throw 'The configured host compiler is not MSVC.'
}
if ($pythonEnabled -and $configureText -notmatch '(?m)To be built:\s+[^\r\n]*\bpython3\b') {
    throw 'OpenCV did not enable the Python 3 module despite the requested settings.'
}
Invoke-NativeLogged $cmake @('--build', $buildRoot, '--parallel', "$ParallelJobs") 'build.log'
Invoke-NativeLogged $cmake @('--install', $buildRoot, '--config', $Configuration) 'install.log'

$coreDlls = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Filter 'opencv_core*.dll')
if ($coreDlls.Count -ne 1) { throw 'Expected exactly one installed core DLL for the selected configuration.' }
if (($Configuration -eq 'Debug') -ne ($coreDlls[0].BaseName -match 'd$')) { throw 'The installed DLL debug postfix disagrees with its configuration.' }
$opencvBin = $coreDlls[0].DirectoryName
$configs = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Filter 'OpenCVConfig.cmake' |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'OpenCVModules.cmake') })
if ($configs.Count -ne 1) { throw 'Expected one concrete MSVC OpenCV CMake package.' }
$pythonExtensions = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Filter 'cv2*.pyd')
if ($pythonEnabled -and $pythonExtensions.Count -ne 1) { throw 'Expected exactly one installed Release Python extension.' }

$packageName = "opencv-$($sourceLock.opencv_version)-msvc-cuda-$CudaVersion-cudnn-$CudnnVersion-x64"
if ($Configuration -eq 'Debug') { $packageName += '-debug' } else { $packageName += '-py' + $PythonVersion.Replace('.', '') }
$cudaLock = Get-Content -LiteralPath $cuda.lock_file -Raw | ConvertFrom-Json
$buildLock = [ordered]@{
    schema_version = 1
    package_name = $packageName
    opencv_version = $sourceLock.opencv_version
    opencv_repository = $sourceLock.opencv_repository
    opencv_commit = $sourceLock.opencv_commit
    contrib_repository = $sourceLock.contrib_repository
    contrib_commit = $sourceLock.contrib_commit
    toolchain_kind = 'msvc'
    msvc_version = $msvc.compiler_version
    msvc_toolset_version = $msvc.toolset_version
    configuration = $Configuration
    python_bindings = $pythonEnabled
    python_version = if ($pythonEnabled) { $PythonVersion } else { $null }
    python_full_version = if ($pythonEnabled) { $pythonInfo.version } else { $null }
    numpy_version = if ($pythonEnabled) { $pythonInfo.numpy_version } else { $null }
    cuda_version = $CudaVersion
    cuda_compiler_version = $actualNvccVersion
    cudnn_version = $CudnnVersion
    cuda_arch_bin = $binArchitectures
    cuda_arch_ptx = $ptxArchitectures
    cuda_dependencies = $cudaLock
    cuda_gpu_execution_tested = $false
    cuda_gpu_execution_status = 'not-tested-no-GPU-execution-in-this-build'
}
$buildLockPath = Join-Path $WorkRoot 'build-lock.json'
$buildLock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $buildLockPath -Encoding utf8NoBOM
$metadataRoot = Join-Path $InstallRoot 'build-info'
New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null
Copy-Item -LiteralPath $buildLockPath -Destination (Join-Path $metadataRoot 'versions.lock.json')
Copy-Item -LiteralPath $cuda.lock_file -Destination $metadataRoot
foreach ($name in @('msvc-toolchain.json', 'cmake-version.txt', 'ninja-version.txt', 'nvcc-version.txt',
                    'nvcc-preflight.log', 'cuda-architectures.json', 'cmake-options.json', 'configure.log', 'sources.log', 'python-build.json')) {
    $path = Join-Path $logRoot $name
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $metadataRoot }
}
Copy-Item -LiteralPath (Join-Path $buildRoot 'CMakeCache.txt') -Destination $metadataRoot
Copy-Item -LiteralPath (Join-Path $buildRoot 'CMakeCache.txt') -Destination $logRoot
Copy-Item -LiteralPath (Join-Path $buildRoot 'cvconfig.h') -Destination $metadataRoot
if ($pythonEnabled) {
    Copy-Item -LiteralPath $pythonBuild.config_path, $pythonInfo.pip_report -Destination $metadataRoot
}

$msvcRuntimeDirs = @()
$runtimeLicenses = @()
if ($msvc.redist_root -and (Test-Path -LiteralPath $msvc.redist_root)) {
    $msvcRuntimeDirs = @(Get-ChildItem -LiteralPath (Join-Path $msvc.redist_root 'x64') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Microsoft.VC*.CRT' -or $_.Name -like 'Microsoft.VC*.OpenMP' } |
        Sort-Object Name | ForEach-Object { $_.FullName })
    $runtimeLicenses = @(Get-ChildItem -LiteralPath $msvc.redist_root -Recurse -File |
        Where-Object { $_.Name -match '(?i)^(license|notice|copying)' } | ForEach-Object { $_.FullName })
}
$vsLicense = Join-Path $msvc.installation_root 'Common7/IDE/1033/License.rtf'
if (Test-Path -LiteralPath $vsLicense -PathType Leaf) { $runtimeLicenses += $vsLicense }
$externalDlls = @($cuda.runtime_bin_dirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -File -Filter '*.dll' } |
    ForEach-Object { $_.Name } | Sort-Object -Unique)
$state = [ordered]@{
    schema_version = 1
    package_name = $packageName
    opencv_version = $sourceLock.opencv_version
    opencv_commit = $sourceLock.opencv_commit
    contrib_commit = $sourceLock.contrib_commit
    toolchain_kind = 'msvc'
    msvc_version = $msvc.compiler_version
    msvc_toolset_version = $msvc.toolset_version
    compiler_target = 'x86_64-pc-windows-msvc'
    compiler_executable = $compiler
    vcvars_path = $msvc.vcvars_path
    dumpbin_executable = $msvc.dumpbin
    install_root = $InstallRoot
    toolchain_root = $msvc.installation_root
    opencv_bin_dir = $opencvBin
    opencv_cmake_dir = $configs[0].DirectoryName
    cmake_executable = $cmake
    ninja_executable = $ninja
    lock_file = $buildLockPath
    source_lock_file = $LockFile
    build_root = $buildRoot
    build_log_dir = $logRoot
    configuration = $Configuration
    requested_parallel_backend = 'OpenMP'
    requested_ffmpeg = $true
    python_bindings = $pythonEnabled
    python = $pythonInfo
    python_version = if ($pythonEnabled) { $PythonVersion } else { $null }
    python_executable = $python
    python_numpy_version = if ($pythonEnabled) { $pythonInfo.numpy_version } else { $null }
    python_install_dir = if ($pythonEnabled) { Join-Path $InstallRoot 'python' } else { $null }
    python_extension = if ($pythonEnabled) { $pythonExtensions[0].FullName } else { $null }
    cuda_version = $CudaVersion
    cuda_compiler_version = $actualNvccVersion
    cudnn_version = $CudnnVersion
    cudnn_component_version = $cuda.cudnn_component_version
    cuda_root = $cuda.cuda_root
    cudnn_root = $cuda.cudnn_root
    cuda_runtime_bin_dirs = @($cuda.runtime_bin_dirs)
    cuda_python_runtime_packages = $cuda.python_runtime_packages
    external_runtime_packages = $cuda.python_runtime_packages
    external_runtime_prefixes = @('cudart64_', 'cublas64_', 'cublasLt64_', 'cufft64_', 'curand64_', 'npp', 'nvrtc64_', 'nvrtc-builtins64_', 'nvJitLink_', 'cudnn')
    external_runtime_dlls = $externalDlls
    runtime_directories = @($msvcRuntimeDirs) + @($cuda.runtime_bin_dirs)
    runtime_license_files = $runtimeLicenses
    cuda_arch_bin = $binArchitectures
    cuda_arch_ptx = $ptxArchitectures
    cuda_host_compile_verified = $true
    cuda_gpu_execution_tested = $false
    cuda_gpu_execution_status = 'not-tested-no-GPU-execution-in-this-build'
    native_smoke_test_completed = $false
}
$statePath = Join-Path $WorkRoot 'build-state.json'
$state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
if ($env:GITHUB_OUTPUT) {
    "state_file=$statePath" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "package_name=$packageName" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
Write-Host "MSVC CUDA $Configuration SDK installed at $InstallRoot. GPU execution has not been tested."
if ($CleanupBuild) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
    Write-Host 'Removed the CUDA object/build tree after preserving installation and build diagnostics.'
}
