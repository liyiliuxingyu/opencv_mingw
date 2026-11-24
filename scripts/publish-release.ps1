#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$SourceCommit = $env:GITHUB_SHA
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$result = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json
$outputDir = Split-Path -Parent (Resolve-Path -LiteralPath $ResultFile).Path
$verificationPath = Join-Path $outputDir 'verification.json'
$verification = Get-Content -LiteralPath $verificationPath -Raw | ConvertFrom-Json
if ($verification.result -ne 'passed' -or $verification.package_name -ne $result.package_name) {
    throw 'A matching successful distribution verification is required before publication.'
}
foreach ($key in @('GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')) {
    if (-not [Environment]::GetEnvironmentVariable($key)) { throw "Missing CI context: $key" }
}
if ($SourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'The release target must be an exact source commit SHA.' }
if ($verification.workflow_commit -ne $env:GITHUB_SHA -or
    [string]$verification.github_run_id -ne $env:GITHUB_RUN_ID -or
    [string]$verification.github_run_attempt -ne $env:GITHUB_RUN_ATTEMPT) {
    throw 'The verification report must belong to this workflow commit, run and attempt.'
}
$originPath = Join-Path $outputDir 'candidate-origin.json'
$sourceRunId = $env:GITHUB_RUN_ID
$sourceRunAttempt = $env:GITHUB_RUN_ATTEMPT
$originNote = ''
if (Test-Path -LiteralPath $originPath -PathType Leaf) {
    $origin = Get-Content -LiteralPath $originPath -Raw | ConvertFrom-Json
    if ($origin.schema_version -ne 1 -or $origin.checkpoint_status -ne 'unverified' -or
        $origin.repository -ne $env:GITHUB_REPOSITORY -or
        $origin.workflow_path -ne '.github/workflows/build-windows.yml' -or
        $origin.package_name -ne $result.package_name -or $origin.source_commit -ne $SourceCommit -or
        [string]$origin.source_run_id -notmatch '^[1-9][0-9]*$' -or
        [string]$origin.source_run_attempt -notmatch '^[1-9][0-9]*$') {
        throw 'Candidate provenance does not match the package and original release target.'
    }
    $sourceRunId = [string]$origin.source_run_id
    $sourceRunAttempt = [string]$origin.source_run_attempt
    $originDigest = (Get-FileHash -LiteralPath $originPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $originChecksum = @(Get-Content -LiteralPath $result.checksums_path | Where-Object { $_ -match '  candidate-origin\.json$' })
    if ($originChecksum.Count -ne 1 -or $originChecksum[0] -ne "$originDigest  candidate-origin.json") {
        throw 'The public checksums must include the unchanged candidate provenance.'
    }
    $originNote = '- **candidate-origin.json**：原始构建运行与提交；checkpoint_status 记录保存候选包时的状态，最终验证结果见 verification.json。'
} elseif ($SourceCommit -ne $env:GITHUB_SHA) {
    throw 'Publishing an earlier build commit requires its candidate provenance.'
}
# Run numbers are local to a workflow; run IDs stay unique across build and recovery workflows.
$tag = "$($result.package_name)-r$env:GITHUB_RUN_ID-a$env:GITHUB_RUN_ATTEMPT"
$title = "OpenCV $($result.opencv_version) + MinGW-w64 $($result.mingw_version) / GCC $($result.gcc_version) (x64)"
$lock = Get-Content -LiteralPath $result.build_lock_path -Raw | ConvertFrom-Json
$notes = @"
## Windows x64 安装包

本次从 OpenCV **$($result.opencv_version)** 与同版本 contrib 源码构建，使用 **GCC $($result.gcc_version) / MinGW-w64 $($result.mingw_version)**，UCRT、POSIX 线程、SEH 异常模型。

- **setup.exe**：图形安装程序，默认安装到当前用户目录，包含 OpenCV、完整匹配编译器、CMake、Ninja、运行库和最小示例。
- **.zip**：相同内容的便携包；解压后在命令提示符中调用 activate.cmd，再运行 build-example.cmd。
- **SHA256SUMS**：下载校验值。
- **build-lock.json / build-info.json**：完整源码提交、工具链下载与 SHA-256、实际构建功能。
- **verification.json**：Windows 原生编译、运行、ZIP 搬迁、静默安装与卸载结果。
$originNote

### 已通过的发布检查

三个独立目录分别使用随包工具链编译并运行消费示例；验证版本一致性、像素转换、PNG 读写、FFmpeg 视频读写和 OpenMP 功能。运行测试移除了编译工具链的 PATH，验证打包后的运行依赖。

### 版本记录

- OpenCV: $($lock.opencv_commit)
- contrib: $($lock.contrib_commit)
- WinLibs: $($lock.winlibs_version)
- 构建脚本提交: $SourceCommit
- 原始构建运行: https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$sourceRunId (attempt $sourceRunAttempt)
- 验证脚本提交: $env:GITHUB_SHA
- 本次验证运行: https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID (attempt $env:GITHUB_RUN_ATTEMPT)

需要 Windows 10/11 x64；这是 MinGW C++ SDK，未包含 Python cv2 绑定、CUDA 或独立 Debug 库。EXE 未使用代码签名证书签名。安装会创建当前用户的开始菜单入口和卸载项，开发命令提示符负责配置当前进程环境。
"@
$notesPath = Join-Path $outputDir 'release-notes.md'
$notes | Set-Content -LiteralPath $notesPath -Encoding utf8NoBOM
$files = @($result.installer_path, $result.zip_path, $result.build_info_path,
    $result.build_lock_path, $result.checksums_path, $verificationPath)
if (Test-Path -LiteralPath $originPath -PathType Leaf) { $files += $originPath }
foreach ($path in $files) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing release file: $path" }
}
& gh release create $tag @files --repo $env:GITHUB_REPOSITORY --target $SourceCommit `
    --title $title --notes-file $notesPath --latest
if ($LASTEXITCODE -ne 0) { throw "GitHub release creation failed (exit $LASTEXITCODE)." }
$url = "https://github.com/$env:GITHUB_REPOSITORY/releases/tag/$tag"
if ($env:GITHUB_OUTPUT) { "release_url=$url" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
if ($env:GITHUB_STEP_SUMMARY) { "`n[Download EXE and ZIP]($url)" | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
Write-Host $url
& (Join-Path $PSScriptRoot 'request-download-index-update.ps1')
