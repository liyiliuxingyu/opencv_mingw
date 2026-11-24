#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$previousCode = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
$previousNativeExitCode = if ($previousCode) { [int]$previousCode.Value } else { 0 }

# repository_dispatch is one of the events that GITHUB_TOKEN is allowed to
# trigger. Release events emitted by GITHUB_TOKEN do not start another workflow.
# A refresh failure must not invalidate an already verified, published release;
# workflow_run and the hourly maintenance job provide independent retry paths.
try {
    if ($env:GITHUB_REPOSITORY -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or -not $env:GH_TOKEN) {
        throw 'Repository context and the publishing job token are required.'
    }
    & gh api --method POST "repos/$env:GITHUB_REPOSITORY/dispatches" `
        -f 'event_type=windows-release-published' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Repository dispatch failed with exit code $LASTEXITCODE." }
    Write-Host 'Requested an update of the Windows download index.'
} catch {
    Write-Warning "The release is published, but its immediate download-index refresh could not be requested. The scheduled/workflow completion refresh can retry. $($_.Exception.Message)"
} finally {
    # GitHub's pwsh wrapper exits with LASTEXITCODE. Preserve the successful
    # publisher's native status even when this optional notification fails.
    $global:LASTEXITCODE = $previousNativeExitCode
}
