# Windows 安装包下载

本页只列出本仓库已发布、文件摘要一致并完成分发验证的构建。EXE、ZIP 和 wheel 的大文件未在更新索引时重新下载或执行；其 SHA-256 与 GitHub 资产摘要、原始 SHA256SUMS 及 wheel 验证记录交叉核对。

| 版本 | OpenCV / 工具链 | 状态 | EXE | ZIP | wheel | SHA-256 | Release |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MinGW Release + Python | 5.1.0 / GCC 16.2.0 / MinGW 14.0.0 | 已验证发布 | [EXE](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-setup.exe) | [ZIP](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313.zip) | [CPython 3.13](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/opencv_mingw-5.1.0-cp313-cp313-win_amd64.whl) | [SHA256SUMS](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/SHA256SUMS) | [详情](https://github.com/liyiliuxingyu/opencv_mingw/releases/tag/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1) |
| MinGW Debug C++ | 5.1.0 / GCC 16.2.0 / MinGW 14.0.0 | 已验证发布 | [EXE](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-setup.exe) | [ZIP](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug.zip) | — | [SHA256SUMS](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/SHA256SUMS) | [详情](https://github.com/liyiliuxingyu/opencv_mingw/releases/tag/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1) |
| MSVC CUDA + Python | — | 暂无已验证发布 | — | — | — | — | — |

[机器可读索引](latest-windows.json) · [所有历史 Releases](https://github.com/liyiliuxingyu/opencv_mingw/releases)

## MinGW Release + Python

- 包名：`opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313`
- 发布时间：2026-11-24T04:33:16Z
- 维护配置：匹配当前自动维护配置。
- 原始构建：[45320873434 / attempt 1](https://github.com/liyiliuxingyu/opencv_mingw/actions/runs/45320873434)；提交：[`61e9cc3806bda8841d64c984d1429657c984ad87`](https://github.com/liyiliuxingyu/opencv_mingw/commit/61e9cc3806bda8841d64c984d1429657c984ad87)
- 分发验证：[45320873434 / attempt 1](https://github.com/liyiliuxingyu/opencv_mingw/actions/runs/45320873434)，结果 `passed`。
- OpenCV 源码：`e4f78fbcf1a773fbed69e14500e8b734963eb585`；contrib：`b67a855188a3d683813731010f6d39ac614733a4`。
- WinLibs：`16.2.0posix-23.1.3-14.0.0-ucrt-r3`；下载归档 SHA-256：`db014a73b71907c6c778fd1c938056cddcae9023f89f8dfff7783d9e45baf975`。
- CPython 3.13.17 / ABI `cp313` / NumPy 2.5.5。CPU 与 CUDA wheel 均提供 `cv2`，请分别安装到独立环境。

| 文件 | 大小（字节） | SHA-256 |
| --- | ---: | --- |
| [opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-setup.exe](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-setup.exe) | 293726204 | `fbc8889714579039c5cedbd8edbcd5b84316cd282d02dab8d447750ddcce910d` |
| [opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313.zip](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313.zip) | 419030499 | `b242ad72d382698de79788e5e9fbf706e54321b4b79613e30285ded9c144f61c` |
| [SHA256SUMS](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/SHA256SUMS) | 978 | `6e3ec001380c44b293e735800693e70cd1383caff6297378034f931b6686b7f5` |
| [opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-build-info.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-build-info.json) | 2248 | `a6a0d69bb1df984875d30d5e9c64fcacb0294cae2c71125718a1c58b26c3920c` |
| [opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-build-lock.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-build-lock.json) | 1346 | `b4bd1694a9ad82237fcdc88e8f07f735d91e22c534f856df8dff64c3a7f8b624` |
| [verification.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/verification.json) | 7000 | `2926d4b8c9a4bceae8c25ea0813bf20a78fc5285a59279ef8e63090463a0a0a3` |
| [candidate-origin.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/candidate-origin.json) | 1113 | `3fe8fa452baec046651f50f29745416906f9799d4b21356d8cf57980e2099c8a` |
| [opencv_mingw-5.1.0-cp313-cp313-win_amd64.whl](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/opencv_mingw-5.1.0-cp313-cp313-win_amd64.whl) | 58258651 | `eb09b5b9d3853bf531c67e4330eedbf9c2ea604672c5bde845eec639d1d3424c` |
| [python-wheel-result.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/python-wheel-result.json) | 2070 | `ab9b692a5606710679075663e0478f259168a1559e01e793aead403c5af75f58` |
| [python-wheel-verification.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-py313-r45320873434-a1/python-wheel-verification.json) | 1911 | `9ce4ac03f5ab1b190ec05c60cb7345d38145ab4fbfbefaf21b600b1dd69be501` |

## MinGW Debug C++

- 包名：`opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug`
- 发布时间：2026-11-24T04:38:59Z
- 维护配置：匹配当前自动维护配置。
- 原始构建：[45324144625 / attempt 1](https://github.com/liyiliuxingyu/opencv_mingw/actions/runs/45324144625)；提交：[`f92896e3c1ae31d99ccff796b431fc058cc13de7`](https://github.com/liyiliuxingyu/opencv_mingw/commit/f92896e3c1ae31d99ccff796b431fc058cc13de7)
- 分发验证：[45324144625 / attempt 1](https://github.com/liyiliuxingyu/opencv_mingw/actions/runs/45324144625)，结果 `passed`。
- OpenCV 源码：`e4f78fbcf1a773fbed69e14500e8b734963eb585`；contrib：`b67a855188a3d683813731010f6d39ac614733a4`。
- WinLibs：`16.2.0posix-23.1.3-14.0.0-ucrt-r3`；下载归档 SHA-256：`db014a73b71907c6c778fd1c938056cddcae9023f89f8dfff7783d9e45baf975`。
- 独立 C++ Debug 模块库，包含 DWARF 调试信息；不包含 Debug Python。

| 文件 | 大小（字节） | SHA-256 |
| --- | ---: | --- |
| [opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-setup.exe](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-setup.exe) | 396939887 | `601b966fe7655cf3b85f2fdc0bdd99bff73b660890b1df26e4d48598e4a1eb63` |
| [opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug.zip](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug.zip) | 619884285 | `074e8a33841119c6ae749faffc0db465720d06d65769fc3826dfb2a41ccd16ae` |
| [SHA256SUMS](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/SHA256SUMS) | 676 | `4f8fe846b92e08a66e47db998a042ff53c5f36547755c18fd254fa67bf5e3bd0` |
| [opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-build-info.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-build-info.json) | 3999 | `cce41e30d115fdf744a1e12f9cb63727370e1bf2900d8ab139456fedeb1e7abf` |
| [opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-build-lock.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-build-lock.json) | 1341 | `3dca56990925da33930a096b09824a50c6a4862293a9ce22c65f44817c849150` |
| [verification.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/verification.json) | 1264 | `9fd31b54b6f6c1cfff4ccded21bc8adcb1396ee9bcb811ca687e04fde21062b6` |
| [candidate-origin.json](https://github.com/liyiliuxingyu/opencv_mingw/releases/download/opencv-5.1.0-mingw-14.0.0-gcc-16.2.0-x64-debug-r45324144625-a1/candidate-origin.json) | 991 | `91d99ec80d3f39e0996f20e55fe18072f0248d780dc646f5ed16bb82a1a3bd95` |

索引只在内容变化时更新。旧构建后完成、恢复发布或重新验证不会仅凭发布时间替换更高版本及更新原始构建的入口。
