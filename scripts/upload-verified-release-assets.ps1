#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string]$VerifiedRunId,
    [ValidateRange(1, 99999)][int]$RunAttempt = 1,
    [Parameter(Mandatory)][ValidateSet('mingw-release-python', 'mingw-debug', 'cuda-release-python')][string]$Variant,
    [ValidatePattern('^[1-9][0-9]*$')][string]$DraftReleaseId,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$')][string]$DraftReleaseTag,
    [string]$ArtifactDir,
    [string]$ManifestPath,
    [switch]$ResolveOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = 'SilentlyContinue'
if ([bool]$DraftReleaseId -eq [bool]$DraftReleaseTag) {
    throw 'Specify exactly one of DraftReleaseId or DraftReleaseTag for an existing owner-created draft.'
}
$repository = [string]$env:GITHUB_REPOSITORY
if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or -not $env:GH_TOKEN) {
    throw 'Run this helper in the target repository workflow with its GITHUB_TOKEN exposed as GH_TOKEN.'
}

function Read-GitHubJson([string]$Endpoint, [switch]$AllowNotFound) {
    $output = & gh api --method GET $Endpoint 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        if ($AllowNotFound -and $text -match 'HTTP 404') { return $null }
        throw "GitHub read failed for ${Endpoint}: $text"
    }
    return $text | ConvertFrom-Json -AsHashtable
}

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($null -eq $Actual -or [string]$Actual -cne [string]$Expected) {
        throw "${Label} does not match the verified source."
    }
}

function Require-True($Value, [string]$Label) {
    if ($Value -isnot [bool] -or -not $Value) { throw "$Label must be true." }
}

function Read-Record([string]$Name) {
    $path = Join-Path $ArtifactDir $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing verified record: $Name" }
    $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($record -isnot [Collections.IDictionary]) { throw "Expected a JSON object: $Name" }
    return $record
}

function Assert-SourceRun($Run, [string]$Id, [int]$Attempt) {
    Assert-Equal $Run['id'] $Id 'Source run ID'
    Assert-Equal $Run['run_attempt'] $Attempt 'Source run attempt'
    Assert-Equal $Run['repository']['full_name'] $repository 'Source repository'
    Assert-Equal $Run['head_repository']['full_name'] $repository 'Source head repository'
    if ($Run['head_sha'] -notmatch '^[0-9a-f]{40}$' -or $Run['event'] -notin @('push', 'workflow_dispatch')) {
        throw 'The source must be a repository-owned push or manually dispatched workflow with a full commit SHA.'
    }
    if ($Run['status'] -notin @('completed', 'in_progress')) { throw 'The source run has not reached execution.' }
}

function Assert-StepPassed($Steps, [string]$Name) {
    $matches = @($Steps | Where-Object { $_['name'] -ceq $Name })
    if ($matches.Count -ne 1 -or $matches[0]['status'] -ne 'completed' -or $matches[0]['conclusion'] -ne 'success') {
        throw "The verified source job must have passed: $Name"
    }
}

$repo = Read-GitHubJson "repos/$repository"
Assert-Equal $env:GITHUB_REF ('refs/heads/' + $repo['default_branch']) 'Upload workflow branch'
$source = Read-GitHubJson "repos/$repository/actions/runs/$VerifiedRunId/attempts/$RunAttempt"
Assert-SourceRun $source $VerifiedRunId $RunAttempt
Assert-Equal $source['head_branch'] $repo['default_branch'] 'Verified source branch'
$sourcePath = [string]$source['path']
if ($sourcePath -eq '.github/workflows/build-extended.yml') {
    $jobName = $Variant
    $artifactName = "opencv-verified-$Variant-$VerifiedRunId-$RunAttempt"
    if ($Variant -eq 'cuda-release-python') {
        $gateName = 'Validate CUDA publication gates and finalize checksums'
        $uploadName = 'Upload verified CUDA distributions'
    } else {
        $gateName = 'Validate publication gates and finalize checksums'
        $uploadName = 'Upload verified distributions'
    }
} elseif ($sourcePath -eq '.github/workflows/verify-extended-candidate.yml') {
    $jobName = 'verify'
    $artifactName = "opencv-extended-$Variant-$VerifiedRunId-$RunAttempt"
    $gateName = 'Check publication gates and prepare public checksums'
    $uploadName = 'Upload verified original binaries and new verification records'
} else {
    throw 'Only the extended build or extended candidate verification workflow can supply these assets.'
}
$jobPage = Read-GitHubJson "repos/$repository/actions/runs/$VerifiedRunId/attempts/$RunAttempt/jobs?per_page=100"
if ([int]$jobPage['total_count'] -ne @($jobPage['jobs']).Count) { throw 'The source job listing is incomplete.' }
$matchingJobs = @($jobPage['jobs'] | Where-Object { $_['name'] -ceq $jobName })
if ($matchingJobs.Count -ne 1 -or $matchingJobs[0]['status'] -ne 'completed') {
    throw 'Expected one completed source job for the selected variant.'
}
$sourceJob = $matchingJobs[0]
Assert-Equal $sourceJob['run_id'] $VerifiedRunId 'Source job run ID'
Assert-StepPassed $sourceJob['steps'] $gateName
Assert-StepPassed $sourceJob['steps'] $uploadName
# A later release-creation failure is permitted; the native verification and
# public artifact upload above must already have succeeded.
$artifactPage = Read-GitHubJson "repos/$repository/actions/runs/$VerifiedRunId/artifacts?name=$artifactName&per_page=100"
$artifacts = @($artifactPage['artifacts'] | Where-Object { $_['name'] -ceq $artifactName })
if ([int]$artifactPage['total_count'] -ne 1 -or $artifacts.Count -ne 1) {
    throw 'Expected exactly one verified artifact for this source run, attempt and variant.'
}
$artifact = $artifacts[0]
if ($artifact['expired'] -or $artifact['digest'] -notmatch '^sha256:[0-9a-f]{64}$' -or [long]$artifact['size_in_bytes'] -le 0) {
    throw 'The verified artifact is expired or lacks its archive digest.'
}
Assert-Equal $artifact['workflow_run']['id'] $VerifiedRunId 'Artifact workflow run'
Assert-Equal $artifact['workflow_run']['head_sha'] $source['head_sha'] 'Artifact workflow commit'
if ($DraftReleaseTag) {
    $drafts = [Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le 100; $page++) {
        $items = @(Read-GitHubJson "repos/$repository/releases?per_page=100&page=$page")
        foreach ($item in $items) {
            if ($item['tag_name'] -ceq $DraftReleaseTag) { $drafts.Add($item) }
        }
        if ($items.Count -lt 100) { break }
        if ($page -eq 100) { throw 'Release pagination exceeded its expected size.' }
    }
    if ($drafts.Count -ne 1) { throw 'Expected exactly one accessible release matching the requested draft tag.' }
    Require-True $drafts[0]['draft'] 'Requested release draft status'
    $DraftReleaseId = [string]$drafts[0]['id']
    if ($DraftReleaseId -notmatch '^[1-9][0-9]*$') { throw 'Invalid resolved draft release ID.' }
}
if ($ResolveOnly) {
    if ($env:GITHUB_OUTPUT) {
        @("artifact_name=$artifactName", "artifact_id=$($artifact['id'])", "artifact_digest=$($artifact['digest'])", "draft_release_id=$DraftReleaseId") |
            Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
    Write-Host "Verified source job $($sourceJob['id']) and artifact $($artifact['id']): $artifactName"
    return [pscustomobject]@{ artifact_name=$artifactName; artifact_id=$artifact['id']; artifact_digest=$artifact['digest']; draft_release_id=$DraftReleaseId }
}
if (-not $ArtifactDir) { throw 'ArtifactDir is required for attachment upload.' }
$ArtifactDir = (Resolve-Path -LiteralPath $ArtifactDir).Path
if (-not $ManifestPath) { $ManifestPath = Join-Path (Split-Path -Parent $ArtifactDir) 'verified-release-upload.json' }
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ManifestPath) | Out-Null
$manifest = [ordered]@{
    schema_version=1; result='failed'; repository=$repository; variant=$Variant
    verified_run_id=$VerifiedRunId; verified_run_attempt=$RunAttempt; verified_workflow_commit=$source['head_sha']
    artifact_id=$artifact['id']; artifact_name=$artifactName; artifact_digest=$artifact['digest']
    draft_release_id=$DraftReleaseId; uploaded_by_workflow_commit=$env:GITHUB_SHA
    upload_run_id=$env:GITHUB_RUN_ID; upload_run_attempt=$env:GITHUB_RUN_ATTEMPT
    started_at_utc=[DateTime]::UtcNow.ToString('o'); assets=@()
    release_create_edit_publish_performed=$false; tag_mutation_performed=$false
}

try {
    $entries = @(Get-ChildItem -LiteralPath $ArtifactDir -Force)
    if (@($entries | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count) {
        throw 'The verified artifact must contain only regular files at its root.'
    }
    $infoFiles = @($entries | Where-Object { $_.Name -like '*-build-info.json' })
    $lockFiles = @($entries | Where-Object { $_.Name -like '*-build-lock.json' })
    if ($infoFiles.Count -ne 1 -or $lockFiles.Count -ne 1) { throw 'Expected one SDK metadata file and one source lock.' }
    $info = Read-Record $infoFiles[0].Name
    $lock = Read-Record $lockFiles[0].Name
    $origin = Read-Record 'candidate-origin.json'
    $verification = Read-Record 'verification.json'
    $package = [string]$info['package_name']
    if ($package -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$') { throw 'Invalid package name.' }
    $isCuda = $Variant -eq 'cuda-release-python'
    $isDebug = $Variant -eq 'mingw-debug'
    $configuration = if ($isDebug) { 'Debug' } else { 'Release' }
    $compiler = if ($isCuda) { 'msvc' } else { 'mingw' }
    foreach ($record in @($info, $lock, $origin, $verification)) {
        Assert-Equal $record['schema_version'] 1 'Metadata schema'
        Assert-Equal $record['package_name'] $package 'Metadata package name'
        Assert-Equal $record['configuration'] $configuration 'Metadata configuration'
    }
    Assert-Equal $infoFiles[0].Name "$package-build-info.json" 'SDK metadata filename'
    Assert-Equal $lockFiles[0].Name "$package-build-lock.json" 'Source lock filename'
    Assert-Equal $info['toolchain_kind'] $compiler 'SDK compiler family'
    Assert-Equal $verification['result'] 'passed' 'Distribution verification result'
    Assert-Equal $verification['github_run_id'] $VerifiedRunId 'Verification run ID'
    Assert-Equal $verification['github_run_attempt'] $RunAttempt 'Verification attempt'
    Assert-Equal $verification['workflow_commit'] $source['head_sha'] 'Verification commit'
    Assert-Equal $origin['repository'] $repository 'Candidate repository'
    Assert-Equal $origin['workflow_path'] '.github/workflows/build-extended.yml' 'Original build workflow'
    Assert-Equal $origin['variant'] $Variant 'Candidate variant'
    Assert-Equal $origin['source_ref'] ('refs/heads/' + $source['head_branch']) 'Candidate source branch'
    $sourceCommit = [string]$origin['source_commit']
    if ($sourceCommit -notmatch '^[0-9a-f]{40}$' -or [string]$origin['source_run_id'] -notmatch '^[1-9][0-9]*$' -or
        [string]$origin['source_run_attempt'] -notmatch '^[1-9][0-9]*$') { throw 'Invalid original build provenance.' }
    if ($sourcePath -eq '.github/workflows/build-extended.yml') {
        Assert-Equal $origin['source_run_id'] $VerifiedRunId 'Original build run'
        Assert-Equal $origin['source_run_attempt'] $RunAttempt 'Original build attempt'
        Assert-Equal $sourceCommit $source['head_sha'] 'Original build commit'
    } else {
        $original = Read-GitHubJson "repos/$repository/actions/runs/$($origin['source_run_id'])/attempts/$($origin['source_run_attempt'])"
        Assert-SourceRun $original ([string]$origin['source_run_id']) ([int]$origin['source_run_attempt'])
        Assert-Equal $original['path'] '.github/workflows/build-extended.yml' 'Original workflow API identity'
        Assert-Equal $original['head_sha'] $sourceCommit 'Original workflow API commit'
        Assert-Equal $original['head_branch'] $source['head_branch'] 'Original workflow API branch'
    }
    foreach ($field in @('opencv_commit', 'contrib_commit')) {
        if ($lock[$field] -notmatch '^[0-9a-f]{40}$') { throw "Invalid source lock commit: $field" }
        Assert-Equal $info[$field] $lock[$field] "SDK $field"
    }
    Assert-Equal $info['opencv_version'] $lock['opencv_version'] 'SDK OpenCV version'
    Assert-Equal $verification['opencv_version'] $info['opencv_version'] 'Verified OpenCV version'
    if ($info['python_bindings'] -isnot [bool] -or $info['python_bindings'] -eq $isDebug) {
        throw 'Python bindings do not match the selected SDK variant.'
    }
    if ($isDebug) {
        Assert-Equal $info['library_layout'] 'modular' 'Debug library layout'
        Assert-Equal $info['debug_symbols'] 'embedded-dwarf' 'Debug symbols'
    }
    $required = @("$package-setup.exe", "$package.zip", $infoFiles[0].Name, $lockFiles[0].Name,
        'verification.json', 'candidate-origin.json', 'SHA256SUMS')
    $wheelFiles = @($entries | Where-Object { $_.Extension -eq '.whl' })
    $wheelReport = $null
    $wheel = $null
    if (-not $isDebug) {
        if ($wheelFiles.Count -ne 1) { throw 'Exactly one verified Python wheel is required.' }
        $required += @($wheelFiles[0].Name, 'python-wheel-result.json', 'python-wheel-verification.json')
        $wheel = Read-Record 'python-wheel-result.json'
        $wheelReport = Read-Record 'python-wheel-verification.json'
        Assert-Equal $wheel['result'] 'built' 'Wheel build result'
        Assert-Equal $wheelReport['result'] 'passed' 'Wheel verification result'
        Assert-Equal $wheelReport['package_mode'] 'wheel' 'Wheel verification mode'
        foreach ($field in @('opencv_version', 'opencv_commit', 'contrib_commit')) {
            Assert-Equal $wheel[$field] $info[$field] "Wheel $field"
        }
        foreach ($field in @('version', 'major_minor', 'abi', 'numpy_version')) {
            Assert-Equal $wheel['python'][$field] $info['python'][$field] "Wheel Python $field"
        }
        Assert-Equal $wheelReport['opencv_version'] $info['opencv_version'] 'Tested wheel OpenCV version'
        Assert-Equal $wheelReport['python_abi'] $info['python']['abi'] 'Tested wheel Python ABI'
        Assert-Equal $wheelReport['numpy_version'] $info['python']['numpy_version'] 'Tested wheel NumPy version'
        $wheelBase = ([string]$wheel['wheel_path'] -split '[\\/]')[-1]
        Assert-Equal $wheelBase $wheelFiles[0].Name 'Wheel filename'
        $expectedDistribution = if ($isCuda) { 'opencv_cuda' } else { 'opencv_mingw' }
        Assert-Equal $wheel['distribution'] $expectedDistribution 'Wheel distribution'
    } elseif ($wheelFiles.Count) { throw 'The standalone Debug SDK must not contain a Python wheel.' }
    $gpuVerified = $false
    if ($isCuda) {
        Require-True $info['features']['cuda'] 'SDK CUDA capability'
        Require-True $info['features']['cudnn'] 'SDK cuDNN capability'
        Require-True $wheelReport['cuda_compiled'] 'Wheel CUDA capability'
        $locations = @($verification['locations'])
        $expectedLocations = @('staged SDK', 'ZIP consumer', 'installed consumer')
        if ($locations.Count -ne 3) { throw 'All three CUDA SDK locations must have passed.' }
        foreach ($location in $expectedLocations) {
            $match = @($locations | Where-Object { $_['location'] -ceq $location })
            if ($match.Count -ne 1) { throw "Missing or duplicate CUDA SDK location: $location" }
            Assert-Equal $match[0]['cpp'] 'passed' 'CUDA C++ verification'
            Assert-Equal $match[0]['python']['result'] 'passed' 'CUDA SDK Python verification'
            Require-True $match[0]['python']['cuda_compiled'] 'SDK Python CUDA capability'
        }
        $gpuVerified = $verification['gpu_execution'] -eq 'passed' -and $wheelReport['gpu_execution'] -eq 'passed' -and
            @($locations | Where-Object { $_['gpu']['gpu_execution'] -ne 'passed' -or $_['python']['gpu_execution'] -ne 'passed' }).Count -eq 0
    } else {
        foreach ($check in @('staged SDK compile and run', 'ZIP extraction and relocated consumer', 'installed consumer compile and run')) {
            if ($check -notin $verification['checks']) { throw "Missing SDK distribution check: $check" }
        }
        if (-not $isDebug) {
            $pythonChecks = @($verification['python_checks'])
            if ($pythonChecks.Count -ne 3) { throw 'All three SDK Python locations must have passed.' }
            foreach ($stage in @('staged', 'zip', 'installed')) {
                $match = @($pythonChecks | Where-Object { $_['stage'] -ceq $stage })
                if ($match.Count -ne 1) { throw "Missing or duplicate Python location: $stage" }
                Assert-Equal $match[0]['report']['result'] 'passed' 'SDK Python verification'
                Assert-Equal $match[0]['report']['opencv_version'] $info['opencv_version'] 'SDK Python OpenCV version'
                Assert-Equal $match[0]['report']['python_abi'] $info['python']['abi'] 'SDK Python ABI'
                Assert-Equal $match[0]['report']['numpy_version'] $info['python']['numpy_version'] 'SDK Python NumPy version'
            }
        }
    }
    $expectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $required) { [void]$expectedNames.Add($name) }
    if ($entries.Count -ne $expectedNames.Count -or @($entries | Where-Object { -not $expectedNames.Contains($_.Name) }).Count) {
        throw 'The artifact files do not exactly match the public verified asset set.'
    }
    $checksums = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $ArtifactDir 'SHA256SUMS')) {
        if ($line -notmatch '^([0-9a-fA-F]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._-]*)$') { throw 'Invalid SHA256SUMS entry.' }
        $name = $Matches[2]
        if ($name -eq 'SHA256SUMS' -or -not $expectedNames.Contains($name) -or $checksums.ContainsKey($name)) {
            throw 'SHA256SUMS contains an unexpected or duplicate filename.'
        }
        $checksums[$name] = $Matches[1].ToLowerInvariant()
    }
    if ($checksums.Count -ne $expectedNames.Count - 1) { throw 'SHA256SUMS must cover every public asset except itself.' }
    $files = @{}
    foreach ($name in $required) {
        $file = Get-Item -LiteralPath (Join-Path $ArtifactDir $name)
        if ($file.Length -le 0 -or $file.Length -ge 2GB) { throw "Invalid release asset size: $name" }
        $digest = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($name -ne 'SHA256SUMS') { Assert-Equal $digest $checksums[$name] "Asset checksum: $name" }
        $files[$name] = @{ path=$file.FullName; size=[long]$file.Length; digest="sha256:$digest" }
    }
    if ($wheel) {
        $wheelHash = $files[$wheelFiles[0].Name]['digest'].Substring(7)
        Assert-Equal $wheel['wheel_sha256'] $wheelHash 'Built wheel digest'
        Assert-Equal $wheelReport['wheel_sha256'] $wheelHash 'Tested wheel digest'
    }
    $tag = "$package-r$VerifiedRunId-a$RunAttempt"
    if ($DraftReleaseTag) { Assert-Equal $DraftReleaseTag $tag 'Requested draft release tag' }
    $manifest['package_name'] = $package
    $manifest['tag'] = $tag
    $manifest['source_commit'] = $sourceCommit
    $manifest['cuda_gpu_verified'] = [bool]$gpuVerified
    function Check-Draft {
        $release = Read-GitHubJson "repos/$repository/releases/$DraftReleaseId"
        Assert-Equal $release['id'] $DraftReleaseId 'Draft release ID'
        Require-True $release['draft'] 'Existing release draft status'
        Assert-Equal $release['tag_name'] $tag 'Existing draft tag'
        if ($isCuda -and -not $gpuVerified) { Require-True $release['prerelease'] 'CUDA prerelease status without GPU validation' }
        $reference = Read-GitHubJson "repos/$repository/git/ref/tags/$tag" -AllowNotFound
        if ($null -eq $reference) {
            # GitHub may defer tag creation until an owner publishes a draft.
            Assert-Equal $release['target_commitish'] $sourceCommit 'Draft target without an existing tag'
        } else {
            $object = $reference['object']
            for ($depth = 0; $object['type'] -eq 'tag' -and $depth -lt 8; $depth++) {
                if ($object['sha'] -notmatch '^[0-9a-f]{40}$') { throw 'Invalid annotated tag object.' }
                $tagObject = Read-GitHubJson "repos/$repository/git/tags/$($object['sha'])"
                $object = $tagObject['object']
            }
            Assert-Equal $object['type'] 'commit' 'Resolved release tag object type'
            Assert-Equal $object['sha'] $sourceCommit 'Resolved release tag commit'
        }
        $expectedUploadUrl = "https://uploads.github.com/repos/$repository/releases/$DraftReleaseId/assets"
        Assert-Equal (([string]$release['upload_url']) -replace '\{.*$', '') $expectedUploadUrl 'Release asset upload URL'
        return $release
    }
    function Read-ReleaseAssets {
        $all = [Collections.Generic.List[object]]::new()
        for ($page = 1; $page -le 20; $page++) {
            $items = @(Read-GitHubJson "repos/$repository/releases/$DraftReleaseId/assets?per_page=100&page=$page")
            foreach ($item in $items) { $all.Add($item) }
            if ($items.Count -lt 100) { return $all.ToArray() }
        }
        throw 'Release asset pagination exceeded its expected size.'
    }
    function Check-Asset($Asset, [string]$Name) {
        Assert-Equal $Asset['name'] $Name 'Uploaded asset name'
        Assert-Equal $Asset['state'] 'uploaded' "Asset state: $Name"
        Assert-Equal $Asset['size'] $files[$Name]['size'] "Asset size: $Name"
        Assert-Equal $Asset['digest'] $files[$Name]['digest'] "Asset digest: $Name"
    }
    $release = Check-Draft
    $existing = @(Read-ReleaseAssets)
    $existingNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($asset in $existing) {
        if (-not $expectedNames.Contains([string]$asset['name'])) { throw 'The draft contains an unexpected asset; no files were overwritten or deleted.' }
        if (-not $existingNames.Add([string]$asset['name'])) { throw "Duplicate draft asset: $($asset['name'])" }
        Check-Asset $asset ([string]$asset['name'])
    }
    foreach ($name in ($required | Sort-Object)) {
        $matches = @($existing | Where-Object { $_['name'] -ceq $name })
        if ($matches.Count -gt 1) { throw "Duplicate draft assets: $name" }
        if ($matches.Count -eq 1) {
            Check-Asset $matches[0] $name
            $asset = $matches[0]
            $action = 'existing-matched'
        } else {
            Write-Host "Uploading verified asset: $name ($($files[$name]['size']) bytes)"
            $uri = "https://uploads.github.com/repos/$repository/releases/$DraftReleaseId/assets?name=$([Uri]::EscapeDataString($name))"
            $headers = @{ Authorization="Bearer $env:GH_TOKEN"; Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2026-03-10' }
            # This is the only write request in this script. It neither creates
            # nor edits a release or tag, and never deletes/replaces an asset.
            $asset = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/octet-stream' `
                -InFile $files[$name]['path'] -TimeoutSec 1800
            $asset = $asset | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
            Check-Asset $asset $name
            $action = 'uploaded'
        }
        $manifest['assets'] += [ordered]@{ name=$name; size=$files[$name]['size']; digest=$files[$name]['digest']; asset_id=$asset['id']; action=$action }
    }
    $release = Check-Draft
    $finalAssets = @(Read-ReleaseAssets)
    if ($finalAssets.Count -ne $required.Count) { throw 'The final draft attachment count differs from the verified asset set.' }
    foreach ($name in $required) {
        $matches = @($finalAssets | Where-Object { $_['name'] -ceq $name })
        if ($matches.Count -ne 1) { throw "Missing or duplicate final draft asset: $name" }
        Check-Asset $matches[0] $name
    }
    $manifest['result'] = 'uploaded-and-verified'
    $manifest['draft_remains_unpublished'] = $true
    $manifest['release_url'] = $release['html_url']
    if ($env:GITHUB_STEP_SUMMARY) {
        @("## Verified release assets uploaded", '', "- Draft release ID: $DraftReleaseId", "- Tag: $tag",
            "- Original build commit: $sourceCommit", "- Verified artifact: $artifactName ($($artifact['id']))",
            "- Attachments checked: $($required.Count)", '',
            'The release remains a draft. The repository owner must review and publish it in GitHub; this workflow does not change release or tag metadata.') |
            Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
    Write-Host "All $($required.Count) original verified attachments are present. Draft $DraftReleaseId remains unpublished."
} catch {
    $manifest['error'] = $_.Exception.Message
    throw
} finally {
    $manifest['completed_at_utc'] = [DateTime]::UtcNow.ToString('o')
    $manifest | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $ManifestPath -Encoding utf8NoBOM
    if ($env:GITHUB_OUTPUT) { "upload_manifest=$ManifestPath" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
}
