#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateFile,
    [Parameter(Mandatory)][string]$ResultFile,
    [Parameter(Mandatory)][string]$PythonExecutable,
    [Parameter(Mandatory)][string]$WorkRoot,
    [switch]$RequireGPU
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$state=Get-Content -LiteralPath $StateFile -Raw|ConvertFrom-Json
$result=Get-Content -LiteralPath $ResultFile -Raw|ConvertFrom-Json
$output=Split-Path -Parent (Resolve-Path $ResultFile).Path
$WorkRoot=[IO.Path]::GetFullPath($WorkRoot)
if(Test-Path $WorkRoot){throw 'Use a fresh CUDA verification directory.'}
New-Item -ItemType Directory -Path $WorkRoot|Out-Null
$started=[DateTime]::UtcNow.ToString('o')
$vs=& (Join-Path $PSScriptRoot 'enter-msvc.ps1')
$developerPath=$env:PATH
$windows=@((Join-Path $env:SystemRoot 'System32'),$env:SystemRoot)
$external=@($state.runtime_directories|Where-Object{$_ -notmatch 'Microsoft\.VC\d+\.(CRT|OpenMP)'})
$env:CUDA_PATH=[string]$state.cuda_root
$env:CUDNN_PATH=[string]$state.cudnn_root
$reports=[Collections.Generic.List[object]]::new()
function Run([string]$exe,[string[]]$arguments,[string]$log){
    & $exe @arguments 2>&1|Tee-Object -FilePath $log|Write-Host
    if($LASTEXITCODE -ne 0){throw "$exe failed. See $log"}
}
function Test-SDK([string]$root,[string]$label){
    $metadata=Get-Content (Join-Path $root 'build-info.json') -Raw|ConvertFrom-Json
    if($metadata.toolchain_kind -ne 'msvc' -or -not $metadata.features.cuda -or $metadata.configuration -ne 'Release') {throw 'Incorrect CUDA SDK metadata.'}
    $bin=Join-Path $root $metadata.opencv_bin_dir
    $cmakeDir=Join-Path $root $metadata.opencv_cmake_dir
    $work=Join-Path $WorkRoot $label
    New-Item -ItemType Directory -Path $work|Out-Null
    $env:PATH=(@($bin)+$external+@($developerPath)) -join ';'
    Run $state.cmake_executable @('-S',"$root/examples/cuda",'-B',"$work/build",'-G','Ninja',
        "-DCMAKE_MAKE_PROGRAM=$($state.ninja_executable)","-DCMAKE_CXX_COMPILER=$($vs.compiler)",
        '-DCMAKE_BUILD_TYPE=Release',"-DOpenCV_DIR=$cmakeDir",'-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF',
        '-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF',"-DCUDAToolkit_ROOT=$($state.cuda_root)",
        '-DOPENCV_STRONG_CUDA_VERSION_CHECK=ON') "$work/configure.log"
    Run $state.cmake_executable @('--build',"$work/build",'--parallel','2') "$work/build.log"
    $env:PATH=(@($bin)+$external+$windows)-join ';'
    Run "$work/build/opencv_cuda_smoke.exe" @("$work/results",'--expected-version',[string]$result.opencv_version,
        '--expected-configuration','Release','--require-ffmpeg') "$work/run.log"
    $gpuArgs=@("$work/gpu-verification.json")
    if($RequireGPU){$gpuArgs+='--require-gpu'}
    Run "$work/build/opencv_cuda_device.exe" $gpuArgs "$work/gpu.log"
    $env:PATH=$developerPath
    & (Join-Path $PSScriptRoot 'test-python-package.ps1') -PythonExecutable $PythonExecutable -PackageRoot $root `
        -WorkRoot "$work/python" -ExpectedVersion $result.opencv_version -RequireCuda
    $reports.Add([ordered]@{
        location=$label;cpp='passed';gpu=(Get-Content "$work/gpu-verification.json" -Raw|ConvertFrom-Json)
        python=(Get-Content "$work/python/python-test-result.json" -Raw|ConvertFrom-Json)
    })
}
try{
    Test-SDK $result.package_root 'staged SDK'
    $zipParent=Join-Path $WorkRoot 'ZIP extraction with spaces'
    Expand-Archive -LiteralPath $result.zip_path -DestinationPath $zipParent
    Test-SDK (Join-Path $zipParent $result.package_name) 'ZIP consumer'
    Remove-Item -LiteralPath $zipParent -Recurse -Force
    $installed=Join-Path $WorkRoot 'installed CUDA SDK with spaces'
    $installLog=Join-Path $WorkRoot 'installer.log'
    $p=Start-Process -FilePath $result.installer_path -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installed`"","/LOG=`"$installLog`"") -Wait -PassThru
    if($p.ExitCode -ne 0){throw "CUDA installer exited $($p.ExitCode)."}
    Test-SDK $installed 'installed consumer'
    $uninstall=Join-Path $installed 'unins000.exe'
    $uninstallLog=Join-Path $WorkRoot 'uninstaller.log'
    $p=Start-Process -FilePath $uninstall -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$uninstallLog`"") -Wait -PassThru
    if($p.ExitCode -ne 0){throw "CUDA uninstaller exited $($p.ExitCode)."}
    foreach($file in @('activate.cmd','build-info.json','install-python.cmd')){
        if(Test-Path (Join-Path $installed $file)){throw "Uninstall left $file"}
    }
}finally{$env:PATH=$developerPath}
$gpuPassed=@($reports|Where-Object{$_.gpu.gpu_execution -eq 'passed'}).Count -eq 3
$report=[ordered]@{
    schema_version=1;package_name=$result.package_name;toolchain_kind='msvc';configuration='Release'
    opencv_version=$result.opencv_version;cuda_version=$result.cuda_version;cudnn_version=$result.cudnn_version
    result='passed';gpu_execution=if($gpuPassed){'passed'}else{'not-tested-no-compatible-device'}
    validation_scope='Native C++ compile/link/run, CPython import and CPU operations, CUDA/cuDNN build capability, ZIP relocation, EXE installation/uninstall'
    started_at_utc=$started;completed_at_utc=[DateTime]::UtcNow.ToString('o')
    workflow_commit=$env:GITHUB_SHA;github_run_id=$env:GITHUB_RUN_ID;github_run_attempt=$env:GITHUB_RUN_ATTEMPT
    locations=$reports.ToArray()
}
$path=Join-Path $output 'verification.json'
$report|ConvertTo-Json -Depth 25|Set-Content -LiteralPath $path -Encoding utf8NoBOM
"$((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant())  verification.json"|Add-Content -LiteralPath $result.checksums_path -Encoding utf8NoBOM
Write-Host "CUDA SDK distribution checks passed. GPU execution: $($report.gpu_execution)"
