#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$ConfigPath = 'config/auto-update.json',
    [string]$CatalogPath = 'docs/latest-windows.json',
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$knownVariants = @('mingw-release-python', 'mingw-debug', 'cuda-release-python')
$activeStatuses = @('queued', 'in_progress', 'waiting', 'pending', 'requested')
$now = [DateTimeOffset]::UtcNow
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$workRoot = Join-Path $outputDirectory ('upstream-check-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot | Out-Null
$report = [ordered]@{
    schema_version = 1
    repository = $Repository
    checked_at_utc = $now.ToString('o')
    check_only = [bool]$CheckOnly
    result = 'failed'
    decisions = @()
    dispatched_count = 0
    needs_publication_count = 0
}
$apiToken = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
$apiHeaders = @{
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2026-03-10'
    'User-Agent' = 'opencv-mingw-upstream-checker'
}
if ($apiToken) { $apiHeaders.Authorization = "Bearer $apiToken" }
$apiCache = @{}
$runContexts = @{}

function Read-JsonFile([string]$Path) {
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($value -isnot [Collections.IDictionary]) { throw "Expected a JSON object: $Path" }
    return $value
}

function Get-ApiJson([string]$Endpoint) {
    if (-not $apiCache.ContainsKey($Endpoint)) {
        $value = Invoke-RestMethod -Uri "https://api.github.com/$Endpoint" -Headers $apiHeaders `
            -Method Get -MaximumRetryCount 3 -RetryIntervalSec 3 -TimeoutSec 120
        $apiCache[$Endpoint] = $value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    }
    return $apiCache[$Endpoint]
}

function Get-ApiItems([string]$Endpoint, [string]$Property) {
    $items = [Collections.Generic.List[object]]::new()
    $separator = if ($Endpoint.Contains('?')) { '&' } else { '?' }
    for ($page = 1; $page -le 10; $page++) {
        $response = Get-ApiJson "$Endpoint${separator}per_page=100&page=$page"
        if (-not $response.Contains($Property)) { throw "Incomplete GitHub response: $Endpoint" }
        $batch = @($response[$Property])
        foreach ($item in $batch) { $items.Add($item) }
        if ($batch.Count -lt 100) { return $items.ToArray() }
    }
    throw "GitHub pagination limit reached; refusing an incomplete update decision: $Endpoint"
}

function Normalize-Architectures($Value) {
    $values = @(([string]($Value -join ';')) -split '[;,\s]+' | Where-Object { $_ } | Sort-Object -Unique)
    if ($values.Count -eq 0) { throw 'CUDA architecture lists must not be empty.' }
    foreach ($item in $values) {
        if ($item -notmatch '^\d+\.\d$' -or [version]$item -lt [version]'7.5') {
            throw "Unsupported CUDA 13 architecture: $item"
        }
    }
    return $values
}

function New-Identity([string]$Variant, $Lock, $Settings) {
    foreach ($field in @('opencv_commit', 'contrib_commit')) {
        if ($Lock[$field] -notmatch '^[0-9a-f]{40}$') { throw "Invalid locked source commit: $field" }
    }
    if ($Lock['opencv_version'] -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid locked OpenCV version.' }
    $identity = [ordered]@{
        variant = $Variant
        opencv_version = [string]$Lock['opencv_version']
        opencv_commit = [string]$Lock['opencv_commit']
        contrib_commit = [string]$Lock['contrib_commit']
    }
    if ($Variant -ne 'mingw-debug') {
        if ($Settings['python_version'] -notmatch '^3\.(12|13|14)$') { throw 'Missing supported CPython major/minor version.' }
        $identity['python_version'] = [string]$Settings['python_version']
    }
    if ($Variant -eq 'cuda-release-python') {
        if ($Settings['cuda_version'] -notmatch '^13\.\d+\.\d+$' -or $Settings['cudnn_version'] -notmatch '^9\.\d+\.\d+$') {
            throw 'Automatic CUDA builds require explicit supported CUDA 13 and cuDNN 9 releases.'
        }
        $identity['cuda_version'] = [string]$Settings['cuda_version']
        $identity['cudnn_version'] = [string]$Settings['cudnn_version']
        $identity['cuda_arch_bin'] = @(Normalize-Architectures $Settings['cuda_arch_bin'])
        $identity['cuda_arch_ptx'] = @(Normalize-Architectures $Settings['cuda_arch_ptx'])
    } else {
        if ($Lock['winlibs_sha256'] -notmatch '^[0-9a-f]{64}$' -or
            $Lock['winlibs_version'] -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$' -or
            $Lock['gcc_version'] -notmatch '^\d+\.\d+\.\d+$' -or $Lock['mingw_version'] -notmatch '^\d+\.\d+\.\d+$') {
            throw 'Missing exact WinLibs identity in the source lock.'
        }
        foreach ($field in @('winlibs_version', 'winlibs_sha256', 'gcc_version', 'mingw_version')) {
            $identity[$field] = [string]$Lock[$field]
        }
    }
    return $identity
}

function Get-Fingerprint($Identity) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Identity | ConvertTo-Json -Depth 10 -Compress))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-NewerPublished($Published, $Desired) {
    # A channel with different Python/CUDA configuration is not a replacement
    # for the configured channel, even if it happens to use a newer OpenCV.
    foreach ($field in @('python_version', 'cuda_version', 'cudnn_version', 'cuda_arch_bin', 'cuda_arch_ptx')) {
        if ($Desired.Contains($field) -and (($Published[$field] -join ';') -cne ($Desired[$field] -join ';'))) { return $false }
    }
    if ([version]$Published['opencv_version'] -gt [version]$Desired['opencv_version']) { return $true }
    if ($Published['opencv_commit'] -ne $Desired['opencv_commit'] -or $Published['contrib_commit'] -ne $Desired['contrib_commit']) { return $false }
    if ($Desired['variant'] -ne 'cuda-release-python') {
        foreach ($field in @('gcc_version', 'mingw_version')) {
            if ([version]$Published[$field] -gt [version]$Desired[$field]) { return $true }
            if ([version]$Published[$field] -lt [version]$Desired[$field]) { return $false }
        }
        $oldRevision = [regex]::Match($Published['winlibs_version'], '-r([0-9]+)$')
        $newRevision = [regex]::Match($Desired['winlibs_version'], '-r([0-9]+)$')
        if ($oldRevision.Success -and $newRevision.Success -and [int]$oldRevision.Groups[1].Value -gt [int]$newRevision.Groups[1].Value) { return $true }
    }
    return $false
}

function Test-TrustedRun($Run) {
    return $Run['repository']['full_name'] -ieq $Repository -and
        $Run['head_repository']['full_name'] -ieq $Repository -and
        $Run['head_branch'] -ceq $defaultBranch -and $Run['head_sha'] -match '^[0-9a-f]{40}$' -and
        $Run['event'] -in @('push', 'workflow_dispatch') -and $Run['path'] -eq '.github/workflows/build-extended.yml'
}

function Get-RunContext($Run) {
    $key = "$($Run['id'])-$($Run['run_attempt'])"
    if ($runContexts.ContainsKey($key)) { return $runContexts[$key] }
    $jobs = @(Get-ApiItems "repos/$Repository/actions/runs/$($Run['id'])/attempts/$($Run['run_attempt'])/jobs" 'jobs')
    $context = @{
        run = $Run; jobs = $jobs; artifacts = $null; request = $null; source_lock = $null
        records_read = $false; diagnostics = @{}
    }
    $runContexts[$key] = $context
    return $context
}

function Get-RunArtifacts($Context) {
    if ($null -eq $Context['artifacts']) {
        $Context['artifacts'] = @(Get-ApiItems "repos/$Repository/actions/runs/$($Context['run']['id'])/artifacts" 'artifacts')
    }
    return $Context['artifacts']
}

function Read-ArtifactRecords($Context, $Artifact, [string[]]$Names, [long]$MaximumBytes) {
    $run = $Context['run']
    if ($Artifact['expired']) { return $null }
    if ($Artifact['workflow_run']['id'] -ne $run['id'] -or $Artifact['workflow_run']['head_sha'] -ne $run['head_sha'] -or
        $Artifact['digest'] -notmatch '^sha256:([0-9a-f]{64})$') { throw 'Artifact provenance does not match its source run.' }
    $expectedDigest = ([string]$Artifact['digest']).Substring(7)
    if ([long]$Artifact['size_in_bytes'] -gt $MaximumBytes -or [long]$Artifact['size_in_bytes'] -le 0) {
        throw 'The metadata artifact exceeds the bounded read size.'
    }
    $archivePath = Join-Path $workRoot ("artifact-$($Artifact['id']).zip")
    Invoke-WebRequest -Uri "https://api.github.com/repos/$Repository/actions/artifacts/$($Artifact['id'])/zip" `
        -Headers $apiHeaders -OutFile $archivePath -MaximumRetryCount 3 -RetryIntervalSec 3 -TimeoutSec 120
    if ((Get-Item -LiteralPath $archivePath).Length -gt $MaximumBytes -or
        (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedDigest) {
        throw 'Metadata artifact digest or size verification failed.'
    }
    $records = @{}
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $basename = ($entry.FullName -split '[\\/]')[-1]
            if ($basename -notin $Names) { continue }
            if ($records.ContainsKey($basename) -or $entry.Length -gt 2MB) { throw 'Ambiguous or oversized artifact metadata.' }
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $record = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
            if ($record -isnot [Collections.IDictionary]) { throw 'Artifact metadata must be a JSON object.' }
            $records[$basename] = $record
        }
    } finally {
        $archive.Dispose()
        Remove-Item -LiteralPath $archivePath -Force
    }
    return $records
}

function Read-RunRecords($Context) {
    if ($Context['records_read']) { return }
    $Context['records_read'] = $true
    $run = $Context['run']
    $name = "extended-versions-$($run['id'])-$($run['run_attempt'])"
    $matches = @(Get-RunArtifacts $Context | Where-Object { $_['name'] -ceq $name -and -not $_['expired'] })
    if ($matches.Count -gt 1) { throw 'Duplicate source-lock artifacts.' }
    if ($matches.Count -eq 0) { return }
    $records = Read-ArtifactRecords $Context $matches[0] @('versions.lock.json', 'build-request.json') 2MB
    if ($null -eq $records) { return }
    $Context['source_lock'] = $records['versions.lock.json']
    $request = $records['build-request.json']
    if ($null -ne $request) {
        if ($request['schema_version'] -ne 1 -or $request['repository'] -ine $Repository -or
            $request['source_commit'] -ne $run['head_sha'] -or $request['source_ref'] -ne "refs/heads/$defaultBranch" -or
            [string]$request['run_id'] -ne [string]$run['id'] -or [string]$request['run_attempt'] -ne [string]$run['run_attempt'] -or
            $request['publish'] -isnot [bool] -or @($request['variants']).Count -eq 0 -or
            @($request['variants'] | Where-Object { $_ -notin $knownVariants }).Count) {
            throw 'The recorded build request does not match its workflow run.'
        }
        $Context['request'] = $request
    }
}

function Get-ActiveVariants($Context) {
    $run = $Context['run']
    if ($run['status'] -notin $activeStatuses) { return @() }
    $jobs = @($Context['jobs'])
    $active = [Collections.Generic.List[string]]::new()
    $knownMingw = @($jobs | Where-Object { $_['name'] -in @('mingw-release-python', 'mingw-debug') })
    $skippedMatrix = @($jobs | Where-Object { $_['name'] -eq 'matrix.variant' -and $_['conclusion'] -eq 'skipped' }).Count -gt 0
    foreach ($variant in $knownVariants) {
        $matches = @($jobs | Where-Object { $_['name'] -ceq $variant })
        if ($matches.Count -gt 1) { throw 'Duplicate native jobs in one run attempt.' }
        if ($matches.Count -eq 1) {
            if ($matches[0]['status'] -ne 'completed') { $active.Add($variant) }
        } elseif ($variant -ne 'cuda-release-python' -and ($knownMingw.Count -gt 0 -or $skippedMatrix)) {
            # An expanded MinGW matrix, or its explicit skipped placeholder,
            # identifies a missing configuration as unselected.
        } else {
            Read-RunRecords $Context
            if ($null -eq $Context['request'] -or $variant -in $Context['request']['variants']) { $active.Add($variant) }
        }
    }
    return $active.ToArray()
}

function Get-HistoricalIdentity($Context, [string]$Variant) {
    Read-RunRecords $Context
    $request = $Context['request']
    $sourceLock = $Context['source_lock']
    if ($null -ne $request -and $null -ne $sourceLock) {
        if ($Variant -notin $request['variants']) { return $null }
        $settings = @{}
        foreach ($field in @('python_version', 'cuda_version', 'cudnn_version', 'cuda_arch_bin')) { $settings[$field] = $request[$field] }
        # The existing build workflow has no configurable PTX input.
        $settings['cuda_arch_ptx'] = '9.0'
        return New-Identity $Variant $sourceLock $settings
    }
    # Older verified runs predate build-request.json. Their small diagnostic
    # artifact contains the actual per-variant lock and build state.
    if (-not $Context['diagnostics'].ContainsKey($Variant)) {
        $run = $Context['run']
        $prefix = if ($Variant -eq 'cuda-release-python') { 'extended-logs-cuda' } else { "extended-logs-$Variant" }
        $name = "$prefix-$($run['id'])-$($run['run_attempt'])"
        $matches = @(Get-RunArtifacts $Context | Where-Object { $_['name'] -ceq $name -and -not $_['expired'] })
        if ($matches.Count -gt 1) { throw 'Duplicate diagnostic artifacts.' }
        $Context['diagnostics'][$Variant] = if ($matches.Count -eq 1) {
            Read-ArtifactRecords $Context $matches[0] @('build-state.json', 'versions.lock.json') 64MB
        } else { $null }
    }
    $diagnostics = $Context['diagnostics'][$Variant]
    if ($null -eq $diagnostics -or $null -eq $diagnostics['build-state.json']) { return $null }
    $state = $diagnostics['build-state.json']
    $lock = if ($null -ne $diagnostics['versions.lock.json']) { $diagnostics['versions.lock.json'] } else { $sourceLock }
    if ($null -eq $lock) { return $null }
    $settings = @{
        python_version = if ($null -ne $state['python']) { $state['python']['major_minor'] } else { '' }
        cuda_version = $state['cuda_version']; cudnn_version = $state['cudnn_version']
        cuda_arch_bin = $state['cuda_arch_bin']; cuda_arch_ptx = $state['cuda_arch_ptx']
    }
    return New-Identity $Variant $lock $settings
}

function Test-StepPassed($Job, [string]$Name) {
    $steps = @($Job['steps'] | Where-Object { $_['name'] -ceq $Name })
    return $steps.Count -eq 1 -and $steps[0]['status'] -eq 'completed' -and $steps[0]['conclusion'] -eq 'success'
}

try {
    if (-not $Repository -or ($env:GITHUB_REPOSITORY -and $env:GITHUB_REPOSITORY -ine $Repository)) {
        throw 'Repository must identify this workflow repository.'
    }
    $config = Read-JsonFile $ConfigPath
    if ($config['schema_version'] -ne 1 -or $config['enabled'] -isnot [bool] -or
        ($config['retry_cooldown_hours'] -isnot [long] -and $config['retry_cooldown_hours'] -isnot [int]) -or
        [int]$config['retry_cooldown_hours'] -lt 1 -or [int]$config['retry_cooldown_hours'] -gt 168) {
        throw 'Invalid automatic-update configuration.'
    }
    $variants = @($config['variants'])
    if ($variants.Count -eq 0 -or @($variants | Select-Object -Unique).Count -ne $variants.Count -or
        @($variants | Where-Object { $_ -notin $knownVariants }).Count) { throw 'Select unique supported update variants.' }
    if ($config['python_version'] -notmatch '^3\.(12|13|14)$' -or $config['cuda_version'] -notmatch '^13\.\d+\.\d+$' -or
        $config['cudnn_version'] -notmatch '^9\.\d+\.\d+$' -or
        ((@(Normalize-Architectures $config['cuda_arch_ptx']) -join ';') -ne '9.0')) {
        throw 'Automatic builds require supported explicit Python/CUDA versions and the current fixed PTX target 9.0.'
    }
    [void](Normalize-Architectures $config['cuda_arch_bin'])
    $report['configuration'] = $config
    if (-not $config['enabled']) {
        $report['result'] = 'disabled'
        Write-Host 'Automatic upstream builds are disabled in configuration.'
        return
    }
    $catalog = Read-JsonFile $CatalogPath
    if ($catalog['schema_version'] -ne 1 -or $catalog['repository'] -ine $Repository -or $catalog['variants'] -isnot [Collections.IDictionary]) {
        throw 'Use the trusted current Windows download catalog from this repository.'
    }
    $repo = Get-ApiJson "repos/$Repository"
    $defaultBranch = [string]$repo['default_branch']
    if ([string]::IsNullOrWhiteSpace($defaultBranch)) { throw 'The repository default branch could not be determined.' }
    if (-not $CheckOnly -and $env:GITHUB_REF -ne "refs/heads/$defaultBranch") {
        throw 'Automatic build dispatch is restricted to the repository default branch.'
    }
    $lockPath = Join-Path $workRoot 'versions.lock.json'
    $savedOutput = $env:GITHUB_OUTPUT
    try {
        $env:GITHUB_OUTPUT = $null
        & (Join-Path $PSScriptRoot 'resolve-versions.ps1') -OpenCVVersion latest -WinLibsVersion latest -OutputPath $lockPath
    } finally { $env:GITHUB_OUTPUT = $savedOutput }
    $latestLock = Read-JsonFile $lockPath
    $report['upstream_lock'] = $latestLock
    $decisions = @{}
    foreach ($variant in $variants) {
        $desired = New-Identity $variant $latestLock $config
        $fingerprint = Get-Fingerprint $desired
        $decision = [ordered]@{ variant=$variant; status='build'; reason='No matching published verified package.'; desired=$desired; fingerprint=$fingerprint }
        $published = $catalog['variants'][$variant]
        if ($null -ne $published) {
            $info = $published['build_info']
            $lock = $published['build_lock']
            $configuration = if ($variant -eq 'mingw-debug') { 'Debug' } else { 'Release' }
            $compiler = if ($variant -eq 'cuda-release-python') { 'msvc' } else { 'mingw' }
            if ($published['variant'] -ne $variant -or $published['verification']['result'] -ne 'passed' -or
                $info['toolchain_kind'] -ne $compiler -or $info['configuration'] -ne $configuration -or
                $info['python_bindings'] -isnot [bool] -or $info['python_bindings'] -eq ($variant -eq 'mingw-debug')) {
                throw "The catalog entry has inconsistent variant metadata: $variant"
            }
            $settings = @{
                python_version = if ($null -ne $info['python']) { $info['python']['major_minor'] } else { '' }
                cuda_version = $lock['cuda_version']; cudnn_version = $lock['cudnn_version']
                cuda_arch_bin = $lock['cuda_arch_bin']; cuda_arch_ptx = $lock['cuda_arch_ptx']
            }
            $publishedIdentity = New-Identity $variant $lock $settings
            $decision['published_release'] = $published['release']
            if ((Get-Fingerprint $publishedIdentity) -eq $fingerprint) {
                $decision['status'] = 'up-to-date'
                $decision['reason'] = 'A verified published package matches the exact sources, toolchain and channel configuration.'
            } elseif (Test-NewerPublished $publishedIdentity $desired) {
                $decision['status'] = 'published-newer'
                $decision['reason'] = 'The configured channel already contains a newer verified release; automatic downgrade is disabled.'
            }
        }
        $decisions[$variant] = $decision
        $report.decisions += $decision
    }
    if (@($report.decisions | Where-Object { $_['status'] -eq 'build' }).Count -gt 0) {
        # Source artifacts are kept for 14 days. Failed attempts only delay the
        # same input identity for the configured cooldown, not indefinitely.
        $since = [Uri]::EscapeDataString('>=' + $now.AddDays(-14).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $branch = [Uri]::EscapeDataString($defaultBranch)
        $runs = @(Get-ApiItems "repos/$Repository/actions/workflows/build-extended.yml/runs?branch=$branch&created=$since" 'workflow_runs' |
            Where-Object { Test-TrustedRun $_ } | Sort-Object { [DateTimeOffset]$_['created_at'] } -Descending)
        foreach ($run in $runs | Where-Object { $_['status'] -in $activeStatuses }) {
            $context = Get-RunContext $run
            foreach ($variant in @(Get-ActiveVariants $context)) {
                if ($decisions.ContainsKey($variant) -and $decisions[$variant]['status'] -eq 'build') {
                    $decisions[$variant]['status'] = 'in-progress'
                    $decisions[$variant]['reason'] = 'An existing run already owns this variant, or its matrix has not yet been resolved.'
                    $decisions[$variant]['run_id'] = [string]$run['id']
                    $decisions[$variant]['run_url'] = [string]$run['html_url']
                }
            }
        }
        foreach ($variant in $variants) {
            $decision = $decisions[$variant]
            if ($decision['status'] -ne 'build') { continue }
            # A completed MinGW job can await publication while another job in
            # the same run is still compiling CUDA. Inspect completed jobs even
            # when the encompassing run has not finished.
            foreach ($run in $runs) {
                $context = Get-RunContext $run
                $matches = @($context['jobs'] | Where-Object { $_['name'] -ceq $variant -and $_['status'] -eq 'completed' -and $_['conclusion'] -ne 'skipped' })
                if ($matches.Count -eq 0) {
                    # An error before matrix expansion must not produce an
                    # hourly retry loop. Use the request receipt when present;
                    # older unresolved failures conservatively cool down all
                    # still-missing channels for the same short interval.
                    $resolveFailures = @($context['jobs'] | Where-Object {
                        $_['name'] -eq 'Lock source and toolchain versions once' -and
                        $_['status'] -eq 'completed' -and $_['conclusion'] -in @('failure', 'cancelled', 'timed_out')
                    })
                    if ($resolveFailures.Count -ne 1) { continue }
                    Read-RunRecords $context
                    if ($null -ne $context['request'] -and $variant -notin $context['request']['variants']) { continue }
                    $matches = $resolveFailures
                }
                if ($matches.Count -ne 1) { throw 'Duplicate historical variant jobs.' }
                $job = $matches[0]
                $isCuda = $variant -eq 'cuda-release-python'
                $gate = if ($isCuda) { 'Validate CUDA publication gates and finalize checksums' } else { 'Validate publication gates and finalize checksums' }
                $upload = if ($isCuda) { 'Upload verified CUDA distributions' } else { 'Upload verified distributions' }
                $publish = if ($isCuda) { 'Publish CUDA prerelease when GPU execution remains untested' } else { 'Publish this verified variant' }
                $verified = (Test-StepPassed $job $gate) -and (Test-StepPassed $job $upload)
                $failureTime = if ($job['completed_at']) { [DateTimeOffset]$job['completed_at'] } else { [DateTimeOffset]$run['updated_at'] }
                $inCooldown = $job['conclusion'] -in @('failure', 'cancelled', 'timed_out') -and $failureTime -gt $now.AddHours(-[int]$config['retry_cooldown_hours'])
                if (-not $verified -and -not $inCooldown) { continue }
                $identity = Get-HistoricalIdentity $context $variant
                if ($null -ne $identity -and (Get-Fingerprint $identity) -ne $decision['fingerprint']) { continue }
                if ($verified) {
                    $publishSteps = @($job['steps'] | Where-Object { $_['name'] -ceq $publish })
                    $publicationRequested = if ($null -ne $context['request']) { [bool]$context['request']['publish'] } else {
                        $publishSteps.Count -eq 1 -and $publishSteps[0]['conclusion'] -ne 'skipped'
                    }
                    if (-not $publicationRequested) {
                        # A deliberate publish=false run neither claims the
                        # automatic release channel nor blocks a future build.
                        continue
                    }
                    $artifactName = "opencv-verified-$variant-$($run['id'])-$($run['run_attempt'])"
                    $artifacts = @(Get-RunArtifacts $context | Where-Object { $_['name'] -ceq $artifactName -and -not $_['expired'] })
                    if ($artifacts.Count -gt 1) { throw 'Duplicate verified artifacts.' }
                    if ($artifacts.Count -eq 1) {
                        if ($artifacts[0]['workflow_run']['id'] -ne $run['id'] -or
                            $artifacts[0]['workflow_run']['head_sha'] -ne $run['head_sha'] -or
                            [long]$artifacts[0]['size_in_bytes'] -le 0 -or
                            $artifacts[0]['digest'] -notmatch '^sha256:[0-9a-f]{64}$') {
                            throw 'The verified artifact does not match its source run.'
                        }
                        $decision['status'] = 'needs-publication'
                        $decision['reason'] = if ($null -ne $identity) { 'Matching verified binaries already exist; finish publication without recompiling OpenCV.' } else { 'Verified binaries await publication; inspect the older run metadata before scheduling a replacement.' }
                        $decision['artifact_id'] = [string]$artifacts[0]['id']
                        $report.needs_publication_count++
                    }
                }
                if ($decision['status'] -eq 'build' -and $inCooldown) {
                    $decision['status'] = 'cooldown'
                    $decision['reason'] = if ($null -ne $identity) { 'This exact input identity failed recently; a later check may retry after the cooldown.' } else { 'A recent failure predates complete request metadata; conservatively delay this variant.' }
                    $decision['retry_after_utc'] = $failureTime.AddHours([int]$config['retry_cooldown_hours']).ToString('o')
                }
                if ($decision['status'] -ne 'build') {
                    $decision['run_id'] = [string]$run['id']
                    $decision['run_url'] = [string]$run['html_url']
                    break
                }
            }
        }
    }
    foreach ($decision in $report.decisions) {
        if ($decision['status'] -eq 'build') {
            if ($CheckOnly) {
                $decision['status'] = 'would-dispatch'
            } else {
                if (-not $apiToken) { throw 'Workflow dispatch requires the current workflow GITHUB_TOKEN.' }
                $variant = $decision['variant']
                $inputs = [ordered]@{
                    opencv_version = [string]$latestLock['opencv_version']; winlibs_version = [string]$latestLock['winlibs_version']
                    python_version = [string]$config['python_version']
                    build_python = ($variant -eq 'mingw-release-python'); build_debug = ($variant -eq 'mingw-debug'); build_cuda = ($variant -eq 'cuda-release-python')
                    cuda_version = [string]$config['cuda_version']; cudnn_version = [string]$config['cudnn_version']
                    cuda_arch_bin = (@(Normalize-Architectures $config['cuda_arch_bin']) -join ';'); publish = $true
                }
                $body = @{ref=$defaultBranch; inputs=$inputs} | ConvertTo-Json -Depth 6 -Compress
                $decision['dispatch_inputs'] = $inputs
                $decision['status'] = 'dispatch-unknown'
                # Do not automatically retry a POST: a lost response may still
                # have created a run. The next scheduled check reads active jobs.
                Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/actions/workflows/build-extended.yml/dispatches" `
                    -Headers $apiHeaders -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 120 | Out-Null
                $decision['status'] = 'dispatched'
                $decision['reason'] = 'Dispatched one independently selected variant using explicit stable upstream tags.'
                $report.dispatched_count++
            }
        }
        Write-Host "$($decision['variant']): $($decision['status']) — $($decision['reason'])"
    }
    $report['result'] = 'checked'
} catch {
    $report['error'] = $_.Exception.Message
    throw
} finally {
    $report['completed_at_utc'] = [DateTimeOffset]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    if ($env:GITHUB_OUTPUT) {
        @("update_check_result=$($report.result)", "dispatched_count=$($report.dispatched_count)", "needs_publication_count=$($report.needs_publication_count)") |
            Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = @('## Upstream Windows build check', '', "Result: $($report.result); read-only check: $([bool]$CheckOnly)", '', '| Variant | Decision | Reason |', '| --- | --- | --- |')
        foreach ($decision in $report.decisions) {
            $summary += "| $($decision['variant']) | $($decision['status']) | $($decision['reason']) |"
        }
        if ($report.Contains('error')) { $summary += @('', 'The check stopped before it could safely complete. Existing published downloads were not changed.') }
        $summary | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
    if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force }
}
