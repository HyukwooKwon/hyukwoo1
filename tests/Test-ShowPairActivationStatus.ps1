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
    PairTest = @{
        PairDefinitions = @(
            @{ PairId = 'pair10'; TopTargetId = 'target10'; BottomTargetId = 'target20' }
            @{ PairId = 'pair11'; TopTargetId = 'target11'; BottomTargetId = 'target21' }
        )
    }
}
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

$config = Import-PowerShellDataFile -Path $configPath
[void](Set-PairActivationDisabled -Root $testRoot -Config $config -PairId 'pair11' -Reason 'status test')

$json = & (Join-Path $PSScriptRoot 'Show-PairActivationStatus.ps1') -ConfigPath $configPath -AsJson
$payload = $json | ConvertFrom-Json

Assert-True ($payload.SchemaVersion -eq '1.0.0') 'Expected SchemaVersion 1.0.0.'
Assert-True ($payload.LaneName -eq 'pair-activation-status-test') 'Expected lane name in payload.'
Assert-True ($payload.Summary.PairCount -eq 2) 'Expected two pair rows.'
Assert-True ($payload.Summary.DisabledCount -eq 1) 'Expected one disabled pair.'
Assert-True ($payload.Summary.EnabledCount -eq 1) 'Expected one enabled pair.'
Assert-True ((@($payload.Pairs | Where-Object { $_.PairId -eq 'pair10' }).Count -eq 1)) 'Expected configured pair10 row.'
Assert-True ((@($payload.Pairs | Where-Object { $_.PairId -eq 'pair01' }).Count -eq 0)) 'Did not expect fallback pair01 row when config defines pair ids.'

$pair11 = @($payload.Pairs | Where-Object { $_.PairId -eq 'pair11' })[0]
Assert-True ($null -ne $pair11) 'Expected pair11 row.'
Assert-True ($pair11.EffectiveEnabled -eq $false) 'Expected pair11 to be blocked.'
Assert-True ($pair11.DisableReason -eq 'status test') 'Expected pair11 reason to round-trip.'

Write-Host ('pair-activation status contract ok: statePath=' + $statePath)
