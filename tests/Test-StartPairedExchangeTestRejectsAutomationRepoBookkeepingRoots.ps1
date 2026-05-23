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
$externalFixtureRoot = 'C:\dev\python\_relay-test-fixtures'
$tmpRoot = Join-Path $externalFixtureRoot 'Test-StartPairedExchangeTestRejectsAutomationRepoBookkeepingRoots'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$reviewRoot = Join-Path $workRepoRoot 'reviewfile'
$reviewInputPath = Join-Path $reviewRoot 'seed-input.zip'

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
Set-Content -LiteralPath $reviewInputPath -Value 'seed-input' -Encoding UTF8

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$generated = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath $baseConfigPath `
    -WorkRepoRoot $workRepoRoot `
    -ReviewInputPath $reviewInputPath `
    -PairId 'pair01' `
    -AsJson | ConvertFrom-Json
$generatedConfigPath = [string]$generated.OutputConfigPath
$configPath = Join-Path (Split-Path -Parent $generatedConfigPath) 'settings.externalized.internal-routerstate.psd1'
$escapedGeneratedRouterStatePath = ([string]$generated.RouterStatePath).Replace("'", "''")
$escapedInternalRouterStatePath = (Join-Path $root 'runtime\bottest-live-visible\router-state.json').Replace("'", "''")
$configText = Get-Content -LiteralPath $generatedConfigPath -Raw -Encoding UTF8
$configText = $configText.Replace(
    ("RouterStatePath = '" + $escapedGeneratedRouterStatePath + "'"),
    ("RouterStatePath = '" + $escapedInternalRouterStatePath + "'")
)
Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8

$stdoutPath = Join-Path $tmpRoot 'start-paired-exchange.stdout.txt'
$stderrPath = Join-Path $tmpRoot 'start-paired-exchange.stderr.txt'
$process = Start-Process `
    -FilePath 'pwsh.exe' `
    -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'tests\Start-PairedExchangeTest.ps1'),
        '-ConfigPath', $configPath,
        '-IncludePairId', 'pair01',
        '-SeedTargetId', 'target01',
        '-SeedWorkRepoRoot', $workRepoRoot,
        '-SeedReviewInputPath', $reviewInputPath
    ) `
    -Wait `
    -NoNewWindow `
    -PassThru `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath
$exitCode = [int]$process.ExitCode
$detail = ''
if (Test-Path -LiteralPath $stdoutPath) {
    $detail += (Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8)
}
if (Test-Path -LiteralPath $stderrPath) {
    $detail += (Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8)
}

Assert-True ($exitCode -ne 0) 'Start-PairedExchangeTest should reject bookkeeping roots that still point into the automation repo.'
Assert-True ($detail.Contains('automation-repo-bookkeeping-roots-disallowed')) 'failure output should mention automation-repo-bookkeeping-roots-disallowed.'

Write-Host 'start-paired-exchange-test bookkeeping roots guard ok'
