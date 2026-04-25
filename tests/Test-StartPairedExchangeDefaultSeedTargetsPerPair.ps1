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
$tmpRoot = Join-Path $root '_tmp\Test-StartPairedExchangeDefaultSeedTargetsPerPair'
$runRoot = Join-Path $tmpRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01,pair02 | Out-Null

$manifest = Get-Content -LiteralPath (Join-Path $runRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$target02 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
$target05 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target05' } | Select-Object -First 1)[0]
$target06 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target06' } | Select-Object -First 1)[0]
$pair01 = @($manifest.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)[0]
$pair02 = @($manifest.Pairs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)[0]

Assert-True ([string]$manifest.SeedTargetId -eq '') 'multi-pair prepare should not collapse to a single root seed target id.'
Assert-True (@($manifest.SeedTargetIds).Count -eq 2) 'multi-pair prepare should default one seed target per pair.'
Assert-True ([string]$target01.InitialRoleMode -eq 'seed') 'pair01 top target should default to seed mode.'
Assert-True ([string]$target02.InitialRoleMode -eq 'seed') 'pair02 top target should default to seed mode.'
Assert-True ([string]$target05.InitialRoleMode -eq 'handoff_wait') 'pair01 bottom target should default to handoff wait mode.'
Assert-True ([string]$target06.InitialRoleMode -eq 'handoff_wait') 'pair02 bottom target should default to handoff wait mode.'
Assert-True ([bool]$target01.SeedEnabled) 'pair01 top target should be marked seed enabled.'
Assert-True ([bool]$target02.SeedEnabled) 'pair02 top target should be marked seed enabled.'
Assert-True (-not [bool]$target05.SeedEnabled) 'pair01 bottom target should not be seed enabled.'
Assert-True (-not [bool]$target06.SeedEnabled) 'pair02 bottom target should not be seed enabled.'
Assert-True ([string]$pair01.Policy.DefaultSeedTargetId -eq 'target01') 'pair01 manifest row should persist pair policy seed target.'
Assert-True ([string]$pair02.Policy.DefaultSeedTargetId -eq 'target02') 'pair02 manifest row should persist pair policy seed target.'
Assert-True ([string]$target01.PairPolicy.PublishContractMode -eq 'strict') 'target request rows should persist pair publish contract mode.'

Write-Host ('start paired exchange default seed targets per pair ok: runRoot=' + $runRoot)
