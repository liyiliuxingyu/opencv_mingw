#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LockFile,
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release',
    [string]$PythonExecutable,
    [ValidateRange(1, 8)][int]$ParallelJobs = 4,
    [switch]$CleanupBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'This script builds a native Windows x64 package and must run in Windows PowerShell 7.' }

$LockFile = (Resolve-Path -LiteralPath $LockFile).Path
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$lock = Get-Content -LiteralPath $LockFile -Raw | ConvertFrom-Json
if ($lock.schema_version -ne 1) { throw 'Unsupported versions.lock.json schema.' }
$Configuration = if ($Configuration -eq 'Debug') { 'Debug' } else { 'Release' }
$isDebug = $Configuration -eq 'Debug'
$pythonEnabled = -not [string]::IsNullOrWhiteSpace($PythonExecutable)
if ($isDebug -and $pythonEnabled) { throw 'Debug is a separate C++ SDK; cv2 is built with the Release configuration.' }
if ($lock.PSObject.Properties['python_bindings'] -and [bool]$lock.python_bindings -ne $pythonEnabled) {
    throw 'The Python selection differs from the source lock.'
}
if ($lock.PSObject.Properties['configuration'] -and $lock.configuration -ne $Configuration) {
    throw 'The requested configuration differs from the source lock.'
}
if ($isDebug -and $lock.package_name -notmatch '-debug$') {
    throw 'A Debug build requires its own package name ending in -debug.'
}
foreach ($sha in @($lock.opencv_commit, $lock.contrib_commit)) {
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'Source commits must be full 40-character Git SHAs.' }
}
if ($lock.winlibs_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'The toolchain SHA-256 is invalid.' }
if ($lock.opencv_repository -ne 'https://github.com/opencv/opencv.git' -or
    $lock.contrib_repository -ne 'https://github.com/opencv/opencv_contrib.git') {
    throw 'Source repositories must be the official OpenCV repositories.'
}
if (-not ([string]$lock.winlibs_asset_url).StartsWith('https://github.com/brechtsanders/winlibs_mingw/releases/download/', [StringComparison]::Ordinal)) {
    throw 'The toolchain URL must belong to the official WinLibs release repository.'
}
if (Test-Path -LiteralPath $InstallRoot) {
    if (@(Get-ChildItem -LiteralPath $InstallRoot -Force).Count -gt 0) {
        throw "InstallRoot must be absent or empty to prevent mixing old and new SDK files: $InstallRoot"
    }
}

$logRoot = Join-Path $WorkRoot 'logs'
$downloadRoot = Join-Path $WorkRoot 'downloads'
$sourceRoot = Join-Path $WorkRoot 'sources'
$buildRoot = Join-Path $WorkRoot 'build'
$toolchainParent = Join-Path $WorkRoot 'toolchain with spaces'
New-Item -ItemType Directory -Force -Path $WorkRoot, $logRoot, $downloadRoot, $sourceRoot, $InstallRoot | Out-Null

function Invoke-NativeLogged {
    param([string]$File, [string[]]$ArgumentList, [string]$LogName)
    Write-Host "> $File $($ArgumentList -join ' ')"
    & $File @ArgumentList 2>&1 | Tee-Object -FilePath (Join-Path $logRoot $LogName) -Append | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE. See $LogName." }
}

$git = (Get-Command git.exe -ErrorAction Stop).Source
# WinLibs CMake uses GnuTLS and may not discover Windows trust anchors itself.
# Supply a trusted CA bundle explicitly; keep certificate verification enabled.
$gitCaInfo = (& $git config --path --get http.sslCAInfo | Out-String).Trim()
if ($LASTEXITCODE -notin @(0, 1)) { throw 'Could not read the Git HTTPS CA configuration.' }
$gitRoot = Split-Path -Parent (Split-Path -Parent $git)
$caCandidates = @(
    $env:CMAKE_TLS_CAINFO,
    $gitCaInfo,
    (Join-Path $gitRoot 'mingw64/etc/ssl/certs/ca-bundle.crt'),
    (Join-Path $gitRoot 'mingw64/ssl/certs/ca-bundle.crt'),
    (Join-Path $gitRoot 'usr/ssl/certs/ca-bundle.crt')
)
$caSource = $caCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
$caBundle = Join-Path $WorkRoot 'cmake-ca-bundle.pem'
if ($caSource) {
    Copy-Item -LiteralPath $caSource -Destination $caBundle
} else {
    # Minimal Git installations may omit the Mozilla bundle. Reuse Windows trust.
    $roots = @(Get-ChildItem 'Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root' | Sort-Object Thumbprint -Unique)
    if ($roots.Count -eq 0) { throw 'No trusted root certificates are available for CMake HTTPS downloads.' }
    $pem = [Text.StringBuilder]::new()
    foreach ($root in $roots) {
        [void]$pem.AppendLine('-----BEGIN CERTIFICATE-----')
        [void]$pem.AppendLine([Convert]::ToBase64String($root.RawData, [Base64FormattingOptions]::InsertLineBreaks))
        [void]$pem.AppendLine('-----END CERTIFICATE-----')
    }
    [IO.File]::WriteAllText($caBundle, $pem.ToString(), [Text.Encoding]::ASCII)
    $caSource = 'Windows LocalMachine/CurrentUser trusted root stores'
}
"Source: $caSource`nSHA256: $((Get-FileHash -LiteralPath $caBundle -Algorithm SHA256).Hash)" |
    Set-Content (Join-Path $logRoot 'cmake-ca-info.txt') -Encoding utf8NoBOM

$sevenZipCommand = Get-Command 7z.exe -ErrorAction SilentlyContinue
if ($sevenZipCommand) {
    $sevenZip = $sevenZipCommand.Source
} else {
    $sevenZip = Join-Path $env:ProgramFiles '7-Zip/7z.exe'
    if (-not (Test-Path -LiteralPath $sevenZip)) { throw '7-Zip is required to extract the official WinLibs toolchain.' }
}

$toolchainArchive = Join-Path $downloadRoot ([IO.Path]::GetFileName([string]$lock.winlibs_asset_name))
if (-not (Test-Path -LiteralPath $toolchainArchive)) {
    Invoke-WebRequest -Uri $lock.winlibs_asset_url -OutFile $toolchainArchive `
        -MaximumRetryCount 3 -RetryIntervalSec 5 -TimeoutSec 900
}
$actualToolchainHash = (Get-FileHash -LiteralPath $toolchainArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualToolchainHash -ne $lock.winlibs_sha256) { throw "Toolchain SHA-256 mismatch: $toolchainArchive" }
"$actualToolchainHash  $($lock.winlibs_asset_name)" | Set-Content (Join-Path $logRoot 'toolchain-sha256.txt') -Encoding utf8NoBOM
if (Test-Path -LiteralPath $toolchainParent) { throw "Use a fresh WorkRoot; toolchain directory already exists: $toolchainParent" }
New-Item -ItemType Directory -Path $toolchainParent | Out-Null
Invoke-NativeLogged $sevenZip @('x', $toolchainArchive, "-o$toolchainParent", '-y') 'toolchain-extract.log'
$toolchainRoot = Join-Path $toolchainParent 'mingw64'
$toolchainBin = Join-Path $toolchainRoot 'bin'
$cCompiler = Join-Path $toolchainBin 'gcc.exe'
$cxxCompiler = Join-Path $toolchainBin 'g++.exe'
foreach ($exe in @($cCompiler, $cxxCompiler)) {
    if (-not (Test-Path -LiteralPath $exe)) { throw "Expected compiler was not found: $exe" }
}
$env:PATH = "$toolchainBin;$env:PATH"
& (Join-Path $PSScriptRoot 'patch-toolchain.ps1') -ToolchainRoot $toolchainRoot -LogDir $logRoot | Out-Null
$targetTriple = (& $cxxCompiler -dumpmachine | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $targetTriple -ne 'x86_64-w64-mingw32') { throw "Unexpected compiler target: $targetTriple" }
$gccVersion = (& $cxxCompiler -dumpfullversion | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $gccVersion -ne $lock.gcc_version) { throw "Compiler version $gccVersion differs from lock $($lock.gcc_version)." }
Invoke-NativeLogged $cxxCompiler @('-v') 'compiler-version.txt'

# Fail before fetching/building OpenCV if a newly selected compiler cannot be
# relocated. Both the compiler and consumer filenames intentionally have spaces.
$compilerProbe = Join-Path $logRoot 'compiler path probe.cpp'
$compilerProbeExe = Join-Path $logRoot 'compiler path probe.exe'
@'
#include <iostream>
#include <thread>
int main() {
    int value = 0;
    std::thread worker([&] { value = 42; });
    worker.join();
    std::cout << "Compiler path probe: " << value << '\n';
    return value == 42 ? 0 : 1;
}
'@ | Set-Content -LiteralPath $compilerProbe -Encoding utf8NoBOM
Invoke-NativeLogged $cxxCompiler @('-std=c++17', $compilerProbe, '-o', $compilerProbeExe) 'compiler-path-probe.log'
Invoke-NativeLogged -File $compilerProbeExe -ArgumentList @() -LogName 'compiler-path-probe.log'

$cmake = Join-Path $toolchainBin 'cmake.exe'
$ninja = Join-Path $toolchainBin 'ninja.exe'
foreach ($exe in @($cmake, $ninja)) {
    if (-not (Test-Path -LiteralPath $exe)) { throw "The complete WinLibs bundle must provide its build tool: $exe" }
}
Invoke-NativeLogged $cmake @('--version') 'cmake-version.txt'
Invoke-NativeLogged $ninja @('--version') 'ninja-version.txt'
if ($isDebug) {
    foreach ($name in @('objdump.exe', 'gdb.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $toolchainBin $name) -PathType Leaf)) {
            throw "The standalone Debug SDK requires $name from the complete WinLibs bundle."
        }
    }
    Invoke-NativeLogged (Join-Path $toolchainBin 'gdb.exe') @('--version') 'gdb-version.txt'
}
$pythonConfig = $null
if ($pythonEnabled) {
    $PythonExecutable = (Resolve-Path -LiteralPath $PythonExecutable).Path
    $pythonConfig = & (Join-Path $PSScriptRoot 'get-python-build-config.ps1') `
        -PythonExecutable $PythonExecutable -InstallRoot $InstallRoot `
        -WorkRoot (Join-Path $WorkRoot 'python-config') -CxxCompiler $cxxCompiler
    if ($lock.PSObject.Properties['python_version'] -and $lock.python_version -ne $pythonConfig.python.major_minor) {
        throw 'The selected CPython major/minor version differs from the source lock.'
    }
}

function Get-PinnedSource([string]$Name, [string]$Repository, [string]$Commit) {
    $destination = Join-Path $sourceRoot $Name
    if (Test-Path -LiteralPath $destination) { throw "Use a fresh WorkRoot; source directory already exists: $destination" }
    Invoke-NativeLogged $git @('init', $destination) 'sources.log'
    Invoke-NativeLogged $git @('-C', $destination, 'config', 'core.longpaths', 'true') 'sources.log'
    Invoke-NativeLogged $git @('-C', $destination, 'remote', 'add', 'origin', $Repository) 'sources.log'
    Invoke-NativeLogged $git @('-C', $destination, 'fetch', '--depth', '1', 'origin', $Commit) 'sources.log'
    Invoke-NativeLogged $git @('-C', $destination, 'checkout', '--detach', 'FETCH_HEAD') 'sources.log'
    $actualCommit = (& $git -C $destination rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $Commit) { throw "Source commit verification failed for $Name." }
    return $destination
}
$opencvSource = Get-PinnedSource 'opencv' $lock.opencv_repository $lock.opencv_commit
$contribSource = Get-PinnedSource 'opencv_contrib' $lock.contrib_repository $lock.contrib_commit
$downloadCache = Join-Path $WorkRoot 'opencv-download-cache'
$buildWorld = if ($isDebug) { 'OFF' } else { 'ON' }

$options = @(
    '-S', $opencvSource, '-B', $buildRoot, '-G', 'Ninja',
    "-DCMAKE_C_COMPILER=$cCompiler", "-DCMAKE_CXX_COMPILER=$cxxCompiler",
    "-DCMAKE_MAKE_PROGRAM=$ninja", "-DCMAKE_INSTALL_PREFIX=$InstallRoot",
    "-DCMAKE_BUILD_TYPE=$Configuration", '-DCMAKE_CXX_STANDARD=17', '-DCMAKE_CXX_STANDARD_REQUIRED=ON',
    '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
    "-DCMAKE_TLS_CAINFO=$($caBundle.Replace('\', '/'))", '-DCMAKE_TLS_VERIFY=ON',
    "-DOPENCV_EXTRA_MODULES_PATH=$contribSource/modules", "-DOPENCV_DOWNLOAD_PATH=$downloadCache",
    "-DOPENCV_VCSVERSION=$($lock.opencv_version)-$($lock.opencv_commit)",
    '-DBUILD_SHARED_LIBS=ON', "-DBUILD_opencv_world=$buildWorld",
    '-DBUILD_TESTS=OFF', '-DBUILD_PERF_TESTS=OFF', '-DBUILD_EXAMPLES=OFF',
    '-DBUILD_DOCS=OFF', '-DBUILD_opencv_apps=ON', '-DBUILD_JAVA=OFF',
    '-DBUILD_opencv_python2=OFF', '-DBUILD_opencv_python3=OFF',
    '-DINSTALL_C_EXAMPLES=OFF', '-DINSTALL_PYTHON_EXAMPLES=OFF', '-DINSTALL_TESTS=OFF',
    '-DOPENCV_ENABLE_NONFREE=OFF',
    '-DWITH_OPENMP=ON', '-DWITH_TBB=OFF', '-DWITH_PTHREADS_PF=OFF',
    '-DWITH_FFMPEG=ON', '-DWITH_GSTREAMER=OFF', '-DWITH_MSMF=OFF', '-DWITH_DSHOW=ON',
    '-DWITH_OPENCL=ON', '-DWITH_IPP=OFF', '-DWITH_CUDA=OFF', '-DWITH_CUDNN=OFF',
    '-DWITH_DIRECTML=OFF', '-DWITH_OBSENSOR=OFF', '-DWITH_VTK=OFF', '-DWITH_LAPACK=OFF'
)
if ($pythonEnabled) { $options += $pythonConfig.cmake_options }
$options | ConvertTo-Json | Set-Content (Join-Path $logRoot 'cmake-options.json') -Encoding utf8NoBOM
Invoke-NativeLogged $cmake $options 'configure.log'
$configureText = Get-Content (Join-Path $logRoot 'configure.log') -Raw
if ($configureText -notmatch '(?m)FFMPEG:\s+YES\b') {
    throw 'The requested FFmpeg backend was not enabled; inspect configure.log and CMakeDownloadLog.txt.'
}
if ($configureText -notmatch '(?m)Parallel framework:\s+OpenMP\b') {
    throw 'The requested OpenMP backend was not enabled; inspect configure.log.'
}
if ($configureText -notmatch "(?m)Configuration:\s+$Configuration\s*$") {
    throw "OpenCV did not configure the requested $Configuration build."
}
if ($pythonEnabled -and $configureText -notmatch '(?m)To be built:[^\r\n]*\bpython3\b') {
    throw 'The requested Python 3 bindings were not enabled; inspect configure.log.'
}
if ($isDebug) {
    # Preserve the native GNU Debug defaults. Do not strip symbols or substitute
    # a Release/RelWithDebInfo build for this independent Debug SDK.
    $cache = Get-Content -LiteralPath (Join-Path $buildRoot 'CMakeCache.txt') -Raw
    foreach ($language in @('C', 'CXX')) {
        $flagMatch = [regex]::Match($cache, "(?m)^CMAKE_${language}_FLAGS_DEBUG:STRING=(.*)$")
        if (-not $flagMatch.Success -or $flagMatch.Groups[1].Value -notmatch '(?:^|\s)-g(?:2|3)?(?:\s|$)' -or
            $flagMatch.Groups[1].Value -match '(?:^|\s)-g0(?:\s|$)') {
            throw "The GNU $language Debug flags must retain full debug information: $($flagMatch.Value)"
        }
    }
}
Invoke-NativeLogged $cmake @('--build', $buildRoot, '--parallel', "$ParallelJobs") 'build.log'
Invoke-NativeLogged $cmake @('--install', $buildRoot, '--config', $Configuration) 'install.log'
if ($pythonEnabled) {
    $pythonExtensions = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'python/cv2') -Recurse -File -Filter '*.pyd')
    $expectedExtension = 'cv2' + $pythonConfig.python.extension_suffix
    if ($pythonExtensions.Count -ne 1 -or $pythonExtensions[0].Name -ne $expectedExtension) {
        throw "The installed Python extension must be exactly $expectedExtension."
    }
}

$worldDlls = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Filter '*opencv_world*.dll')
$debugDllNames = @()
if ($isDebug) {
    if ($worldDlls.Count -ne 0) { throw 'The standalone Debug SDK must use modular DLLs, not opencv_world.' }
    $debugDlls = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Filter '*opencv_*d.dll' |
        Where-Object { $_.Name -match '^(?:lib)?opencv_[a-z0-9_]+[0-9]+d\.dll$' })
    foreach ($module in @('core', 'imgproc', 'imgcodecs', 'videoio')) {
        $found = @($debugDlls | Where-Object { $_.Name -match "^(?:lib)?opencv_${module}[0-9]+d\.dll$" })
        if ($found.Count -ne 1) { throw "Expected one installed Debug $module DLL, found $($found.Count)." }
        if ($module -eq 'core') { $opencvBinDir = $found[0].DirectoryName }
    }
    $objdump = Join-Path $toolchainBin 'objdump.exe'
    foreach ($dll in $debugDlls) {
        if ($dll.DirectoryName -ne $opencvBinDir) { throw 'Debug module DLLs must share one runtime directory.' }
        $sections = (& $objdump '-h' $dll.FullName 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $sections -notmatch '\.debug_info\b' -or $sections -notmatch '\.debug_line\b') {
            throw "Debug symbols or source line information are missing from $($dll.Name)."
        }
    }
    $debugDllNames = @($debugDlls | ForEach-Object Name | Sort-Object)
    $debugDllNames | Set-Content (Join-Path $logRoot 'debug-symbol-dlls.txt') -Encoding utf8NoBOM
} else {
    if ($worldDlls.Count -ne 1) { throw "Expected exactly one installed Release world DLL, found $($worldDlls.Count)." }
    $opencvBinDir = $worldDlls[0].DirectoryName
}
$configFiles = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Filter 'OpenCVConfig.cmake' |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'OpenCVModules.cmake') })
if ($configFiles.Count -ne 1) { throw "Expected one concrete installed OpenCV CMake package, found $($configFiles.Count)." }
$opencvCMakeDir = $configFiles[0].DirectoryName
if (-not (Test-Path -LiteralPath (Join-Path $opencvCMakeDir "OpenCVModules-$($Configuration.ToLowerInvariant()).cmake"))) {
    throw "The installed CMake package has no $Configuration import configuration."
}

$metadataRoot = Join-Path $InstallRoot 'build-info'
New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null
Copy-Item -LiteralPath $LockFile -Destination (Join-Path $metadataRoot 'versions.lock.json')
foreach ($name in @('toolchain-sha256.txt', 'toolchain-patch.json', 'toolchain-specs.before.txt', 'toolchain-specs.after.txt', 'compiler-version.txt', 'compiler-path-probe.log', 'cmake-version.txt', 'ninja-version.txt', 'cmake-options.json', 'cmake-ca-info.txt', 'configure.log', 'sources.log')) {
    Copy-Item -LiteralPath (Join-Path $logRoot $name) -Destination $metadataRoot
}
foreach ($name in @('CMakeCache.txt', 'CMakeDownloadLog.txt')) {
    $file = Join-Path $buildRoot $name
    if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination $metadataRoot }
}
$configureDiagnostic = Join-Path $buildRoot 'CMakeFiles/CMakeConfigureLog.yaml'
if (Test-Path -LiteralPath $configureDiagnostic) {
    Copy-Item -LiteralPath $configureDiagnostic -Destination $metadataRoot
    Copy-Item -LiteralPath $configureDiagnostic -Destination $logRoot
}
if ($isDebug) {
    foreach ($name in @('debug-symbol-dlls.txt', 'gdb-version.txt')) {
        Copy-Item -LiteralPath (Join-Path $logRoot $name) -Destination $metadataRoot
    }
}
if ($pythonEnabled) {
    Copy-Item -LiteralPath $pythonConfig.config_path -Destination $metadataRoot
    Copy-Item -LiteralPath $pythonConfig.python.pip_report -Destination $metadataRoot
}
if (Test-Path -LiteralPath $downloadCache) {
    $cacheHashLines = foreach ($file in Get-ChildItem -LiteralPath $downloadCache -Recurse -File | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($downloadCache, $file.FullName).Replace('\', '/')
        "$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $relative"
    }
    $cacheHashLines | Set-Content (Join-Path $metadataRoot 'download-cache-sha256.txt') -Encoding utf8NoBOM
}

$state = [ordered]@{
    schema_version = 1
    package_name = $lock.package_name
    opencv_version = $lock.opencv_version
    opencv_commit = $lock.opencv_commit
    contrib_commit = $lock.contrib_commit
    winlibs_version = $lock.winlibs_version
    gcc_version = $gccVersion
    mingw_version = $lock.mingw_version
    compiler_target = $targetTriple
    install_root = $InstallRoot
    toolchain_root = $toolchainRoot
    opencv_bin_dir = $opencvBinDir
    opencv_cmake_dir = $opencvCMakeDir
    cmake_executable = $cmake
    ninja_executable = $ninja
    lock_file = $LockFile
    build_root = $buildRoot
    build_log_dir = $logRoot
    build_tree_removed = [bool]$CleanupBuild
    configuration = $Configuration
    toolchain_kind = 'mingw'
    python_bindings = $pythonEnabled
    python = if ($pythonEnabled) { $pythonConfig.python } else { $null }
    library_layout = if ($isDebug) { 'modular' } else { 'world' }
    debug_symbols = if ($isDebug) { 'embedded-dwarf' } else { 'not-requested' }
    debug_symbol_dlls = $debugDllNames
    requested_parallel_backend = 'OpenMP'
    requested_ffmpeg = $true
    native_smoke_test_completed = $false
}
$statePath = Join-Path $WorkRoot 'build-state.json'
$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
if ($CleanupBuild) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
    Write-Host 'Removed the completed build object tree; installed SDK, sources and diagnostic logs are retained.'
}
if ($env:GITHUB_OUTPUT) { "state_file=$statePath" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
Write-Host "Build installed at $InstallRoot. Package and runtime validation are the next stages."
