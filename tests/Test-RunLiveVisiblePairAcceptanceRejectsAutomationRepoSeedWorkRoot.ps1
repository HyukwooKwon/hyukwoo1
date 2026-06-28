[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$runRoot = Join-Path $root '_tmp\Test-RunLiveVisiblePairAcceptanceRejectsAutomationRepoSeedWorkRoot'
if (Test-Path -LiteralPath $runRoot) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$Error.Clear()
try {
    $output = @(
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1') `
            -ConfigPath $configPath `
            -RunRoot $runRoot `
            -PairId pair01 `
            -SeedTargetId target01 `
            -SeedWorkRepoRoot $root `
            -SeedReviewInputPath (Join-Path $root 'README.md') `
            -PreflightOnly `
            -AsJson 2>&1
    )
    $exitCode = $LASTEXITCODE
    $capturedNativeErrors = @($Error | ForEach-Object { $_ | Out-String -Width 4096 })
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

Assert-True ($exitCode -ne 0) 'Run-LiveVisiblePairAcceptance should reject automation repo as seed work repo before preflight.'
$detail = ((@($output) | ForEach-Object { $_ | Out-String -Width 4096 }) + @($capturedNativeErrors)) -join [Environment]::NewLine
Assert-True ($detail.Contains('automation-repo-workrepo-disallowed')) 'failure output should mention automation-repo-workrepo-disallowed.'

Write-Host 'run-live-visible-pair-acceptance external work repo guard ok'
