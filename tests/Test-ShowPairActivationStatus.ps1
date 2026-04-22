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
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')
. (Join-Path $PSScriptRoot 'PairActivation.ps1')

$testRoot = Join-Path $root ('_tmp\pair-activation-status-test-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
Ensure-Directory -Path $testRoot
$configPath = Join-Path $testRoot 'config.psd1'
$statePath = Join-Path $testRoot 'runtime\pair-activation\state.json'

@"
@{
    LaneName = 'pair-activation-status-test'
    PairActivation = @{
        StatePath = '$($statePath.Replace("'", "''"))'
        DefaultEnabled = `$true
    }
}
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

$config = Import-PowerShellDataFile -Path $configPath
[void](Set-PairActivationDisabled -Root $testRoot -Config $config -PairId 'pair02' -Reason 'status test')

$json = & (Join-Path $PSScriptRoot 'Show-PairActivationStatus.ps1') -ConfigPath $configPath -PairId @('pair01', 'pair02') -AsJson
$payload = $json | ConvertFrom-Json

Assert-True ($payload.SchemaVersion -eq '1.0.0') 'Expected SchemaVersion 1.0.0.'
Assert-True ($payload.LaneName -eq 'pair-activation-status-test') 'Expected lane name in payload.'
Assert-True ($payload.Summary.PairCount -eq 2) 'Expected two pair rows.'
Assert-True ($payload.Summary.DisabledCount -eq 1) 'Expected one disabled pair.'
Assert-True ($payload.Summary.EnabledCount -eq 1) 'Expected one enabled pair.'

$pair02 = @($payload.Pairs | Where-Object { $_.PairId -eq 'pair02' })[0]
Assert-True ($null -ne $pair02) 'Expected pair02 row.'
Assert-True ($pair02.EffectiveEnabled -eq $false) 'Expected pair02 to be blocked.'
Assert-True ($pair02.DisableReason -eq 'status test') 'Expected pair02 reason to round-trip.'

Write-Host ('pair-activation status contract ok: statePath=' + $statePath)
