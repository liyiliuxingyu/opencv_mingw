#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StateFile,
    [Parameter(Mandatory)][string] $PythonExecutable,
    [Parameter(Mandatory)][string] $OutputDir,
    [ValidateSet('opencv_mingw', 'opencv_cuda')][string] $DistributionName = 'opencv_mingw',
    [string[]] $RuntimeDirectories = @(),
    [hashtable] $ExternalRuntimePackages = @{},
    [string[]] $LicenseFiles = @(),
    [switch] $RequireCuda
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'Build Windows cv2 wheels on Windows.' }
$StateFile = (Resolve-Path -LiteralPath $StateFile).Path
$PythonExecutable = (Resolve-Path -LiteralPath $PythonExecutable).Path
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json -AsHashtable
foreach ($key in @('install_root', 'opencv_bin_dir', 'opencv_version')) {
    if (-not $state.ContainsKey($key) -or -not $state[$key]) { throw "Missing build-state field: $key" }
}
if ($state.ContainsKey('configuration') -and $state.configuration -ne 'Release') {
    throw 'Python wheels are built only from the Release SDK; Debug is a separate C++ SDK.'
}
if ($DistributionName -eq 'opencv_cuda') { $RequireCuda = $true }
if ($ExternalRuntimePackages.Count -eq 0) {
    foreach ($key in @('cuda_python_runtime_packages', 'external_runtime_packages')) {
        if ($state.ContainsKey($key) -and $state[$key]) { $ExternalRuntimePackages = $state[$key]; break }
    }
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$work = Join-Path $OutputDir ('.python-wheel-work-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$contextPath = Join-Path $work 'context.json'
$resultPath = Join-Path $OutputDir ($DistributionName + '-python-wheel-result.json')
@{
    state = $state; output_dir = $OutputDir; distribution = $DistributionName
    runtime_directories = @($RuntimeDirectories); external_runtime_packages = $ExternalRuntimePackages
    license_files = @($LicenseFiles); require_cuda = [bool]$RequireCuda; result_path = $resultPath
} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $contextPath -Encoding utf8NoBOM

$builder = @'
from __future__ import annotations
import base64, csv, hashlib, io, json, os, pathlib, platform, re, shutil, struct, sys, sysconfig, tempfile, zipfile
from email.message import EmailMessage
import numpy

context = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
state = context['state']
install = pathlib.Path(state['install_root']).resolve()
source = install / 'python' / 'cv2'
binary_dir = pathlib.Path(state['opencv_bin_dir']).resolve()
output = pathlib.Path(context['output_dir']).resolve()
distribution = context['distribution']
version = str(state['opencv_version'])
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise RuntimeError('The OpenCV wheel version must be a stable numeric release.')
if sys.platform != 'win32' or struct.calcsize('P') != 8 or sysconfig.get_platform() != 'win-amd64':
    raise RuntimeError('A native Windows x64 CPython interpreter is required.')
if platform.python_implementation() != 'CPython' or sysconfig.get_config_var('Py_GIL_DISABLED') or hasattr(sys, 'gettotalrefcount'):
    raise RuntimeError('Use regular release CPython, not free-threaded or debug Python.')
major, minor = sys.version_info[:2]
if (major, minor) not in ((3, 12), (3, 13), (3, 14)):
    raise RuntimeError('Only CPython 3.12, 3.13 and 3.14 are supported.')
abi = f'cp{major}{minor}'
suffix = sysconfig.get_config_var('EXT_SUFFIX')
expected_binary = 'cv2' + suffix
natives = list(source.rglob('*.pyd')) if source.is_dir() else []
if len(natives) != 1 or natives[0].name.lower() != expected_binary.lower():
    raise RuntimeError(f'Expected exactly one {expected_binary} in {source}, found {[p.name for p in natives]}.')
for required in ('__init__.py', 'load_config_py3.py', 'config.py', f'config-{major}.{minor}.py'):
    if not (source / required).is_file():
        raise RuntimeError('The installed OpenCV Python loader is incomplete: ' + required)
recorded_python = state.get('python') or {}
if recorded_python.get('major_minor') and recorded_python['major_minor'] != f'{major}.{minor}':
    raise RuntimeError('The requested Python differs from the OpenCV build interpreter.')
if recorded_python.get('numpy_version') and recorded_python['numpy_version'] != numpy.__version__:
    raise RuntimeError('The current NumPy differs from the OpenCV build headers.')

packages = context.get('external_runtime_packages') or {}
for name, pin in packages.items():
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name) or not re.fullmatch(r'[0-9][A-Za-z0-9.+_-]*', str(pin)):
        raise RuntimeError('External runtime dependencies must be package names with exact versions.')
external_names = {str(x).lower() for x in state.get('external_runtime_dlls', [])}
external_prefixes = tuple(str(x).lower() for x in state.get('external_runtime_prefixes', []))
if context['require_cuda'] and not packages:
    raise RuntimeError('The CUDA wheel requires exact NVIDIA runtime package/version metadata.')
system_names = set('''advapi32 avicap32 avifil32 bcrypt bcryptprimitives cabinet cfgmgr32 combase comctl32 comdlg32
crypt32 cryptbase cryptsp d2d1 d3d9 d3d11 d3d12 d3dcompiler_47 dbghelp dnsapi dwmapi dwrite dxgi gdi32 glu32
hid imm32 iphlpapi kernel32 kernelbase mpr msacm32 msimg32 msvcrt mswsock mf mfplat mfreadwrite mfuuid ncrypt
netapi32 normaliz ntdll ole32 oleaut32 opengl32 powrprof propsys psapi rpcrt4 secur32 setupapi shell32 shlwapi
synchronization ucrtbase urlmon user32 userenv usp10 uxtheme version windowscodecs winhttp wininet winmm
wintrust wldap32 ws2_32 wsock32'''.split())
system_names = {name + '.dll' for name in system_names} | {'winspool.drv'}
python_names = {f'python{major}{minor}.dll', 'python3.dll'}

def pe_imports(path):
    data = path.read_bytes()
    def u16(offset): return struct.unpack_from('<H', data, offset)[0]
    def u32(offset): return struct.unpack_from('<I', data, offset)[0]
    if len(data) < 64 or data[:2] != b'MZ': raise RuntimeError('Not a PE file: ' + str(path))
    header = u32(0x3c)
    if header + 24 > len(data) or data[header:header+4] != b'PE\0\0' or u16(header + 4) != 0x8664:
        raise RuntimeError('The wheel contains a non-x64 PE file: ' + str(path))
    optional = header + 24
    optional_size = u16(header + 20)
    if u16(optional) != 0x20b or optional + optional_size > len(data):
        raise RuntimeError('Invalid PE32+ optional header: ' + str(path))
    sections = []
    for index in range(u16(header + 6)):
        sec = optional + optional_size + index * 40
        if sec + 40 > len(data): raise RuntimeError('Invalid PE section table: ' + str(path))
        sections.append((u32(sec+12), max(u32(sec+8), u32(sec+16)), u32(sec+20)))
    def offset(rva):
        if rva < u32(optional + 60):
            return rva
        for virtual, size, raw in sections:
            if virtual <= rva < virtual + size:
                found = raw + rva - virtual
                if found < len(data): return found
        raise RuntimeError(f'Invalid PE RVA {rva:x}: {path}')
    def name_at(rva):
        start = offset(rva)
        end = data.find(b'\0', start, min(len(data), start + 1024))
        if end < 0: raise RuntimeError('Invalid DLL import name: ' + str(path))
        name = data[start:end].decode('ascii')
        if not re.fullmatch(r'[A-Za-z0-9_.+-]+', name): raise RuntimeError('Invalid DLL import name: ' + name)
        return name
    names = set()
    count = u32(optional + 108)
    for directory, width in ((1,20), (13,32)):
        if count <= directory or optional_size < 112 + 8 * (directory + 1): continue
        rva, size = struct.unpack_from('<II', data, optional + 112 + directory * 8)
        if not rva or not size: continue
        pos = offset(rva)
        for index in range(min(4096, size // width + 1)):
            descriptor = pos + index * width
            if descriptor + width > len(data): raise RuntimeError('Invalid import directory: ' + str(path))
            fields = struct.unpack_from('<' + 'I' * (width // 4), data, descriptor)
            if not any(fields): break
            name_rva = fields[3] if directory == 1 else fields[1]
            if directory == 13 and not fields[0] & 1:
                name_rva -= struct.unpack_from('<Q', data, optional + 24)[0]
            names.add(name_at(name_rva))
    return sorted(names, key=str.lower)

search_roots = [binary_dir]
search_roots.extend(pathlib.Path(p) for p in context.get('runtime_directories', []))
search_roots.extend(pathlib.Path(p) for p in state.get('runtime_directories', []))
search_roots.extend(pathlib.Path(p) for p in state.get('cuda_runtime_bin_dirs', []))
compiler_family = str(state.get('compiler_family') or state.get('toolchain_kind') or
                      ('mingw' if state.get('gcc_version') else 'msvc')).lower()
if compiler_family not in ('mingw', 'msvc'):
    raise RuntimeError('Unsupported compiler family in build state: ' + compiler_family)
# A Visual Studio installation is not a redistributable runtime tree. MSVC
# dependencies and license files must come from the explicit lists above/below.
toolchain = pathlib.Path(state['toolchain_root']) if compiler_family == 'mingw' and state.get('toolchain_root') else None
if toolchain:
    search_roots.extend([toolchain / 'bin', toolchain])
available = {}
for root in search_roots:
    if root.is_dir():
        for file in sorted(root.rglob('*.dll')):
            available.setdefault(file.name.lower(), file.resolve())
workspace = pathlib.Path(tempfile.mkdtemp(prefix='wheel-stage-', dir=context['output_dir']))
package = workspace / 'cv2'
shutil.copytree(source, package, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '*.pyo'))
libs = package / '.libs'
libs.mkdir()
queue = list(natives)
# These video backends are loaded by name and are not necessarily PE imports.
queue.extend(sorted(binary_dir.glob('*opencv_videoio*.dll')))
seen = set()
copied = {}
external = {}
while queue:
    binary = queue.pop(0)
    key = str(binary.resolve()).lower()
    if key in seen: continue
    seen.add(key)
    if binary.suffix.lower() == '.dll':
        target = libs / binary.name
        if binary.name.lower() in copied and copied[binary.name.lower()]['sha256'] != hashlib.sha256(binary.read_bytes()).hexdigest():
            raise RuntimeError('Conflicting DLL versions: ' + binary.name)
        shutil.copy2(binary, target)
        copied[binary.name.lower()] = {'name':binary.name, 'sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
    for dependency in pe_imports(binary):
        low = dependency.lower()
        if low in system_names or low.startswith(('api-ms-win-', 'ext-ms-win-')): continue
        if low in python_names:
            external[low] = 'CPython interpreter'
            continue
        if low == 'nvcuda.dll':
            external[low] = 'NVIDIA display driver'
            continue
        if low in external_names or (external_prefixes and low.startswith(external_prefixes)):
            if not packages: raise RuntimeError('External CUDA DLL has no declared pip runtime dependencies: ' + dependency)
            external[low] = 'Pinned NVIDIA Python runtime packages'
            continue
        candidate = available.get(low)
        if candidate is None:
            raise RuntimeError(f'Unresolved non-system DLL {dependency!r}, imported by {binary}. Add its redistributable directory or an explicit external runtime declaration.')
        queue.append(candidate)

loader_config = '''# Generated for this relocatable wheel. Keep directory handles alive.
import importlib.util as _opencv_util
import pathlib as _opencv_pathlib
import sys as _opencv_sys
BINARIES_PATHS = [os.path.join(LOADER_DIR, '.libs')] + BINARIES_PATHS
_opencv_nvidia_roots = []
_opencv_spec = _opencv_util.find_spec('nvidia')
if _opencv_spec is not None:
    for _opencv_p in (_opencv_spec.submodule_search_locations or []):
        _opencv_nvidia_roots.append(_opencv_pathlib.Path(_opencv_p))
for _opencv_p in _opencv_sys.path:
    if _opencv_p and _opencv_pathlib.Path(_opencv_p).is_dir():
        _opencv_nvidia_roots.append(_opencv_pathlib.Path(_opencv_p) / 'nvidia')
for _opencv_root in _opencv_nvidia_roots:
    if _opencv_root.is_dir():
        for _opencv_dll in _opencv_root.rglob('*.dll'):
            _opencv_dir = str(_opencv_dll.parent.resolve())
            if _opencv_dir not in BINARIES_PATHS:
                BINARIES_PATHS.append(_opencv_dir)
if os.name == 'nt' and hasattr(os, 'add_dll_directory'):
    _opencv_handles = globals().setdefault('_opencv_dll_directory_handles', [])
    for _opencv_dir in BINARIES_PATHS:
        if os.path.isdir(_opencv_dir):
            _opencv_handles.append(os.add_dll_directory(_opencv_dir))
'''
(package / 'config.py').write_text(loader_config, encoding='utf-8')
native_relative = natives[0].parent.relative_to(source).as_posix()
(package / f'config-{major}.{minor}.py').write_text(
    "PYTHON_EXTENSIONS_PATHS = [os.path.join(LOADER_DIR, " + repr(native_relative) + ")] + PYTHON_EXTENSIONS_PATHS\n", encoding='utf-8')

python_info = {'version':platform.python_version(), 'major_minor':f'{major}.{minor}', 'abi':abi,
               'extension_suffix':suffix, 'numpy_version':numpy.__version__, 'runtime_packages':packages}
info = {'schema_version':1, 'distribution':distribution, 'opencv_version':version,
        'python':python_info, 'cuda_required':bool(context['require_cuda']),
        'runtime_dlls':list(copied.values()), 'external_dlls':external,
        'opencv_commit':state.get('opencv_commit'), 'contrib_commit':state.get('contrib_commit'),
        'gcc_version':state.get('gcc_version'), 'compiler_family':compiler_family,
        'validation':'pending: publish only after clean-environment wheel and relocated SDK tests'}
distinfo = workspace / f'{distribution}-{version}.dist-info'
distinfo.mkdir()
metadata = EmailMessage()
metadata['Metadata-Version'] = '2.3'
metadata['Name'] = distribution.replace('_', '-')
metadata['Version'] = version
metadata['Summary'] = 'OpenCV built from pinned official sources with ' + ('MSVC/CUDA' if context['require_cuda'] else 'MinGW-w64')
metadata['Requires-Python'] = f'>={major}.{minor},<{major}.{minor+1}'
metadata['Requires-Dist'] = 'numpy==' + numpy.__version__
for name, pin in sorted(packages.items()): metadata['Requires-Dist'] = name + '==' + str(pin)
metadata['License'] = 'OpenCV and bundled components retain their original licenses; see licenses/'
metadata['Project-URL'] = 'Source, https://github.com/liyiliuxingyu/opencv_mingw'
metadata.set_payload('This wheel contains the cv2 extension produced by this repository build.\n')
(distinfo / 'METADATA').write_bytes(metadata.as_bytes())
(distinfo / 'WHEEL').write_text(f'Wheel-Version: 1.0\nGenerator: opencv-mingw-build\nRoot-Is-Purelib: false\nTag: {abi}-{abi}-win_amd64\n', encoding='utf-8')
(distinfo / 'top_level.txt').write_text('cv2\n', encoding='utf-8')
(distinfo / 'opencv-build-info.json').write_text(json.dumps(info, indent=2) + '\n', encoding='utf-8')

license_count = 0
license_pattern = re.compile(r'(license|licence|copying|copyright|notice)', re.I)
for label, root in [('opencv', install), ('toolchain', toolchain)]:
    if root is None or not root.is_dir(): continue
    for file in root.rglob('*'):
        if file.is_file() and (license_pattern.search(file.name) or any(part.lower() in ('licenses','licences') for part in file.relative_to(root).parts)):
            if file.suffix.lower() in ('.dll','.exe','.pyd','.a','.lib','.o','.obj'): continue
            destination = distinfo / 'licenses' / label / file.relative_to(root)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, destination)
            license_count += 1
license_files = list(context.get('license_files', [])) + list(state.get('runtime_license_files', [])) + list(state.get('license_files', []))
for index, file in enumerate(license_files):
    file = pathlib.Path(file)
    if not file.is_file(): raise RuntimeError('Missing declared runtime license file: ' + str(file))
    destination = distinfo / 'licenses' / 'runtime' / f'{index}-{file.name}'
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(file, destination)
    license_count += 1
if license_count == 0: raise RuntimeError('No OpenCV or runtime license files were found.')
license_sources = (
    'OpenCV source: https://github.com/opencv/opencv/tree/' + str(state.get('opencv_commit') or version) + '\n'
    'contrib source: https://github.com/opencv/opencv_contrib/tree/' + str(state.get('contrib_commit') or version) + '\n')
if toolchain:
    license_sources += 'WinLibs source and component information: https://winlibs.com/\n'
if packages:
    license_sources += 'NVIDIA runtime packages retain their own included licenses and are installed as declared dependencies.\n'
(distinfo / 'licenses' / 'SOURCES.txt').write_text(license_sources, encoding='utf-8')

records = []
for file in sorted(workspace.rglob('*')):
    if file.is_file():
        contents = file.read_bytes()
        digest = base64.urlsafe_b64encode(hashlib.sha256(contents).digest()).rstrip(b'=').decode('ascii')
        records.append((file.relative_to(workspace).as_posix(), 'sha256=' + digest, len(contents)))
record_relative = distinfo.relative_to(workspace).as_posix() + '/RECORD'
records.append((record_relative, '', ''))
with (distinfo / 'RECORD').open('w', encoding='utf-8', newline='') as stream:
    csv.writer(stream, lineterminator='\n').writerows(records)
wheel = output / f'{distribution}-{version}-{abi}-{abi}-win_amd64.whl'
if wheel.exists(): raise RuntimeError('Refusing to overwrite an existing wheel: ' + str(wheel))
with zipfile.ZipFile(wheel, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as archive:
    for file in sorted(workspace.rglob('*')):
        if file.is_file(): archive.write(file, file.relative_to(workspace).as_posix())
result = dict(info)
result.update(wheel_path=str(wheel), wheel_sha256=hashlib.sha256(wheel.read_bytes()).hexdigest(),
              wheel_size=wheel.stat().st_size, license_files=license_count, result='built')
pathlib.Path(context['result_path']).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
shutil.rmtree(workspace)
print('Created ' + str(wheel))
'@
$builderPath = Join-Path $work 'build-wheel.py'
$builder | Set-Content -LiteralPath $builderPath -Encoding utf8NoBOM
& $PythonExecutable -I $builderPath $contextPath 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "Python wheel creation failed. Diagnostic inputs: $work" }
$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $result.wheel_path -PathType Leaf)) { throw 'The wheel was not created.' }
Remove-Item -LiteralPath $work -Recurse -Force
Write-Host "Wheel and exact dependency metadata: $resultPath"
return $result
