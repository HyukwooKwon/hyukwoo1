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
$runRoot = Join-Path ([string]$config.PairTest.RunRootBase) ('run_watch_headless_dispatch_guard_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
if (Test-Path -LiteralPath $runRoot) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force
}

& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 | Out-Null
Assert-True ((Test-Path -LiteralPath (Join-Path $runRoot 'manifest.json') -PathType Leaf)) 'prepared run root should contain a manifest before watch guard validation.'

$watchOutput = @(
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-PairedExchange.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -UseHeadlessDispatch `
        -RunDurationSec 5 2>&1
)
$watchExitCode = $LASTEXITCODE
$watchDetail = ($watchOutput | Out-String)

Assert-True ($watchExitCode -ne 0) 'Watch-PairedExchange should reject headless dispatch in the shared visible typed-window lane.'
Assert-True ($watchDetail.Contains('headless-dispatch-disallowed-in-shared-visible-typed-window')) 'watcher failure output should mention the typed-window headless guard.'
Assert-True ($watchDetail.Contains('-AllowHeadlessDispatchInTypedWindowLane')) 'watcher failure output should explain the explicit override switch.'

Write-Host 'watch-paired-exchange headless dispatch guard ok'
