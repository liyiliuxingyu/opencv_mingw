#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateFile,
    [Parameter(Mandatory)][string]$ResultFile,
    [Parameter(Mandatory)][ValidateSet('mingw-release-python', 'mingw-debug', 'cuda-release-python')][string]$Variant,
    [string]$WheelResultFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ResultFile = (Resolve-Path -LiteralPath $ResultFile).Path
$outputDir = Split-Path -Parent $ResultFile
$result = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json -AsHashtable
$state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json -AsHashtable
$info = Get-Content -LiteralPath $result.build_info_path -Raw | ConvertFrom-Json -AsHashtable
$lock = Get-Content -LiteralPath $result.build_lock_path -Raw | ConvertFrom-Json -AsHashtable
$name = [string]$result.package_name
if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$') { throw 'Invalid candidate package name.' }
$configuration = if ($Variant -eq 'mingw-debug') { 'Debug' } else { 'Release' }
$hasPython = $Variant -ne 'mingw-debug'
foreach ($record in @($result, $state, $info, $lock)) {
    if ($record.schema_version -ne 1 -or $record.package_name -ne $name -or
        $record.opencv_version -ne $result.opencv_version -or $record.configuration -ne $configuration) {
        throw 'The candidate records must describe the same package, version and configuration.'
    }
}
if ([bool]$info.python_bindings -ne $hasPython -or [bool]$state.python_bindings -ne $hasPython) {
    throw 'The candidate Python bindings do not match its variant.'
}
if (($Variant -eq 'cuda-release-python' -and $info.target -ne 'x86_64-pc-windows-msvc') -or
    ($Variant -ne 'cuda-release-python' -and $info.target -ne 'x86_64-w64-mingw32')) {
    throw 'The candidate compiler target does not match its variant.'
}
foreach ($field in @('opencv_commit', 'contrib_commit')) {
    if ($lock[$field] -notmatch '^[0-9a-f]{40}$' -or $state[$field] -ne $lock[$field] -or $info[$field] -ne $lock[$field]) {
        throw "The candidate has inconsistent source provenance: $field"
    }
}
foreach ($variable in @('GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_REF', 'GITHUB_RUN_ID', 'GITHUB_RUN_NUMBER', 'GITHUB_RUN_ATTEMPT')) {
    if (-not [Environment]::GetEnvironmentVariable($variable)) { throw "Missing CI context: $variable" }
}
if ($env:GITHUB_SHA -notmatch '^[0-9a-f]{40}$' -or $env:GITHUB_RUN_ID -notmatch '^[1-9][0-9]*$' -or
    $env:GITHUB_RUN_ATTEMPT -notmatch '^[1-9][0-9]*$') { throw 'Invalid CI provenance.' }
foreach ($filename in @('candidate-origin.json', 'CANDIDATE_SHA256SUMS', 'verification.json')) {
    if (Test-Path -LiteralPath (Join-Path $outputDir $filename)) { throw "Save a fresh candidate before distribution verification: $filename already exists." }
}

function Copy-CandidateFile([string]$Source, [string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Candidate filenames must be plain basenames.' }
    $sourcePath = (Resolve-Path -LiteralPath $Source).Path
    $destination = [IO.Path]::GetFullPath((Join-Path $outputDir $Name))
    if ((Get-Item -LiteralPath $sourcePath).PSIsContainer) { throw "Candidate payload must be a file: $Source" }
    if (-not $sourcePath.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $destination) { throw "Candidate destination already exists: $destination" }
        Copy-Item -LiteralPath $sourcePath -Destination $destination
    }
    return $Name
}
$files = [ordered]@{
    installer = Copy-CandidateFile $result.installer_path "$name-setup.exe"
    archive = Copy-CandidateFile $result.zip_path "$name.zip"
    build_info = Copy-CandidateFile $result.build_info_path "$name-build-info.json"
    build_lock = Copy-CandidateFile $result.build_lock_path "$name-build-lock.json"
    state = Copy-CandidateFile $StateFile 'build-state.json'
    result = Copy-CandidateFile $ResultFile 'package-result.json'
    checksums = 'SHA256SUMS'
}
if ($hasPython) {
    if (-not $WheelResultFile) { throw 'Python candidates require the original wheel result file.' }
    $wheel = Get-Content -LiteralPath $WheelResultFile -Raw | ConvertFrom-Json -AsHashtable
    if ($wheel.result -ne 'built' -or $wheel.opencv_version -ne $result.opencv_version -or
        $wheel.opencv_commit -ne $lock.opencv_commit -or $wheel.contrib_commit -ne $lock.contrib_commit -or
        $wheel.python.version -ne $info.python.version -or $wheel.python.numpy_version -ne $info.python.numpy_version) {
        throw 'The wheel was not built from this SDK and Python environment.'
    }
    if ($wheel.python.version -notmatch '^3\.(12|13|14)\.[0-9]+$' -or
        $wheel.python.numpy_version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+-]*$') {
        throw 'Candidate recovery requires exact standard CPython and NumPy versions.'
    }
    $actualHash = (Get-FileHash -LiteralPath $wheel.wheel_path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $wheel.wheel_sha256) { throw 'The wheel differs from its build result.' }
    $wheelName = [IO.Path]::GetFileName([string]$wheel.wheel_path)
    if ($wheelName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*-win_amd64\.whl$') { throw 'Expected a Windows x64 wheel filename.' }
    $files['wheel'] = Copy-CandidateFile $wheel.wheel_path $wheelName
    $files['wheel_result'] = Copy-CandidateFile $WheelResultFile 'python-wheel-result.json'
} elseif ($WheelResultFile) {
    throw 'The standalone Debug candidate must not include a Python wheel.'
}
$publicFiles = @($files.installer, $files.archive, $files.build_info, $files.build_lock, 'candidate-origin.json')
if ($hasPython) { $publicFiles += $files.wheel }
foreach ($filename in $publicFiles | Where-Object { $_ -ne 'candidate-origin.json' }) {
    if ((Get-Item -LiteralPath (Join-Path $outputDir $filename)).Length -ge 2GB) {
        throw "Candidate release asset must be smaller than 2 GiB: $filename"
    }
}
$origin = [ordered]@{
    schema_version = 1
    checkpoint_status = 'unverified'
    variant = $Variant
    repository = $env:GITHUB_REPOSITORY
    workflow_path = '.github/workflows/build-extended.yml'
    source_run_id = $env:GITHUB_RUN_ID
    source_run_number = $env:GITHUB_RUN_NUMBER
    source_run_attempt = $env:GITHUB_RUN_ATTEMPT
    source_commit = $env:GITHUB_SHA
    source_ref = $env:GITHUB_REF
    package_name = $name
    configuration = $configuration
    created_at_utc = [DateTime]::UtcNow.ToString('o')
    files = $files
}
$origin | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outputDir 'candidate-origin.json') -Encoding utf8NoBOM
function Get-ChecksumLines([string[]]$Names) {
    foreach ($filename in $Names) {
        '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $outputDir $filename) -Algorithm SHA256).Hash.ToLowerInvariant(), $filename
    }
}
Get-ChecksumLines $publicFiles | Set-Content -LiteralPath (Join-Path $outputDir 'SHA256SUMS') -Encoding utf8NoBOM
$payloadNames = @($files.Values) + @('candidate-origin.json')
Get-ChecksumLines $payloadNames | Set-Content -LiteralPath (Join-Path $outputDir 'CANDIDATE_SHA256SUMS') -Encoding utf8NoBOM
$payloadPaths = @(@($payloadNames) + @('CANDIDATE_SHA256SUMS') | ForEach-Object { Join-Path $outputDir $_ })
$artifactName = "opencv-extended-candidate-$Variant-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
if ($env:GITHUB_OUTPUT) {
    "artifact_name=$artifactName" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
    $delimiter = 'candidate_paths_' + [Guid]::NewGuid().ToString('N')
    @("candidate_paths<<$delimiter") + $payloadPaths + @($delimiter) |
        Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
Write-Host "Unverified checkpoint prepared: $artifactName"
Write-Host 'Upload the declared candidate paths before verification to preserve the original binaries and provenance.'
