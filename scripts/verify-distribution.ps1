#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultFile,
    [Parameter(Mandatory)][string]$WorkRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Distribution verification requires native Windows.' }
$result = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json
$outputDir = Split-Path -Parent (Resolve-Path -LiteralPath $ResultFile).Path
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
if (Test-Path -LiteralPath $WorkRoot) { throw 'Use a fresh verification directory.' }
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
$started = [DateTime]::UtcNow.ToString('o')
$testScript = Join-Path $PSScriptRoot 'test-package.ps1'

# Build outside the package so that verification never changes archive contents.
& $testScript -PackageRoot $result.package_root -WorkRoot (Join-Path $WorkRoot 'staged sdk') -RequireFFmpeg -RequireOpenMP

$zipParent = Join-Path $WorkRoot 'zip extraction with spaces'
New-Item -ItemType Directory -Path $zipParent | Out-Null
Expand-Archive -LiteralPath $result.zip_path -DestinationPath $zipParent
$zipRoot = Join-Path $zipParent $result.package_name
& $testScript -PackageRoot $zipRoot -WorkRoot (Join-Path $WorkRoot 'zip consumer') -RequireFFmpeg -RequireOpenMP

$installRoot = Join-Path $WorkRoot 'installed SDK with spaces'
$installLog = Join-Path $WorkRoot 'installer.log'
$arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
    "/DIR=`"$installRoot`"", "/LOG=`"$installLog`"")
$process = Start-Process -FilePath $result.installer_path -ArgumentList $arguments -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Installer failed with exit code $($process.ExitCode)." }
& $testScript -PackageRoot $installRoot -WorkRoot (Join-Path $WorkRoot 'installed consumer') -RequireFFmpeg -RequireOpenMP

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
    started_at_utc = $started
    completed_at_utc = [DateTime]::UtcNow.ToString('o')
    operating_system = [Environment]::OSVersion.VersionString
    github_run_id = $env:GITHUB_RUN_ID
    github_run_attempt = $env:GITHUB_RUN_ATTEMPT
    workflow_commit = $env:GITHUB_SHA
    checks = @('staged SDK compile and run', 'ZIP extraction and relocated consumer',
        'silent EXE installation', 'installed consumer compile and run',
        'header/runtime version agreement', 'known pixel conversion', 'PNG round trip',
        'OpenMP build capability', 'FFmpeg video round trip', 'silent uninstall')
    result = 'passed'
}
$verificationPath = Join-Path $outputDir 'verification.json'
$verification | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $verificationPath -Encoding utf8NoBOM
$digest = (Get-FileHash -LiteralPath $verificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$digest  verification.json" | Add-Content -LiteralPath $result.checksums_path -Encoding utf8NoBOM
if ($env:GITHUB_STEP_SUMMARY) {
    @"
## Verified Windows x64 installers

- OpenCV **$($result.opencv_version)** + matching contrib
- GCC **$($result.gcc_version)** / MinGW-w64 **$($result.mingw_version)**, UCRT/POSIX/SEH
- Staged SDK, extracted ZIP and silently installed EXE all compiled and ran the included consumer.
- PNG and FFmpeg video round trips passed; OpenMP was enabled; silent uninstall passed.
- Exact source commits, toolchain SHA-256 and verification report accompany the packages.
"@ | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
Write-Host 'All distribution checks passed.'
