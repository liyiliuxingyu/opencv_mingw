#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LockFile,
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [ValidateRange(1, 8)][int]$ParallelJobs = 4
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
$toolchainParent = Join-Path $WorkRoot 'toolchain'
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
$targetTriple = (& $cxxCompiler -dumpmachine | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $targetTriple -ne 'x86_64-w64-mingw32') { throw "Unexpected compiler target: $targetTriple" }
$gccVersion = (& $cxxCompiler -dumpfullversion | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $gccVersion -ne $lock.gcc_version) { throw "Compiler version $gccVersion differs from lock $($lock.gcc_version)." }
Invoke-NativeLogged $cxxCompiler @('-v') 'compiler-version.txt'

$cmake = Join-Path $toolchainBin 'cmake.exe'
$ninja = Join-Path $toolchainBin 'ninja.exe'
foreach ($exe in @($cmake, $ninja)) {
    if (-not (Test-Path -LiteralPath $exe)) { throw "The complete WinLibs bundle must provide its build tool: $exe" }
}
Invoke-NativeLogged $cmake @('--version') 'cmake-version.txt'
Invoke-NativeLogged $ninja @('--version') 'ninja-version.txt'

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

$options = @(
    '-S', $opencvSource, '-B', $buildRoot, '-G', 'Ninja',
    "-DCMAKE_C_COMPILER=$cCompiler", "-DCMAKE_CXX_COMPILER=$cxxCompiler",
    "-DCMAKE_MAKE_PROGRAM=$ninja", "-DCMAKE_INSTALL_PREFIX=$InstallRoot",
    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_STANDARD=17', '-DCMAKE_CXX_STANDARD_REQUIRED=ON',
    '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
    "-DCMAKE_TLS_CAINFO=$($caBundle.Replace('\', '/'))", '-DCMAKE_TLS_VERIFY=ON',
    "-DOPENCV_EXTRA_MODULES_PATH=$contribSource/modules", "-DOPENCV_DOWNLOAD_PATH=$downloadCache",
    "-DOPENCV_VCSVERSION=$($lock.opencv_version)-$($lock.opencv_commit)",
    '-DBUILD_SHARED_LIBS=ON', '-DBUILD_opencv_world=ON',
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
$options | ConvertTo-Json | Set-Content (Join-Path $logRoot 'cmake-options.json') -Encoding utf8NoBOM
Invoke-NativeLogged $cmake $options 'configure.log'
$configureText = Get-Content (Join-Path $logRoot 'configure.log') -Raw
if ($configureText -notmatch '(?m)FFMPEG:\s+YES\b') {
    throw 'The requested FFmpeg backend was not enabled; inspect configure.log and CMakeDownloadLog.txt.'
}
if ($configureText -notmatch '(?m)Parallel framework:\s+OpenMP\b') {
    throw 'The requested OpenMP backend was not enabled; inspect configure.log.'
}
Invoke-NativeLogged $cmake @('--build', $buildRoot, '--parallel', "$ParallelJobs") 'build.log'
Invoke-NativeLogged $cmake @('--install', $buildRoot, '--config', 'Release') 'install.log'

$worldDlls = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Filter '*opencv_world*.dll')
if ($worldDlls.Count -ne 1) { throw "Expected exactly one installed Release world DLL, found $($worldDlls.Count)." }
$opencvBinDir = $worldDlls[0].DirectoryName
$configFiles = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Filter 'OpenCVConfig.cmake' |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'OpenCVModules.cmake') })
if ($configFiles.Count -ne 1) { throw "Expected one concrete installed OpenCV CMake package, found $($configFiles.Count)." }
$opencvCMakeDir = $configFiles[0].DirectoryName

$metadataRoot = Join-Path $InstallRoot 'build-info'
New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null
Copy-Item -LiteralPath $LockFile -Destination (Join-Path $metadataRoot 'versions.lock.json')
foreach ($name in @('toolchain-sha256.txt', 'compiler-version.txt', 'cmake-version.txt', 'ninja-version.txt', 'cmake-options.json', 'cmake-ca-info.txt', 'configure.log', 'sources.log')) {
    Copy-Item -LiteralPath (Join-Path $logRoot $name) -Destination $metadataRoot
}
foreach ($name in @('CMakeCache.txt', 'CMakeDownloadLog.txt')) {
    $file = Join-Path $buildRoot $name
    if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination $metadataRoot }
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
    configuration = 'Release'
    requested_parallel_backend = 'OpenMP'
    requested_ffmpeg = $true
    native_smoke_test_completed = $false
}
$statePath = Join-Path $WorkRoot 'build-state.json'
$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
if ($env:GITHUB_OUTPUT) { "state_file=$statePath" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
Write-Host "Build installed at $InstallRoot. Package and runtime validation are the next stages."
