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

$testRoot = Join-Path $root ('_tmp\pair-activation-test-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
Ensure-Directory -Path $testRoot
$config = @{
    LaneName = 'pair-activation-test'
    PairActivation = @{
        StatePath = (Join-Path $testRoot 'runtime\pair-activation\state.json')
        DefaultEnabled = $true
    }
}

$initial = Get-PairActivationState -Root $testRoot -Config $config -PairId 'pair02'
Assert-True ($initial.EffectiveEnabled -eq $true) 'Expected pair02 to be enabled by default.'
Assert-True ($initial.State -eq 'enabled') 'Expected default enabled state.'

$disabled = Set-PairActivationDisabled -Root $testRoot -Config $config -PairId 'pair02' -Reason 'unit test'
Assert-True ($disabled.EffectiveEnabled -eq $false) 'Expected disabled state to block execution.'
Assert-True ($disabled.State -eq 'disabled') 'Expected disabled state.'
Assert-True ((Test-Path -LiteralPath ([string]$disabled.StatePath))) 'Expected state file to be created.'

$summary = @(Get-PairActivationSummary -Root $testRoot -Config $config -PairIds @('pair01', 'pair02'))
Assert-True ($summary.Count -eq 2) 'Expected two pair activation rows.'
Assert-True ((@($summary | Where-Object { $_.PairId -eq 'pair02' })[0].EffectiveEnabled -eq $false)) 'Expected pair02 summary row to be disabled.'

$configDriven = @{
    LaneName = 'pair-activation-config-driven'
    PairActivation = @{
        StatePath = (Join-Path $testRoot 'runtime\pair-activation\config-driven.json')
        DefaultEnabled = $true
    }
    PairTest = @{
        PairDefinitions = @(
            @{ PairId = 'pair10'; TopTargetId = 'target10'; BottomTargetId = 'target20' }
            @{ PairId = 'pair11'; TopTargetId = 'target11'; BottomTargetId = 'target21' }
        )
    }
}

[void](Set-PairActivationDisabled -Root $testRoot -Config $configDriven -PairId 'pair11' -Reason 'config driven')
$configDrivenSummary = @(Get-PairActivationSummary -Root $testRoot -Config $configDriven)
Assert-True ($configDrivenSummary.Count -eq 2) 'Expected config-driven summary to use configured pair definitions.'
Assert-True ((@($configDrivenSummary | Where-Object { $_.PairId -eq 'pair10' }).Count -eq 1)) 'Expected configured pair10 row in config-driven summary.'
Assert-True ((@($configDrivenSummary | Where-Object { $_.PairId -eq 'pair11' }).Count -eq 1)) 'Expected configured pair11 row in config-driven summary.'
Assert-True ((@($configDrivenSummary | Where-Object { $_.PairId -eq 'pair01' }).Count -eq 0)) 'Did not expect fallback pair01 row when config defines pair ids.'

$enabled = Set-PairActivationEnabled -Root $testRoot -Config $config -PairId 'pair02'
Assert-True ($enabled.EffectiveEnabled -eq $true) 'Expected enabled state after enable.'
Assert-True ($enabled.State -eq 'enabled') 'Expected enabled state after enable.'

$expiredRaw = Set-PairActivationDisabled -Root $testRoot -Config $config -PairId 'pair03' -Reason 'expired test' -DisabledUntil '2000-01-01T00:00:00+09:00'
Assert-True ($expiredRaw.EffectiveEnabled -eq $true) 'Expected expired disabled state to auto-enable.'
Assert-True ($expiredRaw.State -eq 'expired-auto-enabled') 'Expected expired-auto-enabled state.'

$asserted = Assert-PairActivationEnabled -Root $testRoot -Config $config -PairId 'pair03'
Assert-True ($asserted.EffectiveEnabled -eq $true) 'Expected assert helper to allow expired-auto-enabled state.'

$blocked = $false
try {
    [void](Set-PairActivationDisabled -Root $testRoot -Config $config -PairId 'pair04' -Reason 'blocked test')
    [void](Assert-PairActivationEnabled -Root $testRoot -Config $config -PairId 'pair04')
}
catch {
    $blocked = $_.Exception.Message -like '*pair 실행이 비활성화되어 있습니다*'
}
Assert-True $blocked 'Expected Assert-PairActivationEnabled to block disabled pair04.'

Write-Host ('pair-activation contract ok: statePath=' + (Resolve-PairActivationConfig -Root $testRoot -Config $config).StatePath)
