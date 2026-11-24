#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkRoot,
    [ValidatePattern('^13\.\d+\.\d+$')][string]$CudaVersion = '13.5.0',
    [ValidatePattern('^9\.\d+\.\d+$')][string]$CudnnVersion = '9.28.1',
    [string]$ExpectedLockFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $IsWindows) { throw 'This helper installs the native Windows x64 CUDA development files.' }
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$cudaRoot = Join-Path $WorkRoot 'cuda'
$cudnnRoot = Join-Path $WorkRoot 'cudnn'
$downloadRoot = Join-Path $WorkRoot 'downloads'
$manifestRoot = Join-Path $WorkRoot 'manifests'
foreach ($path in @($cudaRoot, $cudnnRoot)) {
    if (Test-Path -LiteralPath $path) { throw "Use a fresh CUDA work directory: $path already exists." }
}
New-Item -ItemType Directory -Force -Path $WorkRoot, $cudaRoot, $cudnnRoot, $downloadRoot, $manifestRoot | Out-Null

function Get-NvidiaManifest([string]$Product, [string]$Version) {
    $url = "https://developer.download.nvidia.com/compute/$Product/redist/redistrib_$Version.json"
    $path = Join-Path $manifestRoot "$Product-$Version.json"
    Invoke-WebRequest -Uri $url -OutFile $path -MaximumRetryCount 3 -RetryIntervalSec 5 -TimeoutSec 120
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($manifest.release_label -ne $Version -or $manifest.release_product -ne $Product) {
        throw "Unexpected NVIDIA $Product release manifest at $url"
    }
    return [pscustomobject]@{
        manifest = $manifest
        url = $url
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function New-ComponentRecord([object]$Manifest, [string]$Product, [string]$Name, [string]$Destination) {
    $component = $Manifest.PSObject.Properties[$Name]
    if (-not $component) { throw "The $Product manifest has no $Name component." }
    $item = $component.Value
    $platform = $item.PSObject.Properties['windows-x86_64']
    if (-not $platform) { throw "$Name is unavailable for Windows x64." }
    $asset = $platform.Value
    if ($Product -eq 'cudnn') { $asset = $asset.cuda13 }
    if ($asset.sha256 -notmatch '^[0-9a-f]{64}$' -or $asset.relative_path -notmatch '^[A-Za-z0-9_./-]+\.zip$' -or
        $asset.relative_path -match '(?:^|/)\.\.(?:/|$)') {
        throw "Invalid $Name archive metadata in the NVIDIA manifest."
    }
    return [ordered]@{
        name = $Name
        product = $Product
        version = [string]$item.version
        platform = 'windows-x86_64'
        url = "https://developer.download.nvidia.com/compute/$Product/redist/$($asset.relative_path)"
        sha256 = [string]$asset.sha256
        archive_bytes = [long]$asset.size
        license = [string]$item.license
        destination = $Destination
    }
}

function Expand-Component([Collections.IDictionary]$Component) {
    $archivePath = Join-Path $downloadRoot ([IO.Path]::GetFileName([string]$Component.url))
    Write-Host "Downloading $($Component.name) $($Component.version) ($([math]::Round($Component.archive_bytes / 1MB)) MiB)."
    Invoke-WebRequest -Uri $Component.url -OutFile $archivePath -MaximumRetryCount 3 -RetryIntervalSec 5 -TimeoutSec 1800
    $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Component.sha256) { throw "NVIDIA archive SHA-256 mismatch: $archivePath" }
    $destination = Join-Path $WorkRoot ([string]$Component.destination)
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    $count = 0
    $bytes = [long]0
    try {
        foreach ($entry in $archive.Entries) {
            if (-not $entry.Name) { continue }
            $entryName = $entry.FullName.Replace('\', '/')
            $slash = $entryName.IndexOf('/')
            if ($slash -lt 1) { throw "Unexpected archive layout: $entryName" }
            $relative = $entryName.Substring($slash + 1)
            if ($relative -match '(^|/)\.\.(?:/|$)' -or $relative -match '[:\\]' -or $relative.StartsWith('/')) {
                throw "Unsafe archive entry: $entryName"
            }
            # Shared OpenCV needs import libraries, not the large static math
            # archives or NVIDIA PDBs. Retain CUDA's compiler support archives.
            if ($relative -match '(?i)\.pdb$' -or
                ($relative -match '(?i)_static[0-9_]*\.lib$' -and $entry.Name -ne 'cudart_static.lib')) { continue }
            if ($relative -match '(?i)(^|/)(LICENSE[^/]*|COPYING[^/]*|NOTICE[^/]*)$') {
                $relative = "licenses/$($Component.name)/$relative"
            }
            $target = [IO.Path]::GetFullPath((Join-Path $destination $relative))
            $contained = [IO.Path]::GetRelativePath($destination, $target)
            if ([IO.Path]::IsPathRooted($contained) -or $contained -match '^\.\.(?:[\\/]|$)') {
                throw "Archive entry escapes its destination: $entryName"
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            $inputStream = $entry.Open()
            try {
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $incoming = [Convert]::ToHexString($sha.ComputeHash($inputStream)).ToLowerInvariant() }
                    finally { $sha.Dispose() }
                    if ($incoming -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()) {
                        throw "NVIDIA components contain conflicting files: $relative"
                    }
                } else {
                    $outputStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew)
                    try { $inputStream.CopyTo($outputStream) }
                    finally { $outputStream.Dispose() }
                }
            } finally { $inputStream.Dispose() }
            $count++
            $bytes += $entry.Length
        }
    } finally { $archive.Dispose() }
    # Avoid keeping several gigabytes of compressed copies beside the toolkit.
    Remove-Item -LiteralPath $archivePath -Force
    $Component['installed_files'] = $count
    $Component['installed_bytes'] = $bytes
}

function Assert-ExpectedCudaLock([object]$Expected, [Collections.IDictionary]$Actual) {
    if ($Expected.schema_version -ne 1 -or $Expected.cuda_version -ne $Actual.cuda_version -or
        $Expected.cudnn_version -ne $Actual.cudnn_version) { throw 'The expected CUDA dependency lock targets a different release.' }
    foreach ($collection in @('manifests', 'components', 'python_runtime_wheels')) {
        $identity = switch ($collection) { 'manifests' { 'url' } 'components' { 'name' } default { 'package' } }
        $fields = switch ($collection) {
            'manifests' { @('url', 'sha256') }
            'components' { @('name', 'product', 'version', 'platform', 'url', 'sha256', 'archive_bytes', 'destination') }
            default { @('package', 'version', 'filename', 'url', 'sha256', 'size_bytes') }
        }
        $expectedItems = @($Expected.$collection)
        $actualItems = @($Actual[$collection])
        if ($expectedItems.Count -ne $actualItems.Count) { throw "The $collection count differs from the original CUDA dependency lock." }
        foreach ($item in $actualItems) {
            $matching = @($expectedItems | Where-Object { $_.$identity -eq $item[$identity] })
            if ($matching.Count -ne 1) { throw "The original CUDA dependency lock has no unique $collection entry for $($item[$identity])." }
            foreach ($field in $fields) {
                if ([string]$matching[0].$field -cne [string]$item[$field]) {
                    throw "CUDA dependency changed since the original build: $($item[$identity]) / $field"
                }
            }
        }
    }
}

$cuda = Get-NvidiaManifest 'cuda' $CudaVersion
$cudnn = Get-NvidiaManifest 'cudnn' $CudnnVersion
$components = [Collections.Generic.List[object]]::new()
# CUDA 13 splits NVCC, the compiler runtime headers, and NVVM/libdevice into
# separate redistributables. cuRAND headers are used by contrib CUDA modules.
$componentNames = @('cccl', 'cuda_crt', 'cuda_cudart', 'cuda_nvcc', 'libnvvm',
    'libcublas', 'libcufft', 'libcurand', 'libnpp', 'cuda_nvrtc', 'libnvjitlink')
foreach ($name in $componentNames) { $components.Add((New-ComponentRecord $cuda.manifest 'cuda' $name 'cuda')) }
$components.Add((New-ComponentRecord $cudnn.manifest 'cudnn' 'cudnn' 'cudnn'))

# Toolkit wheels use unsuffixed names from CUDA 13 onward; cuDNN retains -cu13.
$runtimeMap = [ordered]@{
    'nvidia-cuda-runtime' = 'cuda_cudart'
    'nvidia-cublas' = 'libcublas'
    'nvidia-cufft' = 'libcufft'
    'nvidia-curand' = 'libcurand'
    'nvidia-npp' = 'libnpp'
    'nvidia-cuda-nvrtc' = 'cuda_nvrtc'
    'nvidia-nvjitlink' = 'libnvjitlink'
    'nvidia-cudnn-cu13' = 'cudnn'
}
$pythonPackages = [ordered]@{}
$pythonWheels = [Collections.Generic.List[object]]::new()
foreach ($package in $runtimeMap.Keys) {
    $component = @($components | Where-Object { $_.name -eq $runtimeMap[$package] })
    if ($component.Count -ne 1) { throw "Missing runtime component for $package" }
    $pythonPackages[$package] = [string]$component[0].version
    $packageVersion = [string]$component[0].version
    $packageInfo = Invoke-RestMethod -Uri "https://pypi.org/pypi/$package/$packageVersion/json" `
        -MaximumRetryCount 3 -RetryIntervalSec 5 -TimeoutSec 120
    $wheels = @($packageInfo.urls | Where-Object { $_.filename -like '*-win_amd64.whl' -and -not $_.yanked })
    if ($wheels.Count -ne 1 -or $wheels[0].digests.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "Expected one published Windows x64 runtime wheel: $package==$packageVersion"
    }
    $pythonWheels.Add([ordered]@{
        package = $package
        version = $packageVersion
        filename = $wheels[0].filename
        url = $wheels[0].url
        sha256 = $wheels[0].digests.sha256
        size_bytes = [long]$wheels[0].size
    })
}
$lock = [ordered]@{
    schema_version = 1
    cuda_version = $CudaVersion
    cuda_nvcc_version = [string]$cuda.manifest.cuda_nvcc.version
    cudnn_version = $CudnnVersion
    resolved_at_utc = [DateTime]::UtcNow.ToString('o')
    platform = 'windows-x86_64'
    manifests = @(
        [ordered]@{ url = $cuda.url; sha256 = $cuda.sha256 },
        [ordered]@{ url = $cudnn.url; sha256 = $cudnn.sha256 }
    )
    components = $components.ToArray()
    python_runtime_packages = $pythonPackages
    python_runtime_wheels = $pythonWheels.ToArray()
    extraction_policy = 'Retain shared runtime and development files; omit NVIDIA PDBs and static math/cuDNN libraries (including *_static64_9.lib); retain cudart_static.lib for compiler probes; preserve component licenses.'
    driver_included = $false
}
$lockPath = Join-Path $WorkRoot 'versions.cuda.lock.json'
if ($ExpectedLockFile) {
    $expected = Get-Content -LiteralPath $ExpectedLockFile -Raw | ConvertFrom-Json
    Assert-ExpectedCudaLock $expected $lock
    Write-Host 'Exact CUDA component manifests, archives and Windows runtime wheels match the original dependency lock.'
}
$lock | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $lockPath -Encoding utf8NoBOM
foreach ($component in $components) { Expand-Component $component }
$lock | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $lockPath -Encoding utf8NoBOM

foreach ($relative in @('bin/nvcc.exe', 'nvvm/bin/cicc.exe', 'nvvm/libdevice/libdevice.10.bc',
                         'include/cuda_runtime.h', 'include/crt/host_config.h', 'lib/x64/cudart.lib',
                         'include/cublas_v2.h', 'lib/x64/cublas.lib', 'include/npp.h', 'lib/x64/nppc.lib')) {
    if (-not (Test-Path -LiteralPath (Join-Path $cudaRoot $relative) -PathType Leaf)) { throw "Incomplete CUDA development files: $relative" }
}
$cudnnHeaders = @(Get-ChildItem -LiteralPath $cudnnRoot -Recurse -File -Filter 'cudnn.h')
$cudnnLibraries = @(Get-ChildItem -LiteralPath $cudnnRoot -Recurse -File -Filter 'cudnn.lib')
if ($cudnnHeaders.Count -ne 1 -or $cudnnLibraries.Count -ne 1) { throw 'Expected exactly one cuDNN header directory and import library.' }
$runtimeDirs = @(Get-ChildItem -LiteralPath $cudaRoot, $cudnnRoot -Recurse -File -Filter '*.dll' |
    Where-Object { $_.FullName -notlike '*\nvvm\*' } | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
if ($runtimeDirs.Count -eq 0) { throw 'No CUDA/cuDNN runtime DLL directories were extracted.' }
$state = [ordered]@{
    schema_version = 1
    cuda_version = $CudaVersion
    cuda_nvcc_version = [string]$cuda.manifest.cuda_nvcc.version
    cudnn_version = $CudnnVersion
    cudnn_component_version = [string]$cudnn.manifest.cudnn.version
    cuda_root = $cudaRoot
    cudnn_root = $cudnnRoot
    nvcc_executable = (Join-Path $cudaRoot 'bin/nvcc.exe')
    cudnn_include_dir = $cudnnHeaders[0].DirectoryName
    cudnn_library = $cudnnLibraries[0].FullName
    runtime_bin_dirs = $runtimeDirs
    python_runtime_packages = $pythonPackages
    lock_file = $lockPath
    installed_bytes = [long](($components | Measure-Object -Property installed_bytes -Sum).Sum)
}
$statePath = Join-Path $WorkRoot 'cuda-state.json'
$state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
Write-Host "CUDA $CudaVersion and cuDNN $CudnnVersion are prepared: $statePath"
[pscustomobject]$state
