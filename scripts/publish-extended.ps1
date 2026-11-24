#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultFile,
    [Parameter(Mandatory)][ValidateSet('mingw-release-python','mingw-debug','cuda-release-python')][string]$Variant,
    [string]$SourceCommit,
    [switch]$PrepareOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$result = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json
$output = Split-Path -Parent (Resolve-Path -LiteralPath $ResultFile).Path
$info = Get-Content -LiteralPath $result.build_info_path -Raw | ConvertFrom-Json
$lock = Get-Content -LiteralPath $result.build_lock_path -Raw | ConvertFrom-Json
$verificationPath = Join-Path $output 'verification.json'
$verification = Get-Content -LiteralPath $verificationPath -Raw | ConvertFrom-Json
if ($verification.result -ne 'passed' -or $verification.package_name -ne $result.package_name -or
    $verification.github_run_id -ne $env:GITHUB_RUN_ID -or $verification.github_run_attempt -ne $env:GITHUB_RUN_ATTEMPT -or
    $verification.workflow_commit -ne $env:GITHUB_SHA) {
    throw 'Publication requires successful distribution verification from this exact workflow run, attempt and commit.'
}
$originPath = Join-Path $output 'candidate-origin.json'
$origin = Get-Content -LiteralPath $originPath -Raw | ConvertFrom-Json
if (-not $SourceCommit) { $SourceCommit = [string]$origin.source_commit }
if ($SourceCommit -notmatch '^[0-9a-f]{40}$' -or $origin.repository -ne $env:GITHUB_REPOSITORY -or
    $origin.workflow_path -ne '.github/workflows/build-extended.yml' -or $origin.variant -ne $Variant -or
    $origin.package_name -ne $result.package_name -or $origin.source_commit -ne $SourceCommit -or
    $origin.source_ref -ne $env:GITHUB_REF -or $env:GITHUB_REF -notmatch '^refs/heads/') {
    throw 'The candidate provenance does not match this repository, branch, variant and source commit.'
}
if ($info.package_name -ne $result.package_name -or $lock.package_name -ne $result.package_name -or
    $info.configuration -ne $verification.configuration) { throw 'Package metadata and verification disagree.' }
$isCuda = $Variant -eq 'cuda-release-python'
$isDebug = $Variant -eq 'mingw-debug'
$hasPython = [bool]$info.python_bindings
if ($isDebug) {
    if ($info.configuration -ne 'Debug' -or $info.library_layout -ne 'modular' -or $info.debug_symbols -ne 'embedded-dwarf' -or $hasPython) {
        throw 'The Debug release requires independent modular Debug libraries with DWARF symbols.'
    }
} elseif ($info.configuration -ne 'Release' -or -not $hasPython) { throw 'Python editions require Release cv2 bindings.' }
if (($isCuda -and $info.toolchain_kind -ne 'msvc') -or (-not $isCuda -and $info.toolchain_kind -ne 'mingw')) {
    throw 'Compiler family does not match the requested variant.'
}
$files = @($result.installer_path, $result.zip_path, $result.build_info_path, $result.build_lock_path, $verificationPath, $originPath)
$wheelReport = $null
if ($hasPython) {
    $wheels = @(Get-ChildItem -LiteralPath $output -File -Filter '*.whl')
    if ($wheels.Count -ne 1) { throw 'Exactly one matching Python wheel must accompany this SDK.' }
    $wheelReportPath = Join-Path $output 'python-wheel-verification.json'
    $wheelReport = Get-Content -LiteralPath $wheelReportPath -Raw | ConvertFrom-Json
    if ($wheelReport.result -ne 'passed' -or $wheelReport.package_mode -ne 'wheel' -or
        $wheelReport.wheel_sha256 -ne (Get-FileHash -LiteralPath $wheels[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'The exact wheel must pass clean-environment import and functional verification.'
    }
    $files += @($wheels[0].FullName, $wheelReportPath, (Join-Path $output 'python-wheel-result.json'))
    if (-not $isCuda) {
        if (@($verification.python_checks).Count -ne 3 -or @($verification.python_checks | Where-Object { $_.report.result -ne 'passed' }).Count) {
            throw 'Python must pass in all three SDK locations.'
        }
    }
}
$gpuVerified = $false
if ($isCuda) {
    if (@($verification.locations).Count -ne 3 -or @($verification.locations | Where-Object { $_.cpp -ne 'passed' -or $_.python.result -ne 'passed' }).Count) {
        throw 'CUDA SDK C++ and Python distribution checks must pass in all three locations.'
    }
    $gpuVerified = $verification.gpu_execution -eq 'passed' -and $wheelReport.gpu_execution -eq 'passed' -and
        @($verification.locations | Where-Object { $_.gpu.gpu_execution -ne 'passed' -or $_.python.gpu_execution -ne 'passed' }).Count -eq 0
}
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing release asset: $file" }
    if ((Get-Item -LiteralPath $file).Length -ge 2GB) { throw "Release assets must be smaller than 2 GiB: $file" }
    $relative = [IO.Path]::GetRelativePath($output, [IO.Path]::GetFullPath($file))
    if ($relative -match '[\\/]' -or [IO.Path]::IsPathRooted($relative)) { throw 'Release assets must be direct children of the output directory.' }
}
$checksums = foreach ($file in $files | Sort-Object) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant(), [IO.Path]::GetFileName($file)
}
$checksums | Set-Content -LiteralPath $result.checksums_path -Encoding utf8NoBOM
$files += $result.checksums_path
$pythonNote = if ($hasPython) {
    "CPython **$($info.python.major_minor) x64**，ABI **$($info.python.abi)**；NumPy **$($info.python.numpy_version)**。EXE/ZIP 内含相同 wheel，运行 ``install-python.cmd`` 创建独立虚拟环境。CPU 与 CUDA 的 wheel 均提供 ``cv2``，请使用不同环境。"
} else { '这是独立 C++ Debug SDK，包含模块 DLL、导入库、DWARF 调试信息和 GDB，不包含 Debug Python。消费者必须选择 CMAKE_BUILD_TYPE=Debug。' }
if ($isCuda) {
    $title = "OpenCV $($info.opencv_version) CUDA $($info.cuda_version) / Python $($info.python.major_minor) x64"
    $description = "MSVC **$($info.msvc_version)**，CUDA **$($info.cuda_version)**，cuDNN **$($info.cudnn_version)**。此 SDK 使用 MSVC C++ ABI；C++ 开发需要 Visual Studio 2022 C++ Build Tools、CMake/Ninja 和匹配的 CUDA/cuDNN。Python wheel 通过精确版本的 NVIDIA pip 依赖安装运行库。"
    $gpuNote = if ($gpuVerified) { 'GPU 功能样例已通过；具体设备和结果见 verification.json。' } else {
        '**CUDA 预发布：已完成编译、链接、cv2 导入、CPU 功能及分发检查；当前 GitHub 托管运行器没有兼容 NVIDIA GPU，GPU 执行尚未验证。** C++ 用户可在目标显卡上运行包内 build-example.cmd；Python 用户请按 README 检查实际设备并验证所需 GPU 算法。'
    }
    $specific = "$gpuNote`n`n默认不包含需要另行提供 NVIDIA Video Codec SDK 的 cudacodec。GPU 架构列表与精确依赖记录在 build-lock.json。"
} else {
    $title = "OpenCV $($info.opencv_version) MinGW $($info.configuration) / GCC $($info.gcc_version) x64"
    $description = "GCC **$($info.gcc_version)** / MinGW-w64 **$($info.mingw_version)**，UCRT、POSIX、SEH。EXE/ZIP 包含匹配的完整编译器、CMake、Ninja 及运行库。"
    $specific = if ($isDebug) {
        '已在暂存、ZIP 搬迁和 EXE 安装后的三个目录验证 Debug 导入目标、运行时配置、模块 DLL 的 DWARF/源代码行信息，以及 GDB 对 OpenCV 函数的源代码行解析。源代码不随包复制，精确提交见 lock 文件。'
    } else { '已验证 CMake Release 导入目标、图像转换、PNG 往返、FFmpeg 视频往返、OpenMP，以及三个 SDK 位置和独立 wheel 虚拟环境中的 cv2。' }
}
$tag = "$($result.package_name)-r$env:GITHUB_RUN_ID-a$env:GITHUB_RUN_ATTEMPT"
$notes = @"
## Windows x64 — $Variant

$description

$pythonNote

### 验证范围

$specific

SDK 暂存目录、含空格 ZIP 解压目录和 EXE 静默安装目录分别编译并运行消费者；安装与卸载检查通过。Python 版另在全新虚拟环境安装 wheel，核对实际加载来源、NumPy、图像转换和 PNG 读写。完整结果见 ``verification.json`` 和 ``python-wheel-verification.json``（适用时）。这些检查不等于完整 OpenCV 回归或性能测试。

### 下载

- ``*-setup.exe``：当前用户安装程序，独立安装目录与卸载入口。
- ``*.zip``：同内容便携 SDK。
- ``*.whl``：适配标题所列 CPython 的 cv2 包（Python 版）。
- ``build-info.json`` / ``build-lock.json``：模块、ABI、源码提交和精确依赖。
- ``SHA256SUMS``：所有公开附件的 SHA-256。

安装程序未配置代码签名。支持 Windows 10/11 x64；不要混用 MinGW 与 MSVC C++ 库，也不要在同一 Python 环境中安装多个提供 cv2 的发行包。

### 来源

- OpenCV: $($lock.opencv_commit)
- contrib: $($lock.contrib_commit)
- 原构建提交: $SourceCommit
- 原构建运行: https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$($origin.source_run_id) (attempt $($origin.source_run_attempt))
- 本次验证提交: $env:GITHUB_SHA
- 本次验证运行: https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID (attempt $env:GITHUB_RUN_ATTEMPT)
"@
$notesPath = Join-Path $output 'release-notes.md'
$notes | Set-Content -LiteralPath $notesPath -Encoding utf8NoBOM
if ($PrepareOnly) { Write-Host 'Validated publication gates and updated public SHA256SUMS.'; return }
$arguments = @('release','create',$tag) + $files + @('--repo',$env:GITHUB_REPOSITORY,'--target',$SourceCommit,'--title',$title,'--notes-file',$notesPath)
if ($isCuda -and -not $gpuVerified) { $arguments += @('--prerelease','--latest=false') }
elseif ($isDebug -or $isCuda) { $arguments += '--latest=false' }
else { $arguments += '--latest=true' }
& gh @arguments
if ($LASTEXITCODE -ne 0) { throw "GitHub release creation failed: $LASTEXITCODE" }
$url = "https://github.com/$env:GITHUB_REPOSITORY/releases/tag/$tag"
if ($env:GITHUB_OUTPUT) { "release_url=$url" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
if ($env:GITHUB_STEP_SUMMARY) { "`n[$Variant downloads]($url)" | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
Write-Host $url
