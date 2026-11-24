#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $StateFile,
    [Parameter(Mandatory)] [string] $PackageRoot,
    [Parameter(Mandatory)] [string] $OutputDir,
    [string] $IsccPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Packaging and installer creation require Windows.' }

function Invoke-Checked {
    param([string] $File, [string[]] $Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $File"
    }
}

function Get-ContainedRelativePath {
    param([string] $Base, [string] $Path)
    $relative = [IO.Path]::GetRelativePath($Base, [IO.Path]::GetFullPath($Path))
    if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..\') -or $relative.StartsWith('../')) {
        throw "Path must be inside the package: $Path"
    }
    return $relative
}

function Write-Text {
    param([string] $Path, [string] $Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-PackageZip {
    param([string] $Source, [string] $Destination, [string] $TopLevelName)
    # Explicit entry names give the ZIP a stable top-level folder without
    # making an extra multi-gigabyte copy of the full compiler toolchain.
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $Source -File -Recurse -Force | Sort-Object FullName) {
                $relative = (Get-ContainedRelativePath $Source $file.FullName).Replace('\', '/')
                $entry = $archive.CreateEntry("$TopLevelName/$relative", [IO.Compression.CompressionLevel]::Optimal)
                if ($file.LastWriteTime.Year -ge 1980 -and $file.LastWriteTime.Year -le 2107) {
                    $entry.LastWriteTime = [DateTimeOffset] $file.LastWriteTime
                }
                $inputStream = [IO.File]::OpenRead($file.FullName)
                try {
                    $entryStream = $entry.Open()
                    try { $inputStream.CopyTo($entryStream) }
                    finally { $entryStream.Dispose() }
                } finally { $inputStream.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function Copy-RuntimeDependencies {
    param([string] $InstallRoot, [string] $BinaryDir, [string] $ToolchainRoot, [string[]] $ExternalDlls = @())
    $objdump = Join-Path $ToolchainRoot 'bin/objdump.exe'
    if (-not (Test-Path -LiteralPath $objdump -PathType Leaf)) {
        throw "The selected toolchain has no objdump.exe: $objdump"
    }
    $systemNames = @(
        'advapi32.dll', 'avicap32.dll', 'avifil32.dll', 'bcrypt.dll', 'bcryptprimitives.dll',
        'cabinet.dll', 'cfgmgr32.dll', 'combase.dll', 'comctl32.dll', 'comdlg32.dll',
        'crypt32.dll', 'cryptbase.dll', 'cryptsp.dll', 'd2d1.dll', 'd3d9.dll', 'd3d11.dll',
        'd3d12.dll', 'd3dcompiler_47.dll', 'dbghelp.dll', 'dnsapi.dll', 'dwmapi.dll',
        'dwrite.dll', 'dxgi.dll', 'gdi32.dll', 'glu32.dll', 'hid.dll', 'imm32.dll',
        'iphlpapi.dll', 'kernel32.dll', 'kernelbase.dll', 'mpr.dll', 'msacm32.dll',
        'msimg32.dll', 'msvcrt.dll', 'mswsock.dll', 'mf.dll', 'mfplat.dll',
        'mfreadwrite.dll', 'mfuuid.dll', 'ncrypt.dll', 'netapi32.dll', 'normaliz.dll',
        'ntdll.dll', 'ole32.dll', 'oleaut32.dll', 'opengl32.dll', 'powrprof.dll',
        'propsys.dll', 'psapi.dll', 'rpcrt4.dll', 'secur32.dll', 'setupapi.dll',
        'shell32.dll', 'shlwapi.dll', 'synchronization.dll', 'ucrtbase.dll',
        'urlmon.dll', 'user32.dll', 'userenv.dll', 'usp10.dll', 'uxtheme.dll',
        'version.dll', 'windowscodecs.dll', 'winhttp.dll', 'wininet.dll',
        'winmm.dll', 'winspool.drv', 'wintrust.dll', 'wldap32.dll', 'ws2_32.dll', 'wsock32.dll'
    )
    $systemDlls = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $systemNames) { [void] $systemDlls.Add($name) }
    $toolchainDlls = @{}
    # Prefer the toolchain's own bin directory when duplicate runtime names exist.
    foreach ($file in Get-ChildItem -LiteralPath $ToolchainRoot -Filter '*.dll' -File -Recurse | Sort-Object FullName) {
        if (-not $toolchainDlls.ContainsKey($file.Name)) { $toolchainDlls[$file.Name] = $file.FullName }
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $ToolchainRoot 'bin') -Filter '*.dll' -File) {
        $toolchainDlls[$file.Name] = $file.FullName
    }
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $InstallRoot -File -Recurse | Where-Object { $_.Extension -in '.dll', '.exe', '.pyd' }) {
        $queue.Enqueue($file.FullName)
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $copied = [Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
        $binary = $queue.Dequeue()
        if (-not $seen.Add($binary)) { continue }
        $details = (& $objdump -p $binary 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "Cannot inspect PE dependencies: $binary`n$details" }
        foreach ($match in [regex]::Matches($details, '(?im)^\s*DLL Name:\s*(\S+)\s*$')) {
            $name = $match.Groups[1].Value
            if ($systemDlls.Contains($name) -or $name -match '^(api-ms-win-|ext-ms-win-)') { continue }
            if ($name -in $ExternalDlls) { continue }
            $destination = Join-Path $BinaryDir $name
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $queue.Enqueue($destination)
                continue
            }
            if (-not $toolchainDlls.ContainsKey($name)) {
                throw "Unresolved non-system DLL '$name', imported by '$binary'. It must be staged before packaging."
            }
            $source = $toolchainDlls[$name]
            Copy-Item -LiteralPath $source -Destination $destination
            $copied.Add([ordered]@{
                name = $name
                toolchain_path = (Get-ContainedRelativePath $ToolchainRoot $source).Replace('\', '/')
                sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
            })
            $queue.Enqueue($destination)
        }
    }
    return $copied.ToArray()
}

$StateFile = (Resolve-Path -LiteralPath $StateFile).Path
$state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
foreach ($name in @('package_name', 'opencv_version', 'gcc_version', 'mingw_version', 'winlibs_version',
                     'install_root', 'toolchain_root', 'opencv_bin_dir', 'opencv_cmake_dir', 'lock_file')) {
    if (-not $state.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string] $state.$name)) {
        throw "Missing build-state field: $name"
    }
}
$packageName = [string] $state.package_name
if ($packageName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$') { throw 'Invalid package_name in build state.' }
$configuration = if ($state.PSObject.Properties['configuration']) { [string]$state.configuration } else { 'Release' }
if ($configuration -notin @('Release', 'Debug')) { throw 'Unsupported SDK configuration in build state.' }
$configuration = if ($configuration -eq 'Debug') { 'Debug' } else { 'Release' }
$isDebug = $configuration -eq 'Debug'
if ($isDebug -and $packageName -notmatch '-debug$') { throw 'Debug must have a separate package name ending in -debug.' }
if (-not $isDebug -and $packageName -match '-debug$') { throw 'Release must not use a Debug package name.' }
$libraryLayout = if ($isDebug) { 'modular' } else { 'world' }
$debugSymbols = if ($isDebug) { 'embedded-dwarf' } else { 'not-requested' }
$cpuOptimizationPolicy = if ($state.PSObject.Properties['cpu_optimization_policy']) { [string]$state.cpu_optimization_policy } else { 'upstream-default' }
$disableOptimization = $state.PSObject.Properties['cv_disable_optimization'] -and [bool]$state.cv_disable_optimization
if ($isDebug -and ($cpuOptimizationPolicy -ne 'disabled-for-debug' -or -not $disableOptimization)) {
    throw 'The standalone Debug SDK must be rebuilt with OpenCV explicit CPU optimizations disabled.'
}
$pythonEnabled = $state.PSObject.Properties['python_bindings'] -and [bool]$state.python_bindings
$pythonExternalDlls = @()
if ($pythonEnabled) {
    if ($isDebug -or -not $state.PSObject.Properties['python'] -or $state.python.major_minor -notmatch '^3\.(12|13|14)$') {
        throw 'Python packages require Release and exact supported CPython metadata.'
    }
    $pythonExternalDlls = @(('python' + $state.python.major_minor.Replace('.', '') + '.dll'), 'python3.dll')
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot 'install-python.cmd') -PathType Leaf)) {
        throw 'Prepare the relocatable Python SDK and included wheel before packaging.'
    }
}
$lock = Get-Content -LiteralPath $state.lock_file -Raw | ConvertFrom-Json
if ($lock.package_name -ne $packageName -or
    ($lock.PSObject.Properties['configuration'] -and $lock.configuration -ne $configuration)) {
    throw 'The source lock and build state describe different packages or configurations.'
}
if ([string] $state.opencv_version -notmatch '^\d+\.\d+\.\d+$') { throw 'Only stable numeric OpenCV versions can be packaged.' }
if ([string] $state.gcc_version -notmatch '^\d+\.\d+(\.\d+)?$') { throw 'Invalid GCC version in build state.' }

$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$installRoot = (Resolve-Path -LiteralPath $state.install_root).Path
$toolchainSource = (Resolve-Path -LiteralPath $state.toolchain_root).Path
$binaryDir = (Resolve-Path -LiteralPath $state.opencv_bin_dir).Path
$cmakeDir = (Resolve-Path -LiteralPath $state.opencv_cmake_dir).Path
$installRelative = Get-ContainedRelativePath $PackageRoot $installRoot
$binaryRelative = Get-ContainedRelativePath $PackageRoot $binaryDir
$cmakeRelative = Get-ContainedRelativePath $PackageRoot $cmakeDir
if (-not (Test-Path -LiteralPath (Join-Path $cmakeDir 'OpenCVConfig.cmake') -PathType Leaf)) {
    throw 'The staged OpenCV CMake package is missing.'
}
if (-not (Test-Path -LiteralPath (Join-Path $cmakeDir "OpenCVModules-$($configuration.ToLowerInvariant()).cmake") -PathType Leaf)) {
    throw "The installed SDK has no $configuration CMake import configuration."
}
if ($isDebug) {
    foreach ($module in @('core', 'imgproc', 'imgcodecs', 'videoio')) {
        $dlls = @(Get-ChildItem -LiteralPath $binaryDir -File -Filter "*opencv_${module}*d.dll" |
            Where-Object { $_.Name -match "^(?:lib)?opencv_${module}[0-9]+d\.dll$" })
        if ($dlls.Count -ne 1) { throw "The Debug package must contain exactly one $module Debug DLL." }
    }
    if (@(Get-ChildItem -LiteralPath $binaryDir -File -Filter '*opencv_world*.dll').Count -ne 0) {
        throw 'The standalone Debug package requires modular OpenCV libraries.'
    }
}
$runtimeDlls = @(Copy-RuntimeDependencies -InstallRoot $installRoot -BinaryDir $binaryDir -ToolchainRoot $toolchainSource -ExternalDlls $pythonExternalDlls)

$toolchainDestination = Join-Path $PackageRoot 'mingw64'
if (Test-Path -LiteralPath $toolchainDestination) {
    throw "Toolchain destination already exists; use a fresh package staging directory: $toolchainDestination"
}
New-Item -ItemType Directory -Path $toolchainDestination | Out-Null
Get-ChildItem -LiteralPath $toolchainSource -Force | Copy-Item -Destination $toolchainDestination -Recurse -Force
foreach ($tool in @('gcc.exe', 'g++.exe', 'cmake.exe', 'ninja.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $toolchainDestination "bin/$tool") -PathType Leaf)) {
        throw "The packaged standalone toolchain is missing $tool."
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$exampleSource = Join-Path $repoRoot 'examples/smoke'
if (-not (Test-Path -LiteralPath (Join-Path $exampleSource 'CMakeLists.txt') -PathType Leaf)) {
    throw 'The repository smoke example is missing.'
}
$examplesRoot = Join-Path $PackageRoot 'examples'
New-Item -ItemType Directory -Path $examplesRoot -Force | Out-Null
Copy-Item -LiteralPath $exampleSource -Destination $examplesRoot -Recurse -Force
if ($pythonEnabled) { Copy-Item -LiteralPath (Join-Path $repoRoot 'examples/python') -Destination $examplesRoot -Recurse -Force }

$pythonInstructions = if ($pythonEnabled) {
    @"
PYTHON CV2

This package contains cv2 for regular 64-bit CPython $($state.python.major_minor).
Install that Python version, then run install-python.cmd. It creates an isolated
virtual environment under LocalAppData\OpenCV-SDK\python-envs and installs the
included wheel with its exact NumPy dependency. An internet connection is needed
to download NumPy. CPU and CUDA wheels both import as cv2: use separate environments.

The relocatable source-built loader is under opencv\python\cv2. The included
wheel can also be installed directly with the matching Python interpreter:

  py -$($state.python.major_minor) -m pip install "python-wheel\$([IO.Path]::GetFileName($state.python_wheel_path))"
"@
} else {
    'This C++ SDK does not include a Python cv2 extension. Use the separate Release Python edition for regular CPython.'
}

$replacements = @{
    '@OPENCV_VERSION@' = [string] $state.opencv_version
    '@GCC_VERSION@' = [string] $state.gcc_version
    '@PACKAGE_NAME@' = $packageName
    '@OPENCV_BIN_DIR@' = $binaryRelative
    '@OPENCV_CMAKE_DIR@' = $cmakeRelative
    '@BUILD_CONFIGURATION@' = $configuration
    '@LIBRARY_LAYOUT@' = $libraryLayout
    '@DEBUG_SYMBOLS@' = $debugSymbols
    '@CPU_OPTIMIZATION_POLICY@' = $cpuOptimizationPolicy
    '@PYTHON_INSTRUCTIONS@' = $pythonInstructions
}
foreach ($name in @('activate.cmd', 'build-example.cmd', 'README.txt')) {
    $text = Get-Content -LiteralPath (Join-Path $repoRoot "packaging/templates/$name.in") -Raw
    foreach ($key in $replacements.Keys) { $text = $text.Replace($key, $replacements[$key]) }
    Write-Text (Join-Path $PackageRoot $name) ($text -replace '\r?\n', "`r`n")
}

Write-Text (Join-Path $PackageRoot 'build-lock.json') ($lock | ConvertTo-Json -Depth 30)
$metadata = [ordered]@{
    schema_version = 1
    package_name = $packageName
    opencv_version = [string] $state.opencv_version
    gcc_version = [string] $state.gcc_version
    mingw_version = [string] $state.mingw_version
    winlibs_version = [string] $state.winlibs_version
    target = 'x86_64-w64-mingw32'
    runtime = 'ucrt'
    threading = 'posix'
    exceptions = 'seh'
    configuration = $configuration
    library_layout = $libraryLayout
    debug_symbols = $debugSymbols
    cpu_optimization_policy = $cpuOptimizationPolicy
    cv_disable_optimization = [bool]$disableOptimization
    shared_libraries = $true
    python_bindings = [bool]$pythonEnabled
    toolchain_kind = 'mingw'
    packaged_at_utc = [DateTime]::UtcNow.ToString('o')
    opencv_bin_dir = $binaryRelative.Replace('\', '/')
    opencv_cmake_dir = $cmakeRelative.Replace('\', '/')
    toolchain_dir = 'mingw64'
    runtime_dlls_copied = $runtimeDlls
    source_lock = 'build-lock.json'
    opencv_build_summary = ($installRelative.Replace('\', '/') + '/build-info/configure.log')
    project_url = 'https://github.com/liyiliuxingyu/opencv_mingw'
}
if ($pythonEnabled) { $metadata['python'] = $state.python }
$configureLog = Join-Path $installRoot 'build-info/configure.log'
if (Test-Path -LiteralPath $configureLog -PathType Leaf) {
    $configureText = Get-Content -LiteralPath $configureLog -Raw
    $parallelMatch = [regex]::Match($configureText, '(?im)Parallel framework:\s+([^\r\n]+)')
    $metadata['features'] = [ordered]@{
        parallel_framework = if ($parallelMatch.Success) { $parallelMatch.Groups[1].Value.Trim() } else { 'unknown' }
        ffmpeg = [bool] ($configureText -match '(?im)FFMPEG:\s+YES\b')
        opencl = [bool] ($configureText -match '(?im)OpenCL:\s+YES\b')
    }
}
foreach ($name in @('opencv_commit', 'contrib_commit')) {
    if ($state.PSObject.Properties[$name]) { $metadata[$name] = [string] $state.$name }
}
if ($isDebug) {
    if (-not $state.PSObject.Properties['debug_symbol_dlls'] -or @($state.debug_symbol_dlls).Count -eq 0) {
        throw 'Debug symbol validation is missing from the completed build state.'
    }
    $metadata['debug_symbol_dlls'] = @($state.debug_symbol_dlls)
}
Write-Text (Join-Path $PackageRoot 'build-info.json') ($metadata | ConvertTo-Json -Depth 20)
$licenseText = @'
COMPONENT LICENSES AND SOURCE INFORMATION

The licenses of the individual bundled components apply to those components.
This bundle does not replace or relicense them under a single license.

OpenCV and OpenCV contrib:
  Installed license and notice files are retained under opencv/.
  Exact source revisions are recorded in build-lock.json.
  https://github.com/opencv/opencv
  https://github.com/opencv/opencv_contrib

WinLibs, GCC, MinGW-w64, Binutils, CMake, Ninja and other toolchain components:
  The complete selected WinLibs archive is retained under mingw64/, including
  its supplied license, copying, notice and documentation files.
  The exact original archive URL, release and checksum are in build-lock.json.
  https://github.com/brechtsanders/winlibs_mingw
  https://winlibs.com/
  https://gcc.gnu.org/
  https://www.mingw-w64.org/

Keep applicable license and notice files when redistributing components.
'@
Write-Text (Join-Path $PackageRoot 'LICENSES.txt') $licenseText

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$outputRelative = [IO.Path]::GetRelativePath($PackageRoot, $OutputDir)
if ($outputRelative -eq '.' -or (-not [IO.Path]::IsPathRooted($outputRelative) -and $outputRelative -ne '..' -and $outputRelative -notmatch '^\.\.[\\/]')) {
    throw 'OutputDir must be outside PackageRoot.'
}
$zipPath = Join-Path $OutputDir "$packageName.zip"
$installerPath = Join-Path $OutputDir "$packageName-setup.exe"
foreach ($path in @($zipPath, $installerPath)) {
    if (Test-Path -LiteralPath $path) { throw "Output already exists: $path" }
}

if (-not $IsccPath) {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe')
    )
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates = @($command.Source) + $candidates }
    $IsccPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $IsccPath -or -not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw 'Inno Setup 6 ISCC.exe is required. Install it before calling package-opencv.ps1.'
}
Invoke-Checked -File $IsccPath -Arguments @(
    "/DPackageDir=$PackageRoot", "/DOutputDir=$OutputDir", "/DPackageName=$packageName",
    "/DOpenCVVersion=$($state.opencv_version)", "/DGccVersion=$($state.gcc_version)",
    "/DBuildConfiguration=$configuration",
    "/DPythonEnabled=$([int][bool]$pythonEnabled)",
    "/DPythonAbi=$(if ($pythonEnabled) { $state.python.abi } else { 'none' })",
    (Join-Path $repoRoot 'packaging/opencv-mingw.iss')
)
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw 'Inno Setup did not create the expected installer.' }
New-PackageZip -Source $PackageRoot -Destination $zipPath -TopLevelName $packageName
foreach ($path in @($zipPath, $installerPath)) {
    $size = (Get-Item -LiteralPath $path).Length
    if ($size -ge 2GB) {
        throw "Release asset must be smaller than 2 GiB: $path ($size bytes). Debug symbols have not been stripped."
    }
}

$infoPath = Join-Path $OutputDir "$packageName-build-info.json"
$lockPath = Join-Path $OutputDir "$packageName-build-lock.json"
Copy-Item -LiteralPath (Join-Path $PackageRoot 'build-info.json') -Destination $infoPath
Copy-Item -LiteralPath (Join-Path $PackageRoot 'build-lock.json') -Destination $lockPath
$checksumLines = foreach ($path in @($installerPath, $zipPath, $infoPath, $lockPath)) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(), [IO.Path]::GetFileName($path)
}
Write-Text (Join-Path $OutputDir 'SHA256SUMS') (($checksumLines -join "`n") + "`n")
$result = [ordered]@{
    schema_version = 1
    package_name = $packageName
    package_root = $PackageRoot
    zip_path = $zipPath
    installer_path = $installerPath
    build_info_path = $infoPath
    build_lock_path = $lockPath
    checksums_path = (Join-Path $OutputDir 'SHA256SUMS')
    opencv_version = [string] $state.opencv_version
    gcc_version = [string] $state.gcc_version
    mingw_version = [string] $state.mingw_version
    winlibs_version = [string] $state.winlibs_version
    configuration = $configuration
    toolchain_kind = 'mingw'
    python_bindings = [bool]$pythonEnabled
    library_layout = $libraryLayout
    debug_symbols = $debugSymbols
}
Write-Text (Join-Path $OutputDir 'package-result.json') ($result | ConvertTo-Json -Depth 10)
if ($env:GITHUB_OUTPUT) {
    foreach ($key in @('package_name', 'zip_path', 'installer_path', 'opencv_version', 'gcc_version')) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$key=$($result[$key])" -Encoding utf8
    }
}
Write-Host "Created $zipPath"
Write-Host "Created $installerPath"
Write-Host "Checksums: $(Join-Path $OutputDir 'SHA256SUMS')"
