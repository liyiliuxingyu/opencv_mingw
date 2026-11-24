#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository = $(if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'liyiliuxingyu/opencv_mingw' }),
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory,
    [string]$ReadmePath,
    [string]$ConfigFile,
    [switch]$SkipReadme
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $RepositoryRoot 'docs' }
if (-not $ReadmePath) { $ReadmePath = Join-Path $RepositoryRoot 'README.md' }
if (-not $ConfigFile) { $ConfigFile = Join-Path $RepositoryRoot 'config/auto-update.json' }
$configuration = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
if ($configuration['schema_version'] -ne 1 -or $configuration['python_version'] -notmatch '^3\.\d+$' -or
    $configuration['cuda_version'] -notmatch '^\d+\.\d+\.\d+$' -or $configuration['cudnn_version'] -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
    throw 'The automatic maintenance configuration is missing or invalid.'
}
$maintenanceConfig = [ordered]@{}
foreach ($key in @('python_version', 'cuda_version', 'cudnn_version', 'cuda_arch_bin', 'cuda_arch_ptx')) { $maintenanceConfig[$key] = $configuration[$key] }
$channels = @('mingw-release-python', 'mingw-debug', 'cuda-release-python')
$headers = @{ Accept='application/vnd.github+json'; 'User-Agent'='opencv-mingw-download-index'; 'X-GitHub-Api-Version'='2022-11-28' }
$token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
if ($token) { $headers['Authorization'] = "Bearer $token" }
$apiCache = @{}
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('opencv-download-index-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

function Reject([string]$Message) { throw [IO.InvalidDataException]::new($Message) }
function Equal($Actual, $Expected, [string]$Label) {
    if ($null -eq $Actual -or [string]$Actual -cne [string]$Expected) { Reject "$Label disagrees with the verified package." }
}
function True($Value, [string]$Label) {
    if ($Value -isnot [bool] -or -not $Value) { Reject "$Label must be true." }
}
function Read-Api([string]$Endpoint) {
    if (-not $apiCache.ContainsKey($Endpoint)) {
        try {
            $response = Invoke-WebRequest -Uri "https://api.github.com/repos/$Repository/$Endpoint" -Headers $headers `
                -TimeoutSec 60 -MaximumRetryCount 2 -RetryIntervalSec 2
        } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            if ([int]$_.Exception.Response.StatusCode -eq 404) { Reject "Missing GitHub provenance resource: $Endpoint" }
            throw
        }
        $apiCache[$Endpoint] = $response.Content | ConvertFrom-Json -AsHashtable
    }
    return $apiCache[$Endpoint]
}
function Read-AssetText($Asset) {
    # Download only small records, never EXE/ZIP/wheel payloads or executable code.
    if ($Asset['name'] -notmatch '(\.json$|^SHA256SUMS$)' -or [long]$Asset['size'] -gt 4MB) { Reject 'Metadata exceeds the allowed file type or 4 MiB size.' }
    $path = Join-Path $temporaryDirectory ([string]$Asset['id'])
    try {
        Invoke-WebRequest -Uri $Asset['browser_download_url'] -Headers @{ 'User-Agent'='opencv-mingw-download-index' } `
            -OutFile $path -TimeoutSec 60 -MaximumRetryCount 2 -RetryIntervalSec 2 | Out-Null
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        if ([int]$_.Exception.Response.StatusCode -eq 404) { Reject "Missing release metadata asset: $($Asset['name'])" }
        throw
    }
    Equal (Get-Item -LiteralPath $path).Length $Asset['size'] "Metadata length: $($Asset['name'])"
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    Equal "sha256:$hash" $Asset['digest'] "Metadata API digest: $($Asset['name'])"
    return [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true))
}
function Read-Record($Asset) {
    $text = Read-AssetText $Asset
    try { $record = $text | ConvertFrom-Json -AsHashtable } catch { Reject "Invalid JSON: $($Asset['name'])" }
    if ($record -isnot [Collections.IDictionary]) { Reject "Expected JSON object: $($Asset['name'])" }
    return $record
}
function Require-Asset($Assets, [string]$Name) {
    if (-not $Assets.Contains($Name)) { Reject "Missing required release asset: $Name" }
    return $Assets[$Name]
}
function Validate-Run($Run, [string]$Id, [string]$Attempt, [string]$Commit, [string]$Ref) {
    Equal $Run['id'] $Id 'Workflow run ID'
    Equal $Run['run_attempt'] $Attempt 'Workflow run attempt'
    Equal $Run['head_sha'] $Commit 'Workflow run commit'
    Equal $Run['repository']['full_name'] $Repository 'Workflow repository'
    Equal $Run['head_repository']['full_name'] $Repository 'Workflow head repository'
    Equal ('refs/heads/' + $Run['head_branch']) $Ref 'Workflow branch'
    if ($Run['event'] -notin @('push', 'workflow_dispatch') -or $Run['status'] -notin @('completed', 'in_progress')) { Reject 'Unsupported workflow source.' }
}
function Validate-PythonReport($Report, $Info, [bool]$Cuda, [string]$Mode) {
    Equal $Report['result'] 'passed' 'Python verification result'
    Equal $Report['package_mode'] $Mode 'Python verification mode'
    Equal $Report['opencv_version'] $Info['opencv_version'] 'Python OpenCV version'
    Equal $Report['python_version'] $Info['python']['version'] 'Python interpreter version'
    Equal $Report['python_abi'] $Info['python']['abi'] 'Python ABI'
    Equal $Report['numpy_version'] $Info['python']['numpy_version'] 'Python NumPy version'
    if ($Report['cuda_compiled'] -isnot [bool] -or $Report['cuda_compiled'] -ne $Cuda) { Reject 'Python CUDA capability does not match its channel.' }
}
function Validate-Release($Release) {
    $tag = [string]$Release['tag_name']
    if ($tag -notmatch '^([A-Za-z0-9][A-Za-z0-9._-]{0,119})-r([1-9][0-9]*)-a([1-9][0-9]*)$') { return $null }
    $package = $Matches[1]; $verifiedRunId = $Matches[2]; $verifiedAttempt = $Matches[3]
    Equal $Release['html_url'] "https://github.com/$Repository/releases/tag/$tag" 'Release URL'
    if ($Release['draft'] -isnot [bool] -or $Release['draft'] -or -not $Release['published_at']) { return $null }
    $assets = [ordered]@{}
    foreach ($asset in $Release['assets']) {
        $name = [string]$asset['name']
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $assets.Contains($name)) { Reject 'Unsafe or duplicate release asset name.' }
        Equal $asset['browser_download_url'] "https://github.com/$Repository/releases/download/$tag/$name" 'Release download URL'
        Equal $asset['state'] 'uploaded' 'Release asset upload state'
        if ([long]$asset['size'] -le 0 -or [long]$asset['size'] -ge 2GB -or $asset['digest'] -notmatch '^sha256:[0-9a-f]{64}$') { Reject "Missing or invalid asset size/digest: $name" }
        $assets[$name] = $asset
    }
    $origin = Read-Record (Require-Asset $assets 'candidate-origin.json')
    $variant = [string]$origin['variant']
    if ($variant -notin $channels) { return $null } # Historical base SDK remains in Releases.
    $isCuda = $variant -eq 'cuda-release-python'; $isDebug = $variant -eq 'mingw-debug'
    $configuration = if ($isDebug) { 'Debug' } else { 'Release' }
    $compiler = if ($isCuda) { 'msvc' } else { 'mingw' }
    $names = [ordered]@{
        installer="$package-setup.exe"; zip="$package.zip"; checksums='SHA256SUMS'
        build_info="$package-build-info.json"; build_lock="$package-build-lock.json"
        verification='verification.json'; origin='candidate-origin.json'
    }
    foreach ($name in $names.Values) { [void](Require-Asset $assets $name) }
    $info = Read-Record $assets[$names['build_info']]
    $lock = Read-Record $assets[$names['build_lock']]
    $verification = Read-Record $assets['verification.json']
    foreach ($record in @($info, $lock, $origin, $verification)) {
        Equal $record['schema_version'] 1 'Record schema'
        Equal $record['package_name'] $package 'Record package name'
        Equal $record['configuration'] $configuration 'Record configuration'
    }
    Equal $info['toolchain_kind'] $compiler 'Compiler family'
    Equal $origin['repository'] $Repository 'Candidate repository'
    Equal $origin['workflow_path'] '.github/workflows/build-extended.yml' 'Original build workflow'
    Equal $verification['result'] 'passed' 'Distribution verification result'
    Equal $verification['github_run_id'] $verifiedRunId 'Verified tag run'
    Equal $verification['github_run_attempt'] $verifiedAttempt 'Verified tag attempt'
    if ($origin['source_commit'] -notmatch '^[0-9a-f]{40}$' -or $verification['workflow_commit'] -notmatch '^[0-9a-f]{40}$' -or
        [string]$origin['source_run_id'] -notmatch '^[1-9][0-9]*$' -or [string]$origin['source_run_attempt'] -notmatch '^[1-9][0-9]*$' -or
        $origin['source_ref'] -notmatch '^refs/heads/[A-Za-z0-9._/-]+$') { Reject 'Invalid workflow provenance.' }
    if ($info['opencv_version'] -notmatch '^\d+\.\d+\.\d+$') { Reject 'Only stable OpenCV source versions are indexed.' }
    Equal $lock['opencv_version'] $info['opencv_version'] 'Locked OpenCV version'
    Equal $verification['opencv_version'] $info['opencv_version'] 'Verified OpenCV version'
    foreach ($key in @('opencv_commit', 'contrib_commit')) {
        if ($lock[$key] -notmatch '^[0-9a-f]{40}$') { Reject "Invalid locked source commit: $key" }
        Equal $info[$key] $lock[$key] "SDK $key"
    }
    if ($info['python_bindings'] -isnot [bool] -or $info['python_bindings'] -eq $isDebug -or
        $lock['python_bindings'] -isnot [bool] -or $lock['python_bindings'] -ne $info['python_bindings']) { Reject 'Python bindings disagree with the channel.' }
    if ($isCuda) {
        foreach ($key in @('cuda_version', 'cudnn_version')) {
            if ($lock[$key] -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') { Reject "Invalid $key" }
            Equal $info[$key] $lock[$key] "SDK $key"
            Equal $verification[$key] $info[$key] "Verified $key"
        }
        True $info['features']['cuda'] 'SDK CUDA capability'
        True $info['features']['cudnn'] 'SDK cuDNN capability'
    } else {
        if ($lock['winlibs_sha256'] -notmatch '^[0-9a-f]{64}$') { Reject 'Missing exact WinLibs archive hash.' }
        foreach ($key in @('gcc_version', 'mingw_version')) {
            if ($lock[$key] -notmatch '^\d+\.\d+\.\d+$') { Reject "Invalid $key" }
            Equal $info[$key] $lock[$key] "SDK $key"
            Equal $verification[$key] $info[$key] "Verified $key"
        }
        foreach ($check in @('staged SDK compile and run', 'ZIP extraction and relocated consumer', 'installed consumer compile and run', 'silent EXE installation', 'silent uninstall')) {
            if ($check -notin $verification['checks']) { Reject "Missing distribution check: $check" }
        }
    }
    $wheelReport = $null
    if ($isDebug) {
        Equal $info['library_layout'] 'modular' 'Debug library layout'
        Equal $info['debug_symbols'] 'embedded-dwarf' 'Debug symbol format'
        if ('GDB source line lookup in staged, relocated and installed Debug SDK' -notin $verification['checks']) { Reject 'Missing Debug source-line verification.' }
    } else {
        $wheels = @($assets.Keys | Where-Object { $_ -like '*.whl' })
        if ($wheels.Count -ne 1) { Reject 'Expected exactly one verified Python wheel.' }
        $names['wheel'] = $wheels[0]; $names['python_wheel_result'] = 'python-wheel-result.json'; $names['python_wheel_verification'] = 'python-wheel-verification.json'
        $wheel = Read-Record (Require-Asset $assets $names['python_wheel_result'])
        $wheelReport = Read-Record (Require-Asset $assets $names['python_wheel_verification'])
        Equal $wheel['result'] 'built' 'Wheel build result'
        Equal $lock['python_version'] $info['python']['major_minor'] 'Locked Python minor version'
        foreach ($key in @('version', 'major_minor', 'abi', 'numpy_version')) { Equal $wheel['python'][$key] $info['python'][$key] "Wheel Python $key" }
        foreach ($key in @('opencv_version', 'opencv_commit', 'contrib_commit')) { Equal $wheel[$key] $info[$key] "Wheel $key" }
        Equal (([string]$wheel['wheel_path'] -split '[\\/]')[-1]) $wheels[0] 'Wheel filename'
        $distribution = if ($isCuda) { 'opencv_cuda' } else { 'opencv_mingw' }
        Equal $wheel['distribution'] $distribution 'Wheel distribution'
        Equal $wheels[0] "$distribution-$($info['opencv_version'])-$($info['python']['abi'])-$($info['python']['abi'])-win_amd64.whl" 'Wheel platform and ABI'
        Equal $wheel['wheel_size'] $assets[$wheels[0]]['size'] 'Wheel size'
        Equal $wheel['wheel_sha256'] ([string]$assets[$wheels[0]]['digest']).Substring(7) 'Built wheel digest'
        Equal $wheelReport['wheel_sha256'] $wheel['wheel_sha256'] 'Verified wheel digest'
        Validate-PythonReport $wheelReport $info $isCuda 'wheel'
        if (-not $isCuda) {
            $checks = @($verification['python_checks'])
            if ($checks.Count -ne 3) { Reject 'Python must pass in three SDK locations.' }
            foreach ($stage in @('staged', 'zip', 'installed')) {
                $match = @($checks | Where-Object { $_['stage'] -ceq $stage })
                if ($match.Count -ne 1) { Reject "Missing or duplicate Python stage: $stage" }
                Validate-PythonReport $match[0]['report'] $info $false 'loader'
            }
        }
    }
    $gpuVerified = $false
    if ($isCuda) {
        $locations = @($verification['locations'])
        if ($locations.Count -ne 3) { Reject 'CUDA must pass in three SDK locations.' }
        foreach ($name in @('staged SDK', 'ZIP consumer', 'installed consumer')) {
            $match = @($locations | Where-Object { $_['location'] -ceq $name })
            if ($match.Count -ne 1) { Reject "Missing or duplicate CUDA location: $name" }
            Equal $match[0]['cpp'] 'passed' 'CUDA C++ verification'
            Validate-PythonReport $match[0]['python'] $info $true 'loader'
        }
        $gpuVerified = $verification['gpu_execution'] -eq 'passed' -and $wheelReport['gpu_execution'] -eq 'passed' -and
            @($locations | Where-Object { $_['gpu']['gpu_execution'] -ne 'passed' -or $_['python']['gpu_execution'] -ne 'passed' }).Count -eq 0
        if (-not $gpuVerified) { True $Release['prerelease'] 'CUDA release without actual GPU validation must remain prerelease' }
    } elseif ($Release['prerelease']) { Reject 'The stable CPU/Debug channels do not promote prereleases.' }
    $checksums = @{}
    foreach ($line in (Read-AssetText $assets['SHA256SUMS']) -split '\r?\n') {
        if (-not $line) { continue }
        if ($line -notmatch '^([a-fA-F0-9]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._-]*)$') { Reject 'Invalid SHA256SUMS entry.' }
        $name = $Matches[2]; $hash = $Matches[1].ToLowerInvariant()
        if ($name -eq 'SHA256SUMS' -or $checksums.ContainsKey($name)) { Reject 'Duplicate or self-referencing checksum.' }
        $asset = Require-Asset $assets $name
        Equal $asset['digest'] "sha256:$hash" "Release asset checksum: $name"
        $checksums[$name] = $hash
    }
    foreach ($name in $names.Values) {
        if ($name -ne 'SHA256SUMS' -and -not $checksums.ContainsKey($name)) { Reject "Missing public asset checksum: $name" }
    }
    # Confirm the tuple against GitHub without requiring the later publish step
    # to have succeeded (an owner may legitimately recover a 403 publication).
    $sourceRun = Read-Api "actions/runs/$($origin['source_run_id'])/attempts/$($origin['source_run_attempt'])"
    Validate-Run $sourceRun ([string]$origin['source_run_id']) ([string]$origin['source_run_attempt']) $origin['source_commit'] $origin['source_ref']
    Equal $sourceRun['path'] '.github/workflows/build-extended.yml' 'Original workflow API identity'
    $verifyRun = Read-Api "actions/runs/$verifiedRunId/attempts/$verifiedAttempt"
    Validate-Run $verifyRun $verifiedRunId $verifiedAttempt $verification['workflow_commit'] $origin['source_ref']
    if ($verifyRun['path'] -eq '.github/workflows/build-extended.yml') {
        Equal $verifiedRunId $origin['source_run_id'] 'Original verification run'
        Equal $verifiedAttempt $origin['source_run_attempt'] 'Original verification attempt'
        Equal $verification['workflow_commit'] $origin['source_commit'] 'Original verification commit'
    } elseif ($verifyRun['path'] -ne '.github/workflows/verify-extended-candidate.yml') { Reject 'Unsupported verification workflow.' }
    $reference = Read-Api "git/ref/tags/$tag"
    $object = $reference['object']
    for ($depth=0; $object['type'] -eq 'tag' -and $depth -lt 8; $depth++) {
        if ($object['sha'] -notmatch '^[0-9a-f]{40}$') { Reject 'Invalid annotated tag object.' }
        $tagObject = Read-Api "git/tags/$($object['sha'])"; $object = $tagObject['object']
    }
    Equal $object['type'] 'commit' 'Release tag object type'
    Equal $object['sha'] $origin['source_commit'] 'Release tag source commit'
    $publicAssets = [ordered]@{}
    foreach ($key in $names.Keys) {
        $asset = $assets[$names[$key]]
        $publicAssets[$key] = [ordered]@{ name=$asset['name']; size=[long]$asset['size']; sha256=([string]$asset['digest']).Substring(7); url=$asset['browser_download_url'] }
    }
    return [ordered]@{
        variant=$variant; status=$(if ($Release['prerelease']) { 'prerelease' } else { 'stable' }); package_name=$package; opencv_version=$info['opencv_version']
        source_run_id=[string]$origin['source_run_id']; source_run_attempt=[int]$origin['source_run_attempt']; source_commit=$origin['source_commit']
        release=[ordered]@{ id=[long]$Release['id']; tag_name=$tag; html_url=$Release['html_url']; published_at=([DateTimeOffset]$Release['published_at']).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); prerelease=[bool]$Release['prerelease'] }
        build_info=$info; build_lock=$lock; origin=$origin
        verification=[ordered]@{ result='passed'; github_run_id=$verifiedRunId; github_run_attempt=[int]$verifiedAttempt; workflow_commit=$verification['workflow_commit']; gpu_execution=$(if ($isCuda) { if ($gpuVerified) { 'passed' } else { 'not-tested' } } else { 'not-applicable' }) }
        assets=$publicAssets
    }
}
function Version-Key([string]$Value) {
    if (-not $Value) { return [version]'0.0.0' }
    return [version]$Value
}
function Compare-Candidate($Left, $Right) {
    if ($null -eq $Right) { return 1 }
    $keys = if ($Left['variant'] -eq 'cuda-release-python') { @('opencv_version', 'cuda_version', 'cudnn_version') } else { @('opencv_version', 'gcc_version', 'mingw_version') }
    foreach ($key in $keys) {
        $comparison = (Version-Key $Left['build_lock'][$key]).CompareTo((Version-Key $Right['build_lock'][$key]))
        if ($comparison) { return $comparison }
    }
    foreach ($key in @('source_run_id', 'source_run_attempt')) {
        $comparison = ([ulong]$Left[$key]).CompareTo([ulong]$Right[$key]); if ($comparison) { return $comparison }
    }
    foreach ($key in @('github_run_id', 'github_run_attempt')) {
        $comparison = ([ulong]$Left['verification'][$key]).CompareTo([ulong]$Right['verification'][$key]); if ($comparison) { return $comparison }
    }
    return ([long]$Left['release']['id']).CompareTo([long]$Right['release']['id'])
}
function Architecture-Key($Value) {
    $values = @($Value | ForEach-Object { ([string]$_ -split '[,;\s]+') } | Where-Object { $_ } | ForEach-Object {
        if ($_ -notmatch '^\d+\.\d+$') { Reject 'Invalid CUDA architecture value.' }
        ([version]$_).ToString(2)
    } | Sort-Object -Unique)
    return $values -join ';'
}
function Matches-Configuration($Candidate) {
    if ($Candidate['variant'] -eq 'mingw-debug') { return $true }
    if ($Candidate['build_info']['python']['major_minor'] -cne $maintenanceConfig['python_version']) { return $false }
    if ($Candidate['variant'] -eq 'cuda-release-python') {
        foreach ($key in @('cuda_version', 'cudnn_version')) { if ($Candidate['build_lock'][$key] -cne $maintenanceConfig[$key]) { return $false } }
        foreach ($key in @('cuda_arch_bin', 'cuda_arch_ptx')) {
            if ((Architecture-Key $Candidate['build_lock'][$key]) -cne (Architecture-Key $maintenanceConfig[$key])) { return $false }
        }
    }
    return $true
}
function Canonical($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $sorted = [ordered]@{}; foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $sorted[$key] = Canonical $Value[$key] }; return $sorted
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) { return ,@($Value | ForEach-Object { Canonical $_ }) }
    return $Value
}
function Json-Identity($Value) { return (Canonical $Value | ConvertTo-Json -Depth 100 -Compress) }
function Write-IfChanged([string]$Path, [string]$Text) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and [IO.File]::ReadAllText($Path) -ceq $Text) { return $false }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)); return $true
}
function Escape-Markdown([string]$Value) { return $Value.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ').Replace('<', '&lt;').Replace('>', '&gt;') }

try {
    $indexPath = Join-Path $OutputDirectory 'latest-windows.json'
    $previous = $null
    $previousGenerated = $null
    if (Test-Path -LiteralPath $indexPath) {
        $previousText = Get-Content -LiteralPath $indexPath -Raw
        $previous = $previousText | ConvertFrom-Json -AsHashtable
        if ($previous['schema_version'] -ne 1 -or $previous['repository'] -cne $Repository) { throw 'The existing index belongs to another schema or repository.' }
        # ConvertFrom-Json may turn ISO timestamps into DateTime values. Their
        # next JSON serialization trims fractional zeros, creating a false diff.
        # Preserve the original string on PowerShell 7.2 and later.
        $previousDocument = [System.Text.Json.JsonDocument]::Parse($previousText)
        try { $previousGenerated = $previousDocument.RootElement.GetProperty('generated_at_utc').GetString() }
        finally { $previousDocument.Dispose() }
    }
    $candidates = [Collections.Generic.List[object]]::new()
    $variants = [ordered]@{}; foreach ($channel in $channels) { $variants[$channel] = $null }
    for ($page=1; $page -le 100; $page++) {
        $releases = @(Read-Api "releases?per_page=100&page=$page")
        foreach ($release in $releases) {
            if ($release['draft'] -or -not $release['published_at']) { continue }
            Write-Host "Checking published release $($release['id'])..."
            try { $candidate = Validate-Release $release }
            catch [IO.InvalidDataException] { Write-Warning "Excluded release $($release['id']): $($_.Exception.Message)"; continue }
            if ($candidate) {
                $candidate['config_match'] = [bool](Matches-Configuration $candidate)
                $candidate['config_status'] = if ($candidate['config_match']) { 'matched' } else { 'waiting-for-matching-build' }
                $candidates.Add($candidate)
            }
        }
        if ($releases.Count -lt 100) { break }
        if ($page -eq 100) { throw 'Release pagination was incomplete; the existing index was not modified.' }
    }
    foreach ($channel in $channels) {
        $available = @($candidates | Where-Object { $_['variant'] -ceq $channel })
        $matching = @($available | Where-Object { $_['config_match'] })
        if ($matching.Count) { $eligible = $matching }
        else {
            $previousId = if ($previous -and $previous['variants'][$channel]) { $previous['variants'][$channel]['release']['id'] } else { $null }
            $retained = @($available | Where-Object { $null -ne $previousId -and $_['release']['id'] -eq $previousId })
            # An old selection is retained only after revalidating the current
            # published release, every required asset, and its provenance.
            $eligible = if ($retained.Count) { $retained } else { $available }
        }
        foreach ($candidate in $eligible) {
            if ((Compare-Candidate $candidate $variants[$channel]) -gt 0) { $variants[$channel] = $candidate }
        }
    }
    $catalog = [ordered]@{ schema_version=1; repository=$Repository; maintenance_config=$maintenanceConfig; variants=$variants }
    $generated = [DateTime]::UtcNow.ToString('o')
    if ($previous) {
        [void]$previous.Remove('generated_at_utc')
        if ((Json-Identity $previous) -ceq (Json-Identity $catalog)) { $generated = $previousGenerated }
    }
    $catalog['generated_at_utc'] = $generated
    $labels = @{ 'mingw-release-python'='MinGW Release + Python'; 'mingw-debug'='MinGW Debug C++'; 'cuda-release-python'='MSVC CUDA + Python' }
    $table = [Collections.Generic.List[string]]::new()
    $table.Add('| 版本 | OpenCV / 工具链 | 状态 | EXE | ZIP | wheel | SHA-256 | Release |')
    $table.Add('| --- | --- | --- | --- | --- | --- | --- | --- |')
    foreach ($channel in $channels) {
        $item = $variants[$channel]
        if ($null -eq $item) { $table.Add("| $($labels[$channel]) | — | 暂无已验证发布 | — | — | — | — | — |"); continue }
        $info = $item['build_info']; $assets = $item['assets']
        $version = if ($channel -eq 'cuda-release-python') { "$($item['opencv_version']) / CUDA $($info['cuda_version']) / cuDNN $($info['cudnn_version'])" } else { "$($item['opencv_version']) / GCC $($info['gcc_version']) / MinGW $($info['mingw_version'])" }
        $status = if ($item['status'] -eq 'prerelease') { if ($item['verification']['gpu_execution'] -eq 'passed') { '预发布；GPU 已验证' } else { '预发布；GPU 未验证' } } else { '已验证发布' }
        if (-not $item['config_match']) { $status += '；等待配置匹配的新构建' }
        $wheelLink = if ($assets.Contains('wheel')) { "[CPython $($info['python']['major_minor'])]($($assets['wheel']['url']))" } else { '—' }
        $table.Add("| $($labels[$channel]) | $version | $status | [EXE]($($assets['installer']['url'])) | [ZIP]($($assets['zip']['url'])) | $wheelLink | [SHA256SUMS]($($assets['checksums']['url'])) | [详情]($($item['release']['html_url'])) |")
    }
    $tableText = $table -join "`n"
    $readmeBlock = @"
$tableText

下载入口跟随自动维护配置，按已验证的 OpenCV、工具链版本和原始构建运行排序更新。CUDA 的 GPU 验证状态见上表；未验证 GPU 的版本只作为预发布提供。[完整版本、来源和文件摘要](docs/downloads.md) · [机器可读索引](docs/latest-windows.json)
"@
    $readmeText = $null
    if (-not $SkipReadme) {
        $readmeText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReadmePath).Path)
        $start = '<!-- WINDOWS-DOWNLOADS:START -->'; $end = '<!-- WINDOWS-DOWNLOADS:END -->'
        if ([regex]::Matches($readmeText, [regex]::Escape($start)).Count -ne 1 -or [regex]::Matches($readmeText, [regex]::Escape($end)).Count -ne 1 -or $readmeText.IndexOf($end) -lt $readmeText.IndexOf($start)) { throw 'README requires exactly one ordered WINDOWS-DOWNLOADS marker pair.' }
        $newline = if ($readmeText.Contains("`r`n")) { "`r`n" } else { "`n" }
        $replacement = $start + $newline + $newline + $readmeBlock.Trim().Replace("`n", $newline) + $newline + $newline + $end
        $readmeText = [regex]::Replace($readmeText, '(?s)' + [regex]::Escape($start) + '.*?' + [regex]::Escape($end), [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement })
    }
    $details = [Collections.Generic.List[string]]::new()
    $details.Add('# Windows 安装包下载'); $details.Add('')
    $details.Add('本页只列出本仓库已发布、文件摘要一致并完成分发验证的构建。EXE、ZIP 和 wheel 的大文件未在更新索引时重新下载或执行；其 SHA-256 与 GitHub 资产摘要、原始 SHA256SUMS 及 wheel 验证记录交叉核对。')
    $details.Add(''); $details.Add($tableText); $details.Add(''); $details.Add('[机器可读索引](latest-windows.json) · [所有历史 Releases](https://github.com/' + $Repository + '/releases)')
    foreach ($channel in $channels) {
        $item = $variants[$channel]; if ($null -eq $item) { continue }
        $info = $item['build_info']; $lock = $item['build_lock']; $verify = $item['verification']
        $details.Add(''); $details.Add('## ' + $labels[$channel]); $details.Add('')
        $details.Add('- 包名：`' + $item['package_name'] + '`')
        $details.Add('- 发布时间：' + $item['release']['published_at'])
        $details.Add('- 维护配置：' + $(if ($item['config_match']) { '匹配当前自动维护配置。' } else { '等待匹配当前配置的新构建，暂保留仍通过验证的上一个可用版本。' }))
        $details.Add('- 原始构建：[' + $item['source_run_id'] + ' / attempt ' + $item['source_run_attempt'] + '](https://github.com/' + $Repository + '/actions/runs/' + $item['source_run_id'] + ')；提交：[`' + $item['source_commit'] + '`](https://github.com/' + $Repository + '/commit/' + $item['source_commit'] + ')')
        $details.Add('- 分发验证：[' + $verify['github_run_id'] + ' / attempt ' + $verify['github_run_attempt'] + '](https://github.com/' + $Repository + '/actions/runs/' + $verify['github_run_id'] + ')，结果 `passed`。')
        $details.Add('- OpenCV 源码：`' + $lock['opencv_commit'] + '`；contrib：`' + $lock['contrib_commit'] + '`。')
        if ($channel -eq 'cuda-release-python') {
            $details.Add('- CUDA ' + $lock['cuda_version'] + ' / cuDNN ' + $lock['cudnn_version'] + '；实际 GPU 执行：`' + $verify['gpu_execution'] + '`。')
            $details.Add('- CUDA 架构：`' + ($lock['cuda_arch_bin'] -join ', ') + '`；PTX：`' + ($lock['cuda_arch_ptx'] -join ', ') + '`。')
        } else { $details.Add('- WinLibs：`' + (Escape-Markdown $lock['winlibs_version']) + '`；下载归档 SHA-256：`' + $lock['winlibs_sha256'] + '`。') }
        if ($info['python_bindings']) { $details.Add('- CPython ' + $info['python']['version'] + ' / ABI `' + $info['python']['abi'] + '` / NumPy ' + $info['python']['numpy_version'] + '。CPU 与 CUDA wheel 均提供 `cv2`，请分别安装到独立环境。') }
        else { $details.Add('- 独立 C++ Debug 模块库，包含 DWARF 调试信息；不包含 Debug Python。') }
        $details.Add(''); $details.Add('| 文件 | 大小（字节） | SHA-256 |'); $details.Add('| --- | ---: | --- |')
        foreach ($asset in $item['assets'].Values) { $details.Add('| [' + $asset['name'] + '](' + $asset['url'] + ') | ' + $asset['size'] + ' | `' + $asset['sha256'] + '` |') }
    }
    $details.Add(''); $details.Add('索引只在内容变化时更新。旧构建后完成、恢复发布或重新验证不会仅凭发布时间替换更高版本及更新原始构建的入口。'); $details.Add('')
    $changed = Write-IfChanged $indexPath (($catalog | ConvertTo-Json -Depth 100) + "`n")
    $changed = (Write-IfChanged (Join-Path $OutputDirectory 'downloads.md') ($details -join "`n")) -or $changed
    if (-not $SkipReadme) { $changed = (Write-IfChanged $ReadmePath $readmeText) -or $changed }
    if ($env:GITHUB_OUTPUT) { "changed=$($changed.ToString().ToLowerInvariant())" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
    foreach ($channel in $channels) { Write-Host "$channel = $(if ($variants[$channel]) { $variants[$channel]['release']['tag_name'] } else { 'no verified published release' })" }
    Write-Host "Download index changed: $changed"
    return [pscustomobject]@{ changed=$changed; catalog_path=[IO.Path]::GetFullPath($indexPath); variants=$variants }
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
