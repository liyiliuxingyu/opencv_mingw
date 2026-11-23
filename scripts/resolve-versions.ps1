#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$OpenCVVersion = 'latest',
    [string]$WinLibsVersion = 'latest',
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$headers = @{
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'opencv-mingw-release-builder'
}
$apiToken = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
if ($apiToken) { $headers.Authorization = "Bearer $apiToken" }

function Get-GitHubJson([string]$Path) {
    Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers `
        -MaximumRetryCount 3 -RetryIntervalSec 3 -TimeoutSec 120
}

function Get-StableRelease([string]$Repository, [string]$Version) {
    if ($Version -eq 'latest') {
        $release = Get-GitHubJson "repos/$Repository/releases/latest"
    } else {
        if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
            throw "Invalid release tag: $Version"
        }
        $tag = [Uri]::EscapeDataString($Version)
        $release = Get-GitHubJson "repos/$Repository/releases/tags/$tag"
    }
    if ($release.draft -or $release.prerelease) {
        throw "$Repository/$($release.tag_name) is not a stable published release."
    }
    return $release
}

function Get-TagCommit([string]$Repository, [string]$Tag) {
    $escapedTag = [Uri]::EscapeDataString($Tag)
    $reference = Get-GitHubJson "repos/$Repository/git/ref/tags/$escapedTag"
    $object = $reference.object
    for ($depth = 0; $object.type -eq 'tag' -and $depth -lt 8; $depth++) {
        $annotation = Get-GitHubJson "repos/$Repository/git/tags/$($object.sha)"
        $object = $annotation.object
    }
    if ($object.type -ne 'commit' -or $object.sha -notmatch '^[0-9a-f]{40}$') {
        throw "Cannot resolve $Repository tag $Tag to a full commit SHA."
    }
    return [string]$object.sha
}

$opencvRelease = Get-StableRelease 'opencv/opencv' $OpenCVVersion
$opencvTag = [string]$opencvRelease.tag_name
if ($opencvTag -notmatch '^\d+\.\d+\.\d+$') {
    throw "Expected a stable numeric OpenCV version, got '$opencvTag'."
}
$opencvCommit = Get-TagCommit 'opencv/opencv' $opencvTag
$contribCommit = Get-TagCommit 'opencv/opencv_contrib' $opencvTag

$winlibsRelease = Get-StableRelease 'brechtsanders/winlibs_mingw' $WinLibsVersion
$assetPattern = '^winlibs-x86_64-posix-seh-gcc-(?<gcc>\d+\.\d+\.\d+)-mingw-w64ucrt-(?<mingw>\d+\.\d+\.\d+)-r\d+\.7z$'
$assets = @($winlibsRelease.assets | Where-Object { $_.name -match $assetPattern })
if ($assets.Count -ne 1) {
    throw "Release '$($winlibsRelease.tag_name)' must contain exactly one x64 POSIX/SEH UCRT GCC-only .7z asset; found $($assets.Count). Select a compatible stable WinLibs release explicitly."
}
$asset = $assets[0]
$assetMatch = [regex]::Match($asset.name, $assetPattern)
$gccVersion = $assetMatch.Groups['gcc'].Value
$mingwVersion = $assetMatch.Groups['mingw'].Value
$downloadPrefix = 'https://github.com/brechtsanders/winlibs_mingw/releases/download/'
if (-not ([string]$asset.browser_download_url).StartsWith($downloadPrefix, [StringComparison]::Ordinal)) {
    throw 'WinLibs asset URL is outside its official GitHub release repository.'
}

$sha256 = $null
if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
    $sha256 = $Matches[1].ToLowerInvariant()
} else {
    $checksumAssets = @($winlibsRelease.assets | Where-Object { $_.name -eq "$($asset.name).sha256" })
    if ($checksumAssets.Count -ne 1) { throw 'No SHA-256 digest or checksum sidecar is available for the selected toolchain.' }
    $checksumUrl = [string]$checksumAssets[0].browser_download_url
    if (-not $checksumUrl.StartsWith($downloadPrefix, [StringComparison]::Ordinal)) {
        throw 'WinLibs checksum URL is outside its official GitHub release repository.'
    }
    $checksumText = (Invoke-WebRequest -Uri $checksumUrl -MaximumRetryCount 3 -RetryIntervalSec 3 -TimeoutSec 120).Content
    $hashMatches = [regex]::Matches([string]$checksumText, '(?i)\b[0-9a-f]{64}\b')
    if ($hashMatches.Count -ne 1) { throw 'The WinLibs checksum sidecar is ambiguous or invalid.' }
    $sha256 = $hashMatches[0].Value.ToLowerInvariant()
}

$packageName = "opencv-$opencvTag-mingw-$mingwVersion-gcc-$gccVersion-x64"
$lock = [ordered]@{
    schema_version = 1
    resolved_at_utc = [DateTime]::UtcNow.ToString('o')
    package_name = $packageName
    opencv_version = $opencvTag
    opencv_commit = $opencvCommit
    opencv_repository = 'https://github.com/opencv/opencv.git'
    opencv_release_url = [string]$opencvRelease.html_url
    contrib_commit = $contribCommit
    contrib_repository = 'https://github.com/opencv/opencv_contrib.git'
    contrib_tag = $opencvTag
    winlibs_version = [string]$winlibsRelease.tag_name
    winlibs_release_url = [string]$winlibsRelease.html_url
    winlibs_asset_name = [string]$asset.name
    winlibs_asset_url = [string]$asset.browser_download_url
    winlibs_sha256 = $sha256
    gcc_version = $gccVersion
    mingw_version = $mingwVersion
    architecture = 'x86_64'
    threading = 'posix'
    exceptions = 'seh'
    crt = 'ucrt'
}

$OutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath -Parent) | Out-Null
$lock | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
if ($env:GITHUB_OUTPUT) {
    foreach ($name in @('opencv_version', 'winlibs_version', 'gcc_version', 'mingw_version', 'package_name')) {
        "$name=$($lock[$name])" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
    "lock_file=$OutputPath" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
Write-Host "Resolved OpenCV $opencvTag + contrib $opencvTag; GCC $gccVersion / MinGW-w64 $mingwVersion (x64, POSIX, SEH, UCRT)."
Write-Host "Exact commits and toolchain SHA-256 recorded in $OutputPath"
