#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateDir,
    [Parameter(Mandatory)][string]$SourceRunFile,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string]$SourceRunId,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string]$SourceRunAttempt,
    [Parameter(Mandatory)][ValidateSet('mingw-release-python', 'mingw-debug', 'cuda-release-python')][string]$Variant,
    [Parameter(Mandatory)][string]$WorkRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$CandidateDir = (Resolve-Path -LiteralPath $CandidateDir).Path
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
if (Test-Path -LiteralPath $WorkRoot) { throw 'Use a fresh recovery work directory.' }
$source = Get-Content -LiteralPath $SourceRunFile -Raw | ConvertFrom-Json -AsHashtable
if (-not $env:GITHUB_REPOSITORY -or $source.repository.full_name -ne $env:GITHUB_REPOSITORY -or
    $source.head_repository.full_name -ne $env:GITHUB_REPOSITORY -or
    $source.path -ne '.github/workflows/build-extended.yml' -or
    $source.event -notin @('push', 'workflow_dispatch') -or $source.status -ne 'completed' -or
    [string]$source.id -ne $SourceRunId -or [long]$source.run_attempt -lt [long]$SourceRunAttempt -or
    $source.head_sha -notmatch '^[0-9a-f]{40}$') {
    throw 'The selected source run is not a completed extended build from this repository.'
}
$origin = Get-Content -LiteralPath (Join-Path $CandidateDir 'candidate-origin.json') -Raw | ConvertFrom-Json -AsHashtable
if ($origin.schema_version -ne 1 -or $origin.checkpoint_status -ne 'unverified' -or $origin.variant -ne $Variant -or
    $origin.repository -ne $env:GITHUB_REPOSITORY -or $origin.workflow_path -ne $source.path -or
    [string]$origin.source_run_id -ne $SourceRunId -or [string]$origin.source_run_attempt -ne $SourceRunAttempt -or
    [long]$origin.source_run_number -ne [long]$source.run_number -or $origin.source_commit -ne $source.head_sha -or
    $origin.source_ref -ne "refs/heads/$($source.head_branch)") {
    throw 'Candidate provenance does not match the selected GitHub Actions run and variant.'
}
$name = [string]$origin.package_name
if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$') { throw 'Invalid candidate package name.' }
$configuration = if ($Variant -eq 'mingw-debug') { 'Debug' } else { 'Release' }
$hasPython = $Variant -ne 'mingw-debug'
if ($origin.configuration -ne $configuration) { throw 'The checkpoint configuration does not match its variant.' }
$expectedFiles = [ordered]@{
    installer = "$name-setup.exe"; archive = "$name.zip"
    build_info = "$name-build-info.json"; build_lock = "$name-build-lock.json"
    state = 'build-state.json'; result = 'package-result.json'; checksums = 'SHA256SUMS'
}
if ($hasPython) {
    if ($origin.files.wheel -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*-win_amd64\.whl$') { throw 'Invalid candidate wheel filename.' }
    $expectedFiles['wheel'] = [string]$origin.files.wheel
    $expectedFiles['wheel_result'] = 'python-wheel-result.json'
}
if ($origin.files.Count -ne $expectedFiles.Count) { throw 'Unexpected candidate file roles.' }
foreach ($role in $expectedFiles.Keys) {
    if (-not $origin.files.Contains($role) -or $origin.files[$role] -cne $expectedFiles[$role]) {
        throw "Unexpected candidate filename for $role."
    }
}
$payloadNames = @($expectedFiles.Values) + @('candidate-origin.json')
$allowedNames = @($payloadNames) + @('CANDIDATE_SHA256SUMS')
foreach ($item in Get-ChildItem -LiteralPath $CandidateDir -Force) {
    if ($item.PSIsContainer -or $item.Name -cnotin $allowedNames) { throw "Unexpected candidate content: $($item.Name)" }
}
function Test-Checksums([string]$ManifestName, [string[]]$ExpectedNames) {
    $seen = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $CandidateDir $ManifestName)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -cnotmatch '^([0-9a-fA-F]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)$') { throw "Invalid checksum manifest: $ManifestName" }
        $hash = $Matches[1]
        $filename = $Matches[2]
        if ($filename -cnotin $ExpectedNames -or $seen.ContainsKey($filename)) { throw "Unexpected or duplicate candidate checksum: $filename" }
        $path = Join-Path $CandidateDir $filename
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $hash) { throw "Candidate checksum mismatch: $filename" }
        $seen[$filename] = $true
    }
    foreach ($filename in $ExpectedNames) {
        if (-not $seen.ContainsKey($filename)) { throw "Missing candidate checksum: $filename" }
    }
}
Test-Checksums 'CANDIDATE_SHA256SUMS' $payloadNames
$publicNames = @($expectedFiles.installer, $expectedFiles.archive, $expectedFiles.build_info,
    $expectedFiles.build_lock, 'candidate-origin.json')
if ($hasPython) { $publicNames += $expectedFiles.wheel }
Test-Checksums 'SHA256SUMS' $publicNames
$result = Get-Content -LiteralPath (Join-Path $CandidateDir $expectedFiles.result) -Raw | ConvertFrom-Json -AsHashtable
$state = Get-Content -LiteralPath (Join-Path $CandidateDir $expectedFiles.state) -Raw | ConvertFrom-Json -AsHashtable
$info = Get-Content -LiteralPath (Join-Path $CandidateDir $expectedFiles.build_info) -Raw | ConvertFrom-Json -AsHashtable
$lock = Get-Content -LiteralPath (Join-Path $CandidateDir $expectedFiles.build_lock) -Raw | ConvertFrom-Json -AsHashtable
$versionFields = if ($Variant -eq 'cuda-release-python') { @('msvc_version', 'cuda_version', 'cudnn_version') } else { @('gcc_version', 'mingw_version', 'winlibs_version') }
foreach ($record in @($result, $state, $info, $lock)) {
    if ($record.schema_version -ne 1 -or $record.package_name -ne $name -or
        $record.configuration -ne $configuration -or $record.opencv_version -ne $result.opencv_version) {
        throw 'The candidate records do not describe the same package and configuration.'
    }
    foreach ($field in $versionFields) {
        if (-not [string]$record[$field] -or $record[$field] -ne $result[$field]) { throw "Candidate version mismatch: $field" }
    }
}
foreach ($field in @('opencv_commit', 'contrib_commit')) {
    if ($lock[$field] -notmatch '^[0-9a-f]{40}$' -or $state[$field] -ne $lock[$field] -or $info[$field] -ne $lock[$field]) {
        throw "Candidate source commit mismatch: $field"
    }
}
if ([bool]$state.python_bindings -ne $hasPython -or [bool]$info.python_bindings -ne $hasPython) { throw 'Candidate Python bindings disagree with the variant.' }
if (($Variant -eq 'cuda-release-python' -and $info.target -ne 'x86_64-pc-windows-msvc') -or
    ($Variant -ne 'cuda-release-python' -and $info.target -ne 'x86_64-w64-mingw32')) { throw 'Candidate compiler target mismatch.' }
$pythonVersion = ''
$wheelPath = ''
if ($hasPython) {
    $wheel = Get-Content -LiteralPath (Join-Path $CandidateDir $expectedFiles.wheel_result) -Raw | ConvertFrom-Json -AsHashtable
    $pythonVersion = [string]$wheel.python.version
    if ($wheel.result -ne 'built' -or $pythonVersion -notmatch '^3\.(12|13|14)\.[0-9]+$' -or
        $pythonVersion -ne $info.python.version -or $wheel.python.numpy_version -ne $info.python.numpy_version -or
        $wheel.opencv_version -ne $result.opencv_version -or $wheel.opencv_commit -ne $lock.opencv_commit -or
        $wheel.contrib_commit -ne $lock.contrib_commit -or [bool]$wheel.cuda_required -ne ($Variant -eq 'cuda-release-python')) {
        throw 'The candidate wheel has mismatched SDK, Python or CUDA provenance.'
    }
    $wheelPath = Join-Path $CandidateDir $expectedFiles.wheel
    if ((Get-FileHash -LiteralPath $wheelPath -Algorithm SHA256).Hash -ne $wheel.wheel_sha256) { throw 'Wheel digest differs from its build result.' }
}

New-Item -ItemType Directory -Path $WorkRoot | Out-Null
$stageParent = Join-Path $WorkRoot 'staged SDK'
$zipPath = Join-Path $CandidateDir $expectedFiles.archive
# Only the expected package root is permitted. Do not extract checkpoint
# entries into the repository or accept paths that escape the SDK root.
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    foreach ($entry in $archive.Entries) {
        $entryName = $entry.FullName.Replace('\', '/')
        if (-not $entryName.StartsWith("$name/", [StringComparison]::Ordinal) -or
            $entryName -match '(^|/)\.\.(?:/|$)' -or $entryName -match ':') {
            throw "Unexpected SDK archive entry: $entryName"
        }
    }
} finally { $archive.Dispose() }
Expand-Archive -LiteralPath $zipPath -DestinationPath $stageParent
$packageRoot = Join-Path $stageParent $name
foreach ($recordName in @('build-info', 'build-lock')) {
    $inside = (Get-FileHash -LiteralPath (Join-Path $packageRoot "$recordName.json") -Algorithm SHA256).Hash
    $outside = (Get-FileHash -LiteralPath (Join-Path $CandidateDir "$name-$recordName.json") -Algorithm SHA256).Hash
    if ($inside -ne $outside) { throw "ZIP and external $recordName metadata differ." }
}
function Resolve-SdkPath([string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)' -or $Relative -match ':') {
        throw 'The SDK metadata must use contained relative paths.'
    }
    $path = [IO.Path]::GetFullPath((Join-Path $packageRoot $Relative))
    $contained = [IO.Path]::GetRelativePath($packageRoot, $path)
    if ([IO.Path]::IsPathRooted($contained) -or $contained -match '^\.\.([\\/]|$)') { throw 'SDK path escapes the restored package.' }
    return (Resolve-Path -LiteralPath $path).Path
}
$result.package_root = $packageRoot
$result.zip_path = $zipPath
$result.installer_path = Join-Path $CandidateDir $expectedFiles.installer
$result.build_info_path = Join-Path $CandidateDir $expectedFiles.build_info
$result.build_lock_path = Join-Path $CandidateDir $expectedFiles.build_lock
$result.checksums_path = Join-Path $CandidateDir 'SHA256SUMS'
$state.install_root = Resolve-SdkPath 'opencv'
$state.opencv_bin_dir = Resolve-SdkPath ([string]$info.opencv_bin_dir)
$state.opencv_cmake_dir = Resolve-SdkPath ([string]$info.opencv_cmake_dir)
$state.lock_file = $result.build_lock_path
$state.build_root = $null
$state.build_tree_removed = $true
$state.build_log_dir = Join-Path $WorkRoot 'logs'
New-Item -ItemType Directory -Path $state.build_log_dir | Out-Null
if ($Variant -ne 'cuda-release-python') {
    $state.toolchain_root = Resolve-SdkPath ([string]$info.toolchain_dir)
    $state.cmake_executable = Join-Path $state.toolchain_root 'bin/cmake.exe'
    $state.ninja_executable = Join-Path $state.toolchain_root 'bin/ninja.exe'
    $state.compiler_executable = Join-Path $state.toolchain_root 'bin/g++.exe'
    foreach ($path in @($state.cmake_executable, $state.ninja_executable, $state.compiler_executable)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The original SDK lacks a required bundled tool: $path" }
    }
}
$cudaLockFile = ''
if ($Variant -eq 'cuda-release-python') {
    if ($lock.cuda_dependencies.cuda_version -ne $lock.cuda_version -or
        $lock.cuda_dependencies.cudnn_version -ne $lock.cudnn_version -or @($lock.cuda_dependencies.components).Count -eq 0) {
        throw 'The CUDA candidate must include its exact toolkit dependency lock.'
    }
    $cudaLockFile = Join-Path $WorkRoot 'expected-cuda-lock.json'
    $lock.cuda_dependencies | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $cudaLockFile -Encoding utf8NoBOM
}
if ($hasPython) {
    $bundledWheel = Resolve-SdkPath ('python-wheel/' + $expectedFiles.wheel)
    if ((Get-FileHash -LiteralPath $bundledWheel -Algorithm SHA256).Hash -ne $wheel.wheel_sha256) {
        throw 'The SDK does not contain the unchanged standalone wheel.'
    }
    $state.python_install_dir = Resolve-SdkPath 'opencv/python'
    $extensions = @(Get-ChildItem -LiteralPath $state.python_install_dir -Recurse -File -Filter 'cv2*.pyd')
    if ($extensions.Count -ne 1) { throw 'The original SDK must contain exactly one cv2 extension.' }
    $state.python_extension = $extensions[0].FullName
    $state.python_wheel_path = $wheelPath
    $wheel.wheel_path = $wheelPath
    $wheelResultFile = Join-Path $CandidateDir 'recovered-python-wheel-result.json'
    $wheel | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $wheelResultFile -Encoding utf8NoBOM
    $state.python_wheel_result = $wheelResultFile
}
$restoredResult = Join-Path $CandidateDir 'recovered-package-result.json'
$restoredState = Join-Path $CandidateDir 'recovered-build-state.json'
$result | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $restoredResult -Encoding utf8NoBOM
$state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $restoredState -Encoding utf8NoBOM
if ($env:GITHUB_OUTPUT) {
    $outputs = [ordered]@{
        result_file = $restoredResult; state_file = $restoredState
        source_commit = $origin.source_commit; configuration = $configuration
        python_required = $hasPython.ToString().ToLowerInvariant(); python_version = $pythonVersion
        wheel_path = $wheelPath; cuda_lock_file = $cudaLockFile
    }
    foreach ($key in $outputs.Keys) { "$key=$($outputs[$key])" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
}
Write-Host "Restored unchanged $Variant binaries from source run $SourceRunId, attempt $SourceRunAttempt."
Write-Host 'Native verification and any required Python/CUDA dependency preparation are still pending.'
