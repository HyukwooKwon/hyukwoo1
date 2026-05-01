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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

$root = Split-Path -Parent $PSScriptRoot
$fixtureRoot = 'C:\dev\python\_relay-test-fixtures'
$tempRoot = Join-Path $fixtureRoot 'Test-StartPairedExchangePairScopedExternalizedRunRoot'
$repoA = Join-Path $tempRoot 'repo-a'
$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'

if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $repoA -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $repoA 'reviewfile') -Force | Out-Null
$seedInputDir = Join-Path $tempRoot 'seed-input'
New-Item -ItemType Directory -Path $seedInputDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $seedInputDir 'smoke-note.txt'), 'pair scoped externalized run root test')
$seedReviewInputPath = Join-Path $repoA 'reviewfile\seed_review_input_latest.zip'
Compress-Archive -LiteralPath (Join-Path $seedInputDir 'smoke-note.txt') -DestinationPath $seedReviewInputPath -Force

$externalized = & (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath $baseConfigPath `
    -WorkRepoRoot $repoA `
    -ReviewInputPath $seedReviewInputPath `
    -PairId 'pair01' `
    -AsJson | ConvertFrom-Json

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath ([string]$externalized.OutputConfigPath) `
    -IncludePairId @('pair01') | Out-Null

$manifestFile = @(
    Get-ChildItem -LiteralPath ([string]$externalized.PairRunRootBase) -Filter manifest.json -File -Recurse -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
)
Assert-True (@($manifestFile).Count -eq 1) 'manifest file should exist under pair-scoped run root base.'
$manifest = Get-Content -LiteralPath ([string]$manifestFile[0].FullName) -Raw -Encoding UTF8 | ConvertFrom-Json
$runRoot = [string]$manifest.RunRoot
Assert-True ($runRoot.StartsWith((Join-Path $repoA '.relay-runs\bottest-live-visible\pairs\pair01'), [System.StringComparison]::OrdinalIgnoreCase)) 'pair-scoped externalized config should drive run root under pair-scoped external run root base.'

Write-Host 'start-paired-exchange pair-scoped externalized run root ok'
