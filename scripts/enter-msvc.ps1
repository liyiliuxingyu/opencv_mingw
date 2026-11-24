#requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'MSVC requires Windows.' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Install Visual Studio 2022 with Desktop development with C++.' }
$installation = (& $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'A supported Visual Studio 2022 x64 C++ toolset was not found.' }
$vcvars = Join-Path $installation 'VC/Auxiliary/Build/vcvars64.bat'
# Capture environment output privately: it can contain CI credentials.
$command = '"' + $vcvars + '" >nul && set'
$environmentLines = @(& $env:ComSpec /D /S /C $command)
if ($LASTEXITCODE -ne 0) { throw 'Visual Studio environment initialization failed.' }
foreach ($line in $environmentLines) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
}
$cl = (Get-Command cl.exe -ErrorAction Stop).Source
$dumpbin = (Get-Command dumpbin.exe -ErrorAction Stop).Source
if ($env:VSCMD_ARG_TGT_ARCH -ne 'x64') { throw 'The selected MSVC environment is not x64.' }
$version = (Get-Item -LiteralPath $cl).VersionInfo.FileVersion
[pscustomobject]@{
    installation_root = $installation
    vcvars_path = $vcvars
    compiler = $cl
    compiler_executable = $cl
    dumpbin = $dumpbin
    compiler_version = $version
    msvc_version = $version
    toolset_version = $env:VCToolsVersion
    redist_root = $env:VCToolsRedistDir
}
