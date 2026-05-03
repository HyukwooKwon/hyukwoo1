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
$preferredExternalizedConfigPath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-config\bottest-live-visible\settings.externalized.psd1'
$configPath = if (Test-Path -LiteralPath $preferredExternalizedConfigPath -PathType Leaf) {
    $preferredExternalizedConfigPath
}
else {
    Join-Path $root 'config\settings.bottest-live-visible.psd1'
}
$config = Import-PowerShellDataFile -Path $configPath
$runRootBase = [string]$config.PairTest.RunRootBase
$blockedRunRoot = Join-Path $runRootBase ('run_headless_dispatch_guard_block_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$allowedRunRoot = Join-Path $runRootBase ('run_headless_dispatch_guard_allow_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

foreach ($path in @($blockedRunRoot, $allowedRunRoot)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

$blockedOutput = @(
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $configPath `
        -RunRoot $blockedRunRoot `
        -IncludePairId pair01 `
        -UseHeadlessDispatch 2>&1
)
$blockedExitCode = $LASTEXITCODE
$blockedDetail = ($blockedOutput | Out-String)

Assert-True ($blockedExitCode -ne 0) 'Start-PairedExchangeTest should reject headless dispatch in the shared visible typed-window lane.'
Assert-True ($blockedDetail.Contains('headless-dispatch-disallowed-in-shared-visible-typed-window')) 'failure output should mention the typed-window headless guard.'
Assert-True ($blockedDetail.Contains('-AllowHeadlessDispatchInTypedWindowLane')) 'failure output should explain the explicit override switch.'

$allowedOutput = @(
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $configPath `
        -RunRoot $allowedRunRoot `
        -IncludePairId pair01 `
        -UseHeadlessDispatch `
        -AllowHeadlessDispatchInTypedWindowLane 2>&1
)
$allowedExitCode = $LASTEXITCODE
$allowedDetail = ($allowedOutput | Out-String)

Assert-True ($allowedExitCode -eq 0) 'explicit override should allow intentional headless dispatch setup in the shared visible lane.'
Assert-True ((Test-Path -LiteralPath (Join-Path $allowedRunRoot 'manifest.json') -PathType Leaf)) 'override path should still prepare the run root manifest.'
Assert-True (-not $allowedDetail.Contains('headless-dispatch-disallowed-in-shared-visible-typed-window')) 'override path should bypass the guard.'

Write-Host 'start-paired-exchange-test headless dispatch guard ok'
