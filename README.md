# OpenCV + MinGW-w64 Windows 安装包

[![Windows build](https://github.com/liyiliuxingyu/opencv_mingw/actions/workflows/build-windows.yml/badge.svg)](https://github.com/liyiliuxingyu/opencv_mingw/actions/workflows/build-windows.yml)

使用 GitHub Actions，从 **OpenCV 最新稳定版及同版本 contrib 源码**构建 Windows x64 C++ SDK，搭配 **WinLibs 最新稳定版的 GCC / MinGW-w64 工具链**，生成便携 ZIP 和 EXE 安装程序。

- [下载安装包（Releases）](https://github.com/liyiliuxingyu/opencv_mingw/releases)
- [查看构建或手动运行（Actions）](https://github.com/liyiliuxingyu/opencv_mingw/actions/workflows/build-windows.yml)

首次构建只有在 Windows 编译、运行、ZIP 搬迁、安装和卸载检查全部通过后才会发布。具体版本和检查结果以 Release 附件 `build-lock.json`、`build-info.json`、`verification.json` 为准。

## 安装包包含什么

| 内容 | 说明 |
| --- | --- |
| OpenCV C++ SDK | Release 动态库、头文件、DLL 导入库、CMake 配置与可构建的 contrib 模块 |
| 完整 MinGW-w64 工具链 | x86-64、POSIX 线程、SEH、UCRT；包括匹配的 GCC、CMake、Ninja 及上游随附工具 |
| 运行时依赖 | 扫描 OpenCV DLL/EXE 的依赖，并从同一工具链补齐非系统运行库 |
| 图像与视频功能 | 发布检查要求 PNG 读写、FFmpeg 视频读写和 OpenMP 并行后端通过 |
| 可编辑示例 | C++ 源码、CMake 工程和一键编译命令 |
| 构建记录 | 完整源码提交、下载地址、工具链 SHA-256、构建参数、第三方下载校验清单 |

目标系统为 **Windows 10/11 x64**。这是 MinGW C++ SDK；Python `cv2`、CUDA、独立 Debug 库不在本次打包范围。OpenCV 的实际可用模块与第三方功能记录在构建摘要中。

针对部分 WinLibs GCC 版本在含空格安装目录下拆分 `default-manifest.o` 路径的上游问题，构建会对已知的 GCC specs 表达式应用精确兼容补丁，保留默认 manifest 及原有条件。未受影响的版本保持原样；原始配置、补丁说明和前后 SHA-256 会随构建记录保留。工具链会先在含空格路径下编译并运行小型程序，再开始 OpenCV 构建。也可独立运行 **Verify latest MinGW in paths with spaces** 工作流快速检查最新工具链。

仓库根目录已有的 `include/`、`x64/`、`OpenCVConfig.cmake` 等是历史 **4.5.1-dev** 分发文件。新构建使用独立源码和安装目录，新版下载请使用 Releases；不要把新旧两套头文件、导入库和 DLL 混放。

## 通过 GitHub Actions 创建安装文件

1. 打开 **Actions → Build latest OpenCV and MinGW installers**。
2. 选择 **Run workflow**，分支选 `master`。
3. 保持 `opencv_version=latest`、`winlibs_version=latest`，即可在运行开始时解析上游最新稳定发行版。也可以指定确切的稳定 release tag。
4. 默认使用 4 个编译任务；如遇内存不足，可将 `parallel_jobs` 改为 2。
5. 保持 `publish=true`，所有验证通过后会自动创建 Release。关闭该项则只上传 Actions Artifacts。

修改构建脚本、安装模板或示例并推送到 `master` 也会触发构建。没有设置定时任务。手动运行其他分支会构建并上传 Artifacts，但只允许默认分支发布 Release。

`latest` 指运行时从 `opencv/opencv` 和 `brechtsanders/winlibs_mingw` 的 GitHub `releases/latest` 解析出的正式发布，不跟随开发分支，也不选择预发布版本。contrib 必须有对应 OpenCV tag；工具链必须提供 x64/POSIX/SEH/UCRT 的 GCC-only 资产和可信的 SHA-256，缺失时构建会明确失败。

### 发布文件

| 文件 | 用途 |
| --- | --- |
| `opencv-…-x64-setup.exe` | 当前用户的图形安装程序；含完整编译器 |
| `opencv-…-x64.zip` | 与安装版内容相同的便携包 |
| `…-build-lock.json` | 本次解析后的确切版本、源码提交与工具链 SHA-256 |
| `…-build-info.json` | 构建能力、相对目录与补齐的运行库清单 |
| `verification.json` | 本次 Windows 编译、运行、安装及卸载检查结果 |
| `candidate-origin.json` | 原始构建的运行编号、提交与候选产物来源 |
| `SHA256SUMS` | 以上下载文件的 SHA-256 校验值 |

每次发布使用全局唯一的运行 ID 与重试编号，不覆盖历史发布。Actions 的临时 Artifacts 保留 14 天；正式下载使用 Releases。安装包创建后会先保存 `opencv-candidate-运行ID-重试编号`，这是尚未完成分发验证的候选产物；只有后续所有检查通过，才会上传已验证产物并发布 Release。

### 复用已完成的候选安装包

如果耗时的编译和打包已成功，但后续验证失败，可先修复验证脚本，再运行 **Verify an existing OpenCV installer candidate**。填写原构建页面 URL 中的 `source_run_id`，`source_run_attempt` 默认为 `1`。它会校验候选产物来源和全部校验值，从原 ZIP 恢复暂存 SDK，重新检查 ZIP、EXE 安装、消费者运行和卸载，无需重新编译 OpenCV。

恢复工作流的 `publish` 默认关闭；需要发布时启用，且原构建与恢复工作流都必须来自默认分支。发布记录分别列出原构建与本次验证的提交。此工作流不修改候选 ZIP/EXE；如果需要修复包内文件或重新编译，请运行完整构建。

## 安装和使用

### EXE 安装版

运行 `*-setup.exe`，默认安装到当前用户的 LocalAppData 目录，无需管理员权限。安装后从开始菜单打开 **Developer Command Prompt**。

安装程序创建开始菜单入口和卸载项。开发终端为当前进程设置编译器、OpenCV 和 CMake 的环境。可从系统的应用列表或安装包的卸载入口卸载。

### ZIP 便携版

解压整个顶层目录，在命令提示符中执行：

```bat
call "C:\your path\opencv-package\activate.cmd"
```

然后执行：

```bat
build-example.cmd
```

示例构建输出放在 `%LOCALAPPDATA%\OpenCV-MinGW\examples\`。它会创建图像、核对颜色转换结果、执行 PNG 无损读写，并检查可用的 FFmpeg 视频读写。切换其他工具链时请打开新的终端。

### 自己的 CMake 项目

```cmake
cmake_minimum_required(VERSION 3.20)
project(MyOpenCVApp LANGUAGES CXX)

find_package(OpenCV CONFIG REQUIRED COMPONENTS core imgproc imgcodecs)
add_executable(my_app main.cpp)
target_compile_features(my_app PRIVATE cxx_std_17)
target_include_directories(my_app PRIVATE ${OpenCV_INCLUDE_DIRS})
target_link_libraries(my_app PRIVATE ${OpenCV_LIBS})
```

在开发终端中使用随包的 Ninja/GCC 配置：

```bat
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 2
```

`activate.cmd` 已设置 `OpenCV_DIR`。使用这套工具链编译消费者，以保持 C++ ABI、CRT 与运行库匹配。`.dll.a` 是导入库，运行应用时仍需要相应 DLL；部署到另一台电脑时，把所需 OpenCV 和匹配运行库放在应用 EXE 旁，并保留相应许可证。

## 发布前实际验证

工作流分别对暂存 SDK、ZIP 解压后的含空格目录、EXE 静默安装后的含空格目录进行原生 Windows 消费者编译和运行。每次运行检查：

- 编译器版本、目标架构以及 OpenCV 头文件/运行库版本一致。
- 已知像素的灰度转换结果正确。
- PNG 文件和内存编码/解码无损。
- `parallel_for_` 结果正确，构建信息报告 OpenMP。
- FFmpeg 后端可用，MJPEG AVI 的八帧写入、读取与尺寸检查通过。
- 运行时 PATH 仅保留 SDK 的 DLL 目录与 Windows 系统目录，避免编译机已有 MinGW 掩盖缺失依赖。
- 静默卸载成功，并移除检查的已安装文件。

这不是完整 OpenCV 回归测试，也不是性能基准。摄像头、GPU/驱动、所有 contrib 模块和其他 Windows 版本仍需要按用途验证。

## 本地重建

需要 Windows x64、PowerShell 7.2+、Git、7-Zip 和 Inno Setup 6.3+。CMake、Ninja 和 GCC 将从经过 SHA-256 校验的 WinLibs 工具链取得。

```powershell
./scripts/resolve-versions.ps1 -OutputPath ./work/versions.lock.json
./scripts/build-opencv.ps1 -LockFile ./work/versions.lock.json `
    -WorkRoot ./work -InstallRoot ./packages/current/opencv -ParallelJobs 4
./scripts/package-opencv.ps1 -StateFile ./work/build-state.json `
    -PackageRoot ./packages/current -OutputDir ./dist
./scripts/verify-distribution.ps1 -ResultFile ./dist/package-result.json `
    -WorkRoot ./verification
```

每次从新的工作和安装目录开始，避免混入旧产物。保留发布附带的 lock 文件可以重新使用同一组源码提交和工具链；构建记录用于追溯，不承诺不同日期的工具和系统环境会产生逐字节相同的文件。

## 许可证与签名

OpenCV、contrib 和工具链中的各组件分别遵循原有许可证。打包过程保留 OpenCV 安装目录和完整 WinLibs 包中的许可证、通知及文档，包内 `LICENSES.txt` 提供来源索引。

当前工作流未配置代码签名证书，因此生成的 EXE 为未签名安装程序。下载时可用 `Get-FileHash -Algorithm SHA256` 与同一 Release 的 `SHA256SUMS` 核对。
