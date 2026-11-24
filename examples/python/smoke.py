"""Validate the cv2 binary shipped by this build, with an isolated interpreter."""

from __future__ import annotations

import argparse
import ctypes
import gc
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import struct
import sys
import traceback


def inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def nvidia_binary_dirs() -> list[Path]:
    roots = []
    spec = importlib.util.find_spec("nvidia")
    if spec is not None:
        roots.extend(Path(p) for p in (spec.submodule_search_locations or []))
    roots.extend(Path(p) / "nvidia" for p in sys.path if p and Path(p).is_dir())
    found = set()
    for root in roots:
        if root.is_dir():
            found.update(p.parent.resolve() for p in root.rglob("*.dll") if p.is_file())
    return sorted(found)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--origin-root", required=True)
    parser.add_argument("--module-root")
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-python", required=True)
    parser.add_argument("--expected-numpy", required=True)
    parser.add_argument("--result-path", required=True)
    parser.add_argument("--dll-dir", action="append", default=[])
    parser.add_argument("--require-cuda", action="store_true")
    parser.add_argument("--require-gpu", action="store_true")
    args = parser.parse_args()
    result_path = Path(args.result_path).resolve()
    result_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"schema_version": 1, "result": "failed", "tests": {}, "gpu_execution": "not-tested"}
    dll_handles = []
    try:
        if sys.platform != "win32" or struct.calcsize("P") != 8:
            raise RuntimeError("The package requires a native Windows x64 Python interpreter.")
        if platform.python_implementation() != "CPython":
            raise RuntimeError("The package requires CPython.")
        actual_python = f"{sys.version_info.major}.{sys.version_info.minor}"
        if actual_python != args.expected_python:
            raise RuntimeError(f"Python ABI mismatch: expected {args.expected_python}, found {actual_python}.")
        origin = Path(args.origin_root).resolve()
        if args.module_root:
            module_root = Path(args.module_root).resolve()
            if not inside(module_root, origin):
                raise RuntimeError("The loader directory must belong to the tested package.")
            sys.path.insert(0, str(module_root))
        directories = [Path(p).resolve() for p in args.dll_dir] + nvidia_binary_dirs()
        for directory in directories:
            if directory.is_dir():
                dll_handles.append(os.add_dll_directory(str(directory)))

        import numpy as np
        import cv2

        native = getattr(cv2, "_native", cv2)
        loader_path = Path(cv2.__file__).resolve()
        native_path = Path(native.__file__).resolve()
        if not inside(loader_path, origin) or not inside(native_path, origin):
            raise RuntimeError(f"Imported another cv2 installation: {loader_path}; {native_path}")
        if native_path.suffix.lower() != ".pyd":
            raise RuntimeError(f"The native OpenCV extension was not loaded: {native_path}")
        if cv2.__version__ != args.expected_version or np.__version__ != args.expected_numpy:
            raise RuntimeError(f"Unexpected versions: cv2={cv2.__version__}, numpy={np.__version__}")
        report.update(python_version=platform.python_version(), python_abi=f"cp{sys.version_info.major}{sys.version_info.minor}",
                      numpy_version=np.__version__, opencv_version=cv2.__version__,
                      cv2_loader_path=str(loader_path), cv2_native_path=str(native_path))
        report["tests"]["package_origin_and_versions"] = True

        colors = np.array([[[0, 0, 255], [255, 0, 0], [0, 255, 0]]], dtype=np.uint8)
        gray = cv2.cvtColor(colors, cv2.COLOR_BGR2GRAY)
        np.testing.assert_array_equal(gray, np.array([[76, 29, 150]], dtype=np.uint8))
        report["tests"]["known_pixel_conversion"] = True
        image = (np.arange(18 * 24 * 3, dtype=np.uint16).reshape(18, 24, 3) % 256).astype(np.uint8)
        ok, encoded = cv2.imencode(".png", image)
        if not ok:
            raise RuntimeError("PNG encoding failed.")
        np.testing.assert_array_equal(cv2.imdecode(encoded, cv2.IMREAD_UNCHANGED), image)
        png_path = result_path.parent / "python-roundtrip.png"
        if not cv2.imwrite(str(png_path), image):
            raise RuntimeError("PNG file writing failed.")
        np.testing.assert_array_equal(cv2.imread(str(png_path), cv2.IMREAD_UNCHANGED), image)
        report["tests"]["png_memory_and_file_roundtrip"] = True

        view = image[::2, ::-2, :]
        if view.flags.c_contiguous:
            raise RuntimeError("The array-stride test did not create a non-contiguous view.")
        np.testing.assert_array_equal(cv2.cvtColor(view, cv2.COLOR_BGR2GRAY),
                                      cv2.cvtColor(np.ascontiguousarray(view), cv2.COLOR_BGR2GRAY))
        for _ in range(32):
            mapped = cv2.UMat(view)
            np.testing.assert_array_equal(mapped.get(), view)
            del mapped
        gc.collect()
        report["tests"]["non_contiguous_arrays_and_lifetimes"] = True

        build_info = cv2.getBuildInformation()
        (result_path.parent / "python-opencv-build-info.txt").write_text(build_info, encoding="utf-8")
        cuda_compiled = re.search(r"NVIDIA CUDA:\s+YES\b", build_info) is not None
        report["cuda_compiled"] = cuda_compiled
        if args.require_cuda and not cuda_compiled:
            raise RuntimeError("The requested CUDA-enabled OpenCV binary was not built with CUDA.")
        if cuda_compiled:
            try:
                devices = cv2.cuda.getCudaEnabledDeviceCount()
                report["cuda_device_count"] = devices
            except cv2.error as error:
                devices = 0
                report["gpu_not_tested_reason"] = str(error)
            if devices > 0:
                gpu = cv2.cuda_GpuMat()
                gpu.upload(image)
                np.testing.assert_array_equal(gpu.download(), image)
                gpu_gray = cv2.cuda.cvtColor(gpu, cv2.COLOR_BGR2GRAY)
                np.testing.assert_array_equal(gpu_gray.download(), cv2.cvtColor(image, cv2.COLOR_BGR2GRAY))
                report["gpu_execution"] = "passed"
            else:
                report.setdefault("gpu_not_tested_reason", "No usable NVIDIA GPU/driver is exposed to this runner.")
                if args.require_gpu:
                    raise RuntimeError("GPU execution was required but no usable GPU is available.")
        else:
            report["gpu_not_tested_reason"] = "This package is the CPU build."
        report["tests"]["cuda_build_flag"] = not args.require_cuda or cuda_compiled

        # Cover both world builds and the separate module DLLs used by CUDA.
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.GetModuleHandleW.argtypes = [ctypes.c_wchar_p]
        kernel32.GetModuleHandleW.restype = ctypes.c_void_p
        kernel32.GetModuleFileNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint32]
        kernel32.GetModuleFileNameW.restype = ctypes.c_uint32
        opencv_candidates = list(origin.rglob("*opencv*.dll"))
        primary_candidates = [p for p in opencv_candidates if re.match(r"(?:lib)?opencv_(?:world|core)\d", p.name, re.I)]
        loaded_opencv = []
        loaded_primary = []
        for candidate in opencv_candidates:
            module = kernel32.GetModuleHandleW(candidate.name)
            if module:
                buffer = ctypes.create_unicode_buffer(32768)
                if not kernel32.GetModuleFileNameW(module, buffer, len(buffer)):
                    raise ctypes.WinError(ctypes.get_last_error())
                loaded_path = Path(buffer.value).resolve()
                if not inside(loaded_path, origin):
                    raise RuntimeError(f"Loaded another OpenCV DLL: {loaded_path}")
                loaded_opencv.append(str(loaded_path))
                if candidate in primary_candidates:
                    loaded_primary.append(str(loaded_path))
        if primary_candidates and not loaded_primary:
            raise RuntimeError("No expected OpenCV core/world DLL was loaded by cv2.")
        report["loaded_opencv_dlls"] = sorted(set(loaded_opencv))
        report["loaded_opencv_world_dlls"] = sorted({p for p in loaded_opencv if "opencv_world" in Path(p).name.lower()})
        report["tests"]["opencv_dll_origin"] = True
        report["result"] = "passed"
    except Exception as error:
        report["error"] = str(error)
        report["traceback"] = traceback.format_exc()
        traceback.print_exc()
    finally:
        result_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["result"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
