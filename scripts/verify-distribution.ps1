#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultFile,
    [Parameter(Mandatory)][string]$WorkRoot,
    [string]$PythonExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Distribution verification requires native Windows.' }
$result = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json
$metadata = Get-Content -LiteralPath (Join-Path $result.package_root 'build-info.json') -Raw | ConvertFrom-Json
$configuration = if ($metadata.PSObject.Properties['configuration']) { [string]$metadata.configuration } else { 'Release' }
if ($configuration -notin @('Release', 'Debug')) { throw 'Unsupported SDK configuration.' }
if ($result.PSObject.Properties['configuration'] -and $result.configuration -ne $configuration) {
    throw 'Package result and SDK metadata configurations differ.'
}
$hasPython = $metadata.PSObject.Properties['python_bindings'] -and [bool]$metadata.python_bindings
$pythonTestScript = Join-Path $PSScriptRoot 'test-python-package.ps1'
if ($hasPython) {
    if (-not $PythonExecutable -or -not (Test-Path -LiteralPath $PythonExecutable -PathType Leaf)) {
        throw 'This SDK contains Python bindings; pass the matching PythonExecutable to verify them.'
    }
    if (-not (Test-Path -LiteralPath $pythonTestScript -PathType Leaf)) { throw 'The Python package verification helper is missing.' }
}
$outputDir = Split-Path -Parent (Resolve-Path -LiteralPath $ResultFile).Path
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
if (Test-Path -LiteralPath $WorkRoot) { throw 'Use a fresh verification directory.' }
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
$started = [DateTime]::UtcNow.ToString('o')
$testScript = Join-Path $PSScriptRoot 'test-package.ps1'
$pythonChecks = [Collections.Generic.List[object]]::new()
function Test-PythonConsumer([string]$PackageRoot, [string]$Stage) {
    if (-not $hasPython) { return }
    $pythonWork = Join-Path $WorkRoot "$Stage python"
    & $pythonTestScript -PythonExecutable $PythonExecutable -PackageRoot $PackageRoot `
        -WorkRoot $pythonWork -ExpectedVersion $result.opencv_version
    $pythonReport = Get-Content -LiteralPath (Join-Path $pythonWork 'python-test-result.json') -Raw | ConvertFrom-Json
    if ($pythonReport.result -ne 'passed') { throw "Python verification did not pass for the $Stage SDK." }
    $pythonChecks.Add([ordered]@{ stage = $Stage; report = $pythonReport })
}

# Build outside the package so that verification never changes archive contents.
& $testScript -PackageRoot $result.package_root -WorkRoot (Join-Path $WorkRoot 'staged sdk') -RequireFFmpeg -RequireOpenMP
Test-PythonConsumer $result.package_root 'staged'

$zipParent = Join-Path $WorkRoot 'zip extraction with spaces'
New-Item -ItemType Directory -Path $zipParent | Out-Null
Expand-Archive -LiteralPath $result.zip_path -DestinationPath $zipParent
$zipRoot = Join-Path $zipParent $result.package_name
& $testScript -PackageRoot $zipRoot -WorkRoot (Join-Path $WorkRoot 'zip consumer') -RequireFFmpeg -RequireOpenMP
Test-PythonConsumer $zipRoot 'zip'
# Debug symbols can make the SDK much larger than Release. The completed
# consumer logs live outside this extraction; release its disk space before
# creating another full copy through the installer.
Remove-Item -LiteralPath $zipParent -Recurse -Force

$installRoot = Join-Path $WorkRoot 'installed SDK with spaces'
$installLog = Join-Path $WorkRoot 'installer.log'
$arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
    "/DIR=`"$installRoot`"", "/LOG=`"$installLog`"")
$process = Start-Process -FilePath $result.installer_path -ArgumentList $arguments -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Installer failed with exit code $($process.ExitCode)." }
& $testScript -PackageRoot $installRoot -WorkRoot (Join-Path $WorkRoot 'installed consumer') -RequireFFmpeg -RequireOpenMP
Test-PythonConsumer $installRoot 'installed'

$uninstaller = Join-Path $installRoot 'unins000.exe'
if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'The installer did not register an uninstaller.' }
$uninstallLog = Join-Path $WorkRoot 'uninstaller.log'
$process = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$uninstallLog`"") -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Uninstaller failed with exit code $($process.ExitCode)." }
foreach ($relative in @('activate.cmd', 'mingw64/bin/g++.exe', 'build-info.json')) {
    if (Test-Path -LiteralPath (Join-Path $installRoot $relative)) { throw "Uninstaller left a packaged file: $relative" }
}

$verification = [ordered]@{
    schema_version = 1
    package_name = $result.package_name
    opencv_version = $result.opencv_version
    gcc_version = $result.gcc_version
    mingw_version = $result.mingw_version
    configuration = $configuration
    imported_configuration_verified = [bool]$metadata.PSObject.Properties['library_layout']
    python_bindings = [bool]$hasPython
    started_at_utc = $started
    completed_at_utc = [DateTime]::UtcNow.ToString('o')
    operating_system = [Environment]::OSVersion.VersionString
    github_run_id = $env:GITHUB_RUN_ID
    github_run_attempt = $env:GITHUB_RUN_ATTEMPT
    workflow_commit = $env:GITHUB_SHA
    checks = @('staged SDK compile and run', 'ZIP extraction and relocated consumer',
        'silent EXE installation', 'installed consumer compile and run',
        'matching consumer configuration and runtime configuration',
        'header/runtime version agreement', 'known pixel conversion', 'PNG round trip',
        'OpenMP build capability', 'FFmpeg video round trip', 'silent uninstall')
    result = 'passed'
}
if ($metadata.PSObject.Properties['library_layout']) {
    $verification.checks += 'concrete CMake import libraries and DLLs for the selected configuration'
}
if ($configuration -eq 'Debug') {
    $verification.checks += @('modular Debug DLLs with embedded DWARF and source line sections',
        'GDB source line lookup in staged, relocated and installed Debug SDK')
}
if ($hasPython) {
    if ($pythonChecks.Count -ne 3) { throw 'All three SDK locations must pass Python verification.' }
    $verification['python_checks'] = @($pythonChecks.ToArray())
    $verification.checks += @('Python cv2 import and functional checks in staged, relocated and installed SDK')
}
$verificationPath = Join-Path $outputDir 'verification.json'
$verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $verificationPath -Encoding utf8NoBOM
$digest = (Get-FileHash -LiteralPath $verificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$digest  verification.json" | Add-Content -LiteralPath $result.checksums_path -Encoding utf8NoBOM
if ($env:GITHUB_STEP_SUMMARY) {
    @"
## Verified Windows x64 installers

- OpenCV **$($result.opencv_version)** + matching contrib
- GCC **$($result.gcc_version)** / MinGW-w64 **$($result.mingw_version)**, UCRT/POSIX/SEH
- OpenCV configuration: **$configuration**; Python bindings included: **$([bool]$hasPython)**
- Staged SDK, extracted ZIP and silently installed EXE all compiled and ran the included consumer.
- PNG and FFmpeg video round trips passed; OpenMP was enabled; silent uninstall passed.
- Exact source commits, toolchain SHA-256 and verification report accompany the packages.
"@ | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
Write-Host 'All distribution checks passed.'
