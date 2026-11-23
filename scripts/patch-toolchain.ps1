#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolchainRoot,
    [string]$LogDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$ToolchainRoot = (Resolve-Path -LiteralPath $ToolchainRoot).Path
$gcc = Join-Path $ToolchainRoot 'bin/gcc.exe'
if (-not (Test-Path -LiteralPath $gcc -PathType Leaf)) { throw "GCC was not found: $gcc" }
if (-not $LogDir) { $LogDir = Join-Path $ToolchainRoot 'build-info' }
$LogDir = [IO.Path]::GetFullPath($LogDir)
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Invoke-GccQuery([string]$Argument, [switch]$Raw) {
    $lines = @(& $gcc $Argument)
    if ($LASTEXITCODE -ne 0) { throw "GCC $Argument failed with exit code $LASTEXITCODE." }
    if ($Raw) { return ($lines -join "`n") + "`n" }
    return ($lines -join "`n").TrimEnd("`r", "`n")
}

function Get-BytesHash([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

$target = Invoke-GccQuery '-dumpmachine'
$version = Invoke-GccQuery '-dumpfullversion'
if ($target -ne 'x86_64-w64-mingw32') { throw "Unsupported compiler target: $target" }
if ($version -notmatch '^\d+\.\d+(?:\.\d+)?$') { throw "Unexpected GCC version: $version" }
$libgcc = Invoke-GccQuery '-print-libgcc-file-name'
if (-not (Test-Path -LiteralPath $libgcc -PathType Leaf)) { throw "GCC did not locate its libgcc archive: $libgcc" }
$privateLibDir = Split-Path -Parent ([IO.Path]::GetFullPath($libgcc))
$relativeLibDir = [IO.Path]::GetRelativePath($ToolchainRoot, $privateLibDir)
if ([IO.Path]::IsPathRooted($relativeLibDir) -or $relativeLibDir -match '^\.\.(?:[\\/]|$)') {
    throw "GCC's private library directory is outside the requested toolchain: $privateLibDir"
}
$specsPath = Join-Path $privateLibDir 'specs'
$backupPath = Join-Path $privateLibDir 'specs.opencv-mingw.original'

# -dumpspecs prints built-in specs, even when an installed specs file exists.
# Read an existing file directly so vendor/user overrides survive this patch.
$builtInSpecs = Invoke-GccQuery '-dumpspecs' -Raw
$utf8 = [Text.UTF8Encoding]::new($false)
$bytes = $utf8.GetBytes($builtInSpecs)
$sourceKind = 'gcc-built-in-specs'
$reportedSpecs = Invoke-GccQuery '-print-file-name=specs'
if ($reportedSpecs -ne 'specs' -and (Test-Path -LiteralPath $reportedSpecs -PathType Leaf)) {
    $reportedSpecs = [IO.Path]::GetFullPath($reportedSpecs)
    if (-not $reportedSpecs.Equals($specsPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "GCC uses a different specs file; refusing to shadow it: $reportedSpecs"
    }
}
if (Test-Path -LiteralPath $specsPath -PathType Leaf) {
    $bytes = [IO.File]::ReadAllBytes($specsPath)
    $sourceKind = 'installed-specs'
}

# Latin-1 provides a reversible byte-to-character mapping. Everything outside
# the exact ASCII expression stays byte-for-byte intact, including line endings.
$encoding = [Text.Encoding]::Latin1
$original = $encoding.GetString($bytes)
$before = '%:if-exists(default-manifest.o%s)'
$after = '%:if-exists-then-else(default-manifest.o%s default-manifest.o%%s)'
$count = [regex]::Matches($original, [regex]::Escape($before)).Count
$status = 'not-needed'
$reason = 'No affected default-manifest expression was found; specs were not changed.'
$originalHash = Get-BytesHash $bytes
$patched = $original

if ($count -gt 0) {
    # if-exists returns an absolute path which GCC parses again as spec text,
    # splitting spaces. Return an unexpanded file%s token instead. %% delays
    # that final %s until the returned text is parsed; the existence check and
    # surrounding shared/mdll conditions retain their original behavior.
    $patched = $original.Replace($before, $after)
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $originalHash) {
            throw "A different original specs backup already exists: $backupPath"
        }
    } else {
        [IO.File]::WriteAllBytes($backupPath, $bytes)
    }
    $temporaryPath = "$specsPath.opencv-mingw.tmp"
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $encoding.GetBytes($patched))
        [IO.File]::Move($temporaryPath, $specsPath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
    $status = 'patched'
    $reason = 'Preserve the default manifest and its optional existence check while handling installation paths containing spaces.'
} elseif ($original.Contains($after)) {
    $status = 'already-patched'
    $reason = 'The exact path-safe expression is already installed; specs were not changed.'
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        $originalHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
} elseif ($sourceKind -eq 'installed-specs' -and $builtInSpecs.Contains($before) -and
          $original -notmatch '(?m)^\*endfile:') {
    # A partial override can inherit the affected built-in endfile spec.
    # Do not silently claim success or replace unrelated custom instructions.
    throw 'An existing partial specs file inherits an affected built-in endfile spec; review this custom toolchain before patching.'
}

$patchedBytes = $encoding.GetBytes($patched)
$patchedHash = Get-BytesHash $patchedBytes
[IO.File]::WriteAllBytes((Join-Path $LogDir 'toolchain-specs.before.txt'), $bytes)
[IO.File]::WriteAllBytes((Join-Path $LogDir 'toolchain-specs.after.txt'), $patchedBytes)
$report = [ordered]@{
    schema_version = 1
    patch_id = 'gcc-default-manifest-path-spaces-v1'
    status = $status
    reason = $reason
    compiler_target = $target
    gcc_version = $version
    source_kind = $sourceKind
    specs_path = [IO.Path]::GetRelativePath($ToolchainRoot, $specsPath).Replace('\', '/')
    original_sha256 = $originalHash
    input_sha256 = (Get-BytesHash $bytes)
    patched_sha256 = $patchedHash
    replacements = $count
    original_expression = $before
    replacement_expression = $after
    upstream_issue = 'https://github.com/brechtsanders/winlibs_mingw/issues/298'
    spec_documentation = 'https://gcc.gnu.org/onlinedocs/gccint/Spec-Files.html'
}
$reportPath = Join-Path $LogDir 'toolchain-patch.json'
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
Write-Host "Toolchain manifest compatibility: $status (GCC $version); report: $reportPath"
[pscustomobject]$report
