#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PythonExecutable,
    [Parameter(Mandatory)][string] $InstallRoot,
    [Parameter(Mandatory)][string] $WorkRoot,
    [string] $CxxCompiler,
    [string] $NumPyVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'Python extension configuration requires native Windows.' }
$PythonExecutable = (Resolve-Path -LiteralPath $PythonExecutable).Path
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

function Invoke-PythonBuildChecked {
    param([string] $File, [string[]] $Arguments)
    & $File @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $File" }
}

$interpreterProbe = @'
import json, platform, struct, sys, sysconfig
if sys.platform != 'win32' or platform.python_implementation() != 'CPython':
    raise RuntimeError('An official Windows CPython interpreter is required.')
if struct.calcsize('P') != 8 or sysconfig.get_platform() != 'win-amd64':
    raise RuntimeError('Only Windows x64 CPython is supported.')
if sys.version_info[:2] not in ((3, 12), (3, 13), (3, 14)):
    raise RuntimeError('Choose regular CPython 3.12, 3.13 or 3.14.')
if sysconfig.get_config_var('Py_GIL_DISABLED') or hasattr(sys, 'gettotalrefcount'):
    raise RuntimeError('Free-threaded and debug CPython interpreters are not supported by these wheels.')
print(json.dumps({'version':platform.python_version()}))
'@
$probe = & $PythonExecutable -I -c $interpreterProbe
if ($LASTEXITCODE -ne 0) { throw 'The selected Python interpreter is incompatible.' }
Write-Host "Preparing Python $((($probe | Out-String) | ConvertFrom-Json).version) build headers."

$numpyRequirement = if ($NumPyVersion) {
    if ($NumPyVersion -notmatch '^\d+\.\d+\.\d+([A-Za-z0-9.+-]*)$') { throw 'Invalid NumPy version.' }
    "numpy==$NumPyVersion"
} else { 'numpy>=2.0,<3' }
$pipReport = Join-Path $WorkRoot 'python-build-pip-report.json'
Invoke-PythonBuildChecked $PythonExecutable @('-I', '-m', 'pip', 'install', '--upgrade', '--only-binary=:all:',
    '--disable-pip-version-check', '--report', $pipReport, $numpyRequirement)

$metadataProbe = @'
import json, pathlib, platform, sys, sysconfig, numpy
base = pathlib.Path(sys.base_prefix)
name = 'python%d%d' % sys.version_info[:2]
library = base / 'libs' / (name + '.lib')
dll = base / (name + '.dll')
include = pathlib.Path(sysconfig.get_path('include'))
for item in (library, dll, include / 'Python.h'):
    if not item.is_file():
        raise RuntimeError('Missing CPython development file: ' + str(item))
print(json.dumps({
    'version': platform.python_version(),
    'major_minor': '%d.%d' % sys.version_info[:2],
    'abi': 'cp%d%d' % sys.version_info[:2],
    'extension_suffix': sysconfig.get_config_var('EXT_SUFFIX'),
    'executable': sys.executable,
    'include_dir': str(include), 'library': str(library), 'dll': str(dll),
    'numpy_version': numpy.__version__, 'numpy_include_dir': numpy.get_include(),
    'runtime_packages': {}, 'compiler_abi_probe': 'not-run'
}))
'@
$metadataJson = & $PythonExecutable -I -c $metadataProbe
if ($LASTEXITCODE -ne 0) { throw 'Could not obtain matching Python/NumPy development paths.' }
$python = ($metadataJson | Out-String) | ConvertFrom-Json -AsHashtable
$python['pip_report'] = $pipReport

if ($CxxCompiler) {
    $CxxCompiler = (Resolve-Path -LiteralPath $CxxCompiler).Path
    $probeRoot = Join-Path $WorkRoot 'python ABI probe'
    New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
    $probeSource = Join-Path $probeRoot 'opencv_python_abi_probe.cpp'
    @'
#include <Python.h>
static PyObject* answer(PyObject*, PyObject*) { return PyLong_FromLong(42); }
static PyMethodDef methods[] = {{"answer", answer, METH_NOARGS, "ABI probe"}, {nullptr, nullptr, 0, nullptr}};
static PyModuleDef module = {PyModuleDef_HEAD_INIT, "opencv_python_abi_probe", nullptr, -1, methods};
PyMODINIT_FUNC PyInit_opencv_python_abi_probe() { return PyModule_Create(&module); }
'@ | Set-Content -LiteralPath $probeSource -Encoding utf8NoBOM
    $probeBinary = Join-Path $probeRoot ("opencv_python_abi_probe" + $python.extension_suffix)
    Invoke-PythonBuildChecked $CxxCompiler @('-std=c++17', '-shared', '-O2', ('-I' + $python.include_dir),
        $probeSource, $python.library, '-o', $probeBinary)
    $probeImport = @'
import os, sys
handle = os.add_dll_directory(sys.argv[2])
sys.path.insert(0, sys.argv[1])
import opencv_python_abi_probe
assert opencv_python_abi_probe.answer() == 42
print('MinGW / CPython C API compile, link and import probe passed.')
'@
    Invoke-PythonBuildChecked $PythonExecutable @('-I', '-c', $probeImport, $probeRoot, (Split-Path -Parent $CxxCompiler))
    $python.compiler_abi_probe = 'passed'
}

$cmakeOptions = @(
    '-DBUILD_opencv_python3=ON', '-DPYTHON3_LIMITED_API=OFF',
    # OpenCV forwards these through CMake macros that reparse arguments. Native
    # Windows backslashes (for example \h in hostedtoolcache) become escapes.
    "-DPYTHON3_EXECUTABLE=$($PythonExecutable.Replace('\', '/'))",
    "-DPYTHON_DEFAULT_EXECUTABLE=$($PythonExecutable.Replace('\', '/'))",
    "-DPYTHON3_INCLUDE_DIR=$($python.include_dir.Replace('\', '/'))",
    "-DPYTHON3_LIBRARY=$($python.library.Replace('\', '/'))",
    "-DPYTHON3_NUMPY_INCLUDE_DIRS=$($python.numpy_include_dir.Replace('\', '/'))",
    '-DOPENCV_PYTHON3_INSTALL_PATH=python', '-DPYTHON3_PACKAGES_PATH=python',
    '-DOPENCV_SKIP_PYTHON_LOADER=OFF'
)
$configPath = Join-Path $WorkRoot 'python-build-config.json'
$result = [ordered]@{schema_version = 1; python = $python; cmake_options = $cmakeOptions; install_root = $InstallRoot; config_path = $configPath}
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
return [pscustomobject]$result
