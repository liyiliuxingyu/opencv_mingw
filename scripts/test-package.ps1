#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PackageRoot,
    [Parameter(Mandatory)] [string] $WorkRoot,
    [switch] $RequireFFmpeg,
    [switch] $RequireOpenMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'Package smoke tests require Windows.' }

function Resolve-PackagePath {
    param([string] $Root, [string] $RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "Package metadata contains an absolute path: $RelativePath" }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $relative = [IO.Path]::GetRelativePath($Root, $full)
    if ($relative -eq '..' -or $relative -match '^\.\.[\\/]') {
        throw "Package metadata references a path outside the package: $RelativePath"
    }
    return (Resolve-Path -LiteralPath $full).Path
}

function Invoke-Logged {
    param([string] $File, [string[]] $Arguments, [string] $LogFile)
    & $File @Arguments 2>&1 | Tee-Object -FilePath $LogFile | Write-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command exited with ${exitCode}: $File. See $LogFile"
    }
}

$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$workRelative = [IO.Path]::GetRelativePath($PackageRoot, $WorkRoot)
if (-not [IO.Path]::IsPathRooted($workRelative) -and $workRelative -ne '..' -and $workRelative -notmatch '^\.\.[\\/]') {
    throw 'WorkRoot must be outside PackageRoot so testing does not change the distributed files.'
}
$metadataPath = Join-Path $PackageRoot 'build-info.json'
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
foreach ($field in @('opencv_version', 'gcc_version', 'target', 'toolchain_dir', 'opencv_bin_dir', 'opencv_cmake_dir')) {
    if (-not $metadata.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string] $metadata.$field)) {
        throw "Missing package metadata field: $field"
    }
}
$configuration = if ($metadata.PSObject.Properties['configuration']) { [string]$metadata.configuration } else { 'Release' }
if ($configuration -notin @('Release', 'Debug')) { throw 'Unsupported package configuration.' }
$configuration = if ($configuration -eq 'Debug') { 'Debug' } else { 'Release' }
$isDebug = $configuration -eq 'Debug'
$requiresImportedProof = [bool]$metadata.PSObject.Properties['library_layout']
if ($isDebug -and (-not $metadata.PSObject.Properties['library_layout'] -or $metadata.library_layout -ne 'modular')) {
    throw 'The standalone Debug SDK must declare modular libraries.'
}
$toolchainRoot = Resolve-PackagePath $PackageRoot ([string] $metadata.toolchain_dir)
$opencvBin = Resolve-PackagePath $PackageRoot ([string] $metadata.opencv_bin_dir)
$opencvCMake = Resolve-PackagePath $PackageRoot ([string] $metadata.opencv_cmake_dir)
$exampleRoot = Resolve-PackagePath $PackageRoot 'examples/smoke'
$toolchainBin = Join-Path $toolchainRoot 'bin'
$cmake = Join-Path $toolchainBin 'cmake.exe'
$ninja = Join-Path $toolchainBin 'ninja.exe'
$cxx = Join-Path $toolchainBin 'g++.exe'
foreach ($file in @($cmake, $ninja, $cxx, (Join-Path $opencvCMake 'OpenCVConfig.cmake'), (Join-Path $exampleRoot 'CMakeLists.txt'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required SDK file is missing: $file" }
}
if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { throw 'SystemRoot is not defined.' }
$windowsPath = @((Join-Path $env:SystemRoot 'System32'), $env:SystemRoot)
$runRoot = Join-Path $WorkRoot ('smoke-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$buildDir = Join-Path $runRoot 'build'
$resultDir = Join-Path $runRoot 'results'
$savedEnvironment = @{}
foreach ($name in @('PATH', 'OPENCV_VIDEOIO_PLUGIN_PATH', 'OPENCV_CORE_PLUGIN_PATH', 'OPENCV_VIDEOIO_PRIORITY_LIST', 'LC_ALL')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location -LiteralPath $runRoot
try {
    foreach ($name in @('OPENCV_VIDEOIO_PLUGIN_PATH', 'OPENCV_CORE_PLUGIN_PATH', 'OPENCV_VIDEOIO_PRIORITY_LIST')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $env:PATH = (@($toolchainBin, $opencvBin) + $windowsPath) -join ';'
    $actualTarget = (& $cxx '-dumpmachine' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot query the bundled compiler target.' }
    if ($actualTarget -ne 'x86_64-w64-mingw32' -or $actualTarget -ne [string] $metadata.target) {
        throw "Compiler target '$actualTarget' is not the declared x86-64 MinGW target."
    }
    $actualGcc = (& $cxx '-dumpfullversion' '-dumpversion' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualGcc -ne [string] $metadata.gcc_version) {
        throw "Compiler version '$actualGcc' does not match package metadata '$($metadata.gcc_version)'."
    }
    Invoke-Logged -File $cmake -LogFile (Join-Path $runRoot 'configure.log') -Arguments @(
        '-S', $exampleRoot, '-B', $buildDir, '-G', 'Ninja',
        "-DCMAKE_MAKE_PROGRAM=$ninja", "-DCMAKE_CXX_COMPILER=$cxx",
        "-DCMAKE_BUILD_TYPE=$configuration", "-DOPENCV_EXPECTED_CONFIGURATION=$configuration", "-DOpenCV_DIR=$opencvCMake",
        '-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF', '-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF'
    )
    Invoke-Logged -File $cmake -LogFile (Join-Path $runRoot 'build.log') -Arguments @(
        '--build', $buildDir, '--parallel', '2'
    )
    $linkSelection = Join-Path $buildDir 'opencv-link-selection.txt'
    $importedConfigurationVerified = Test-Path -LiteralPath $linkSelection -PathType Leaf
    if ($importedConfigurationVerified) {
        Copy-Item -LiteralPath $linkSelection -Destination (Join-Path $runRoot 'imported-configuration.log')
    } elseif ($requiresImportedProof) {
        throw 'The configuration-aware consumer did not record its imported DLL selection.'
    }
    $debugSymbolCount = 0
    if ($isDebug) {
        $objdump = Join-Path $toolchainBin 'objdump.exe'
        $gdb = Join-Path $toolchainBin 'gdb.exe'
        foreach ($tool in @($objdump, $gdb)) {
            if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Debug verification requires the bundled tool: $tool" }
        }
        $debugDlls = @(Get-ChildItem -LiteralPath $opencvBin -File -Filter '*opencv_*d.dll' |
            Where-Object { $_.Name -match '^(?:lib)?opencv_[a-z0-9_]+[0-9]+d\.dll$' })
        if ($debugDlls.Count -lt 4) { throw 'The Debug SDK is missing its modular DLLs.' }
        foreach ($dll in $debugDlls) {
            $sections = (& $objdump '-h' $dll.FullName 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0 -or $sections -notmatch '\.debug_info\b' -or $sections -notmatch '\.debug_line\b') {
                throw "The installed Debug DLL has no embedded debug/source line information: $($dll.Name)"
            }
        }
        $debugSymbolCount = $debugDlls.Count
        $coreDll = @($debugDlls | Where-Object { $_.Name -match '^(?:lib)?opencv_core[0-9]+d\.dll$' })
        if ($coreDll.Count -ne 1) { throw 'Expected one Debug core DLL for the source line check.' }
        $gdbLog = Join-Path $runRoot 'debug-source-line.log'
        $env:LC_ALL = 'C'
        Invoke-Logged -File $gdb -LogFile $gdbLog -Arguments @(
            '--batch', '--nx', '--nh', '--quiet', '-iex', 'set auto-load off',
            '-ex', 'set pagination off', '-ex', 'set width 0',
            '-ex', "info line 'cv::Mat::create(int, int, int)'", $coreDll[0].FullName
        )
        if ((Get-Content -LiteralPath $gdbLog -Raw) -notmatch '(?m)^Line\s+[0-9]+\s+of\s+[^\r\n]*matrix\.cpp[^\r\n]*starts at address') {
            throw 'GDB could not resolve the OpenCV Mat::create function to its source line.'
        }
    }

    # Keep compiler/toolchain directories out of the runtime search path. This
    # catches a package that works only because its builder has MinGW installed.
    $env:PATH = (@($opencvBin) + $windowsPath) -join ';'
    $runArguments = @($resultDir, '--expected-version', [string] $metadata.opencv_version)
    # Saved Release candidates can contain the original bundled example. It
    # predates this argument; its emitted runtime build information still lets
    # the current verifier check the configuration independently below.
    if ($requiresImportedProof) { $runArguments += @('--expected-configuration', $configuration) }
    if ($RequireFFmpeg) { $runArguments += '--require-ffmpeg' }
    if ($RequireOpenMP) { $runArguments += '--require-openmp' }
    Invoke-Logged -File (Join-Path $buildDir 'opencv_mingw_smoke.exe') -Arguments $runArguments -LogFile (Join-Path $runRoot 'run.log')
    $runtimeVersion = (Get-Content -LiteralPath (Join-Path $resultDir 'opencv-version.txt') -Raw).Trim()
    $runtimeBuildInfo = Get-Content -LiteralPath (Join-Path $resultDir 'opencv-build-info.txt') -Raw
    if ($runtimeBuildInfo -notmatch "(?m)Configuration:\s+$configuration\s*$") {
        throw "The runtime library did not report the expected $configuration configuration."
    }
    $report = [ordered]@{
        passed = $true
        package_root = $PackageRoot
        runtime_version = $runtimeVersion
        configuration = $configuration
        imported_configuration_verified = [bool]$importedConfigurationVerified
        runtime_configuration_verified = $true
        debug_symbol_dll_count = $debugSymbolCount
        debug_source_line_verified = $isDebug
        compiler_version = $actualGcc
        compiler_target = $actualTarget
        runtime_path = $env:PATH
        required_ffmpeg = [bool] $RequireFFmpeg
        required_openmp = [bool] $RequireOpenMP
        log_directory = $runRoot
        completed_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runRoot 'test-result.json') -Encoding utf8
    Write-Host "Package smoke tests passed. Diagnostics: $runRoot"
} finally {
    Pop-Location
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
