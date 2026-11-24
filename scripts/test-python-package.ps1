#requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'Loader')]
param(
    [Parameter(Mandatory)][string] $PythonExecutable,
    [Parameter(Mandatory)][string] $WorkRoot,
    [Parameter(Mandatory, ParameterSetName = 'Wheel')][string] $WheelPath,
    [Parameter(Mandatory, ParameterSetName = 'Loader')][string] $PackageRoot,
    [string] $ExpectedVersion,
    [string] $NumPyVersion,
    [hashtable] $ExternalRuntimePackages = @{},
    [string[]] $RuntimeDirectories = @(),
    [switch] $RequireCuda,
    [switch] $RequireGpu,
    [switch] $KeepEnvironment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'Python package tests require native Windows.' }
$PythonExecutable = (Resolve-Path -LiteralPath $PythonExecutable).Path
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
$testRoot = Join-Path $WorkRoot ('python-check-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$resultPath = Join-Path $WorkRoot 'python-test-result.json'
if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force }
$smokeScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'examples/python/smoke.py'
if (-not (Test-Path -LiteralPath $smokeScript -PathType Leaf)) { throw 'The Python smoke test is missing.' }

function Invoke-PythonTestChecked {
    param([string] $File, [string[]] $Arguments, [string] $LogName)
    & $File @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $testRoot $LogName) -Append | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE. See $testRoot/$LogName" }
}

$metadata = @{}
if ($PSCmdlet.ParameterSetName -eq 'Wheel') {
    $WheelPath = (Resolve-Path -LiteralPath $WheelPath).Path
    $readWheel = @'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = [n for n in archive.namelist() if n.endswith('.dist-info/opencv-build-info.json')]
    if len(names) != 1: raise RuntimeError('The wheel must contain exactly one build metadata record.')
    print(archive.read(names[0]).decode('utf-8'))
'@
    $metadataJson = & $PythonExecutable -I -c $readWheel $WheelPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the actual OpenCV wheel build metadata.' }
    $metadata = ($metadataJson | Out-String) | ConvertFrom-Json -AsHashtable
} else {
    $PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
    $metadataFile = Join-Path $PackageRoot 'build-info.json'
    if (Test-Path -LiteralPath $metadataFile) {
        $metadata = Get-Content -LiteralPath $metadataFile -Raw | ConvertFrom-Json -AsHashtable
    }
}
$pythonMetadata = if ($metadata.ContainsKey('python') -and $metadata.python) { $metadata.python } else { @{} }
if (-not $ExpectedVersion -and $metadata.ContainsKey('opencv_version')) { $ExpectedVersion = $metadata.opencv_version }
if (-not $ExpectedVersion) { throw 'ExpectedVersion is required when the package has no OpenCV version metadata.' }
if (-not $NumPyVersion) {
    if ($pythonMetadata.ContainsKey('numpy_version')) { $NumPyVersion = $pythonMetadata.numpy_version }
    elseif ($metadata.ContainsKey('python_numpy_version')) { $NumPyVersion = $metadata.python_numpy_version }
    else {
        $NumPyVersion = (& $PythonExecutable -I -c 'import numpy; print(numpy.__version__)' | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Supply the exact build NumPy version or include it in package metadata.' }
    }
}
if ($NumPyVersion -notmatch '^\d+\.\d+\.\d+([A-Za-z0-9.+-]*)$') { throw 'The NumPy dependency must have an exact version.' }
if ($ExternalRuntimePackages.Count -eq 0) {
    if ($pythonMetadata.ContainsKey('runtime_packages') -and $pythonMetadata.runtime_packages) {
        $ExternalRuntimePackages = $pythonMetadata.runtime_packages
    } elseif ($metadata.ContainsKey('cuda_python_runtime_packages') -and $metadata.cuda_python_runtime_packages) {
        $ExternalRuntimePackages = $metadata.cuda_python_runtime_packages
    }
}
if (($metadata.ContainsKey('cuda_required') -and $metadata.cuda_required) -or
    ($metadata.ContainsKey('cuda_enabled') -and $metadata.cuda_enabled)) { $RequireCuda = $true }
$pythonMinor = (& $PythonExecutable -I -c 'import sys; print("%d.%d" % sys.version_info[:2])' | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not query the test Python interpreter.' }
if ($pythonMetadata.ContainsKey('major_minor') -and $pythonMetadata.major_minor -ne $pythonMinor) {
    throw "The package requires Python $($pythonMetadata.major_minor), but the test interpreter is $pythonMinor."
}
if ($pythonMetadata.ContainsKey('abi') -and $pythonMetadata.abi -ne ('cp' + $pythonMinor.Replace('.', ''))) {
    throw 'The test interpreter does not match the wheel ABI.'
}

try {
    $venv = Join-Path $testRoot 'venv'
    Invoke-PythonTestChecked $PythonExecutable @('-I', '-m', 'venv', $venv) 'venv.log'
    $venvPython = Join-Path $venv 'Scripts/python.exe'
    $pipArguments = @('-I', '-m', 'pip', 'install', '--only-binary=:all:', '--disable-pip-version-check', '--no-cache-dir',
        '--report', (Join-Path $testRoot 'pip-install-report.json'))
    if ($PSCmdlet.ParameterSetName -eq 'Wheel') {
        $pipArguments += $WheelPath
    } else {
        $pipArguments += "numpy==$NumPyVersion"
        foreach ($name in ($ExternalRuntimePackages.Keys | Sort-Object)) {
            $pin = [string]$ExternalRuntimePackages[$name]
            if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $pin -notmatch '^[0-9][A-Za-z0-9.+_-]*$') {
                throw 'External runtime packages require exact package/version pins.'
            }
            $pipArguments += "$name==$pin"
        }
    }
    Invoke-PythonTestChecked $venvPython $pipArguments 'pip-install.log'
    if ($PSCmdlet.ParameterSetName -eq 'Wheel') {
        $originRoot = (& $venvPython -I -c 'import sysconfig; print(sysconfig.get_path("platlib"))' | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not locate the fresh virtual environment.' }
        $moduleRoot = $null
    } else {
        $originRoot = $PackageRoot
        $moduleRoot = Join-Path $PackageRoot 'opencv/python'
        if (-not (Test-Path -LiteralPath (Join-Path $moduleRoot 'cv2/__init__.py'))) {
            throw "The actual installed cv2 loader was not found: $moduleRoot"
        }
        if ($metadata.ContainsKey('opencv_bin_dir')) {
            $binaryDir = [IO.Path]::GetFullPath((Join-Path $PackageRoot $metadata.opencv_bin_dir))
            $relative = [IO.Path]::GetRelativePath($PackageRoot, $binaryDir)
            if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..\') -or $relative.StartsWith('../')) {
                throw 'OpenCV binary directory escapes the tested package.'
            }
            $RuntimeDirectories += $binaryDir
        }
    }
    $smokeArguments = @('-I', $smokeScript, '--origin-root', $originRoot, '--expected-version', $ExpectedVersion,
        '--expected-python', $pythonMinor, '--expected-numpy', $NumPyVersion, '--result-path', $resultPath)
    if ($moduleRoot) { $smokeArguments += @('--module-root', $moduleRoot) }
    foreach ($directory in $RuntimeDirectories) { $smokeArguments += @('--dll-dir', $directory) }
    if ($RequireCuda) { $smokeArguments += '--require-cuda' }
    if ($RequireGpu) { $smokeArguments += '--require-gpu' }
    $oldPath = $env:PATH
    $oldPythonPath = $env:PYTHONPATH
    $oldNoUserSite = $env:PYTHONNOUSERSITE
    try {
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        $env:PYTHONPATH = $null
        $env:PYTHONNOUSERSITE = '1'
        Invoke-PythonTestChecked $venvPython $smokeArguments 'smoke.log'
    } finally {
        $env:PATH = $oldPath
        $env:PYTHONPATH = $oldPythonPath
        $env:PYTHONNOUSERSITE = $oldNoUserSite
    }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
    if ($result.result -ne 'passed') { throw 'The Python package smoke test did not pass.' }
    $result['package_mode'] = $PSCmdlet.ParameterSetName.ToLowerInvariant()
    $result['test_root'] = $testRoot
    $result['runtime_packages'] = $ExternalRuntimePackages
    $result['pip_install_report'] = Join-Path $testRoot 'pip-install-report.json'
    if ($PSCmdlet.ParameterSetName -eq 'Wheel') {
        $result['wheel_path'] = $WheelPath
        $result['wheel_sha256'] = (Get-FileHash -LiteralPath $WheelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if (-not $KeepEnvironment) { Remove-Item -LiteralPath $venv -Recurse -Force }
    $result['test_environment_retained'] = [bool]$KeepEnvironment
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
    Write-Host "Python package verification passed: $resultPath"
    return [pscustomobject]$result
} catch {
    if (-not (Test-Path -LiteralPath $resultPath)) {
        @{schema_version=1; result='failed'; error=$_.Exception.Message; test_root=$testRoot; gpu_execution='not-tested'} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
    }
    throw
}
