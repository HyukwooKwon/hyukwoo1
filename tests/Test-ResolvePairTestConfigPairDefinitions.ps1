[CmdletBinding()]
param(
    [string]$ConfigPath
)

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

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath

Assert-True ($null -ne $pairTest) 'pair test config should resolve.'
Assert-True (@($pairTest.PairDefinitions).Count -ge 1) 'pair definitions should not be empty.'
Assert-True ([string]$pairTest.PairDefinitionSource -ne '') 'pair definition source should be populated.'
Assert-True ([string]$pairTest.PairDefinitionSourceDetail -eq 'config-pair-definitions') 'pair definition source detail should describe config pair definitions.'
Assert-True ([string]$pairTest.PairTopologyStrategy -eq 'configured') 'pair topology strategy should describe configured pair topology.'
Assert-True ($null -ne $pairTest.PairPolicies) 'pair policy map should be populated.'
Assert-True ($pairTest.PairPolicies.ContainsKey('pair01')) 'pair policy map should contain pair01.'

$pair01 = @($pairTest.PairDefinitions | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
Assert-True ($pair01.Count -eq 1) 'pair01 definition should exist.'
Assert-True ([string]$pair01[0].TopTargetId -eq 'target01') 'pair01 top target mismatch.'
Assert-True ([string]$pair01[0].BottomTargetId -eq 'target05') 'pair01 bottom target mismatch.'
Assert-True ((Get-DefaultPairId -PairTest $pairTest) -eq 'pair01') 'default pair id should resolve from configured pair order.'

$fallbackConfigPath = Join-Path $root '_tmp\resolve-pair-test-config-fallback-targets.psd1'
@"
@{
    Targets = @(
        @{ Id = 'target10'; Folder = 'C:\tmp\target10'; WindowTitle = 'Target10'; EnterCount = 1 }
        @{ Id = 'target11'; Folder = 'C:\tmp\target11'; WindowTitle = 'Target11'; EnterCount = 1 }
        @{ Id = 'target20'; Folder = 'C:\tmp\target20'; WindowTitle = 'Target20'; EnterCount = 1 }
        @{ Id = 'target21'; Folder = 'C:\tmp\target21'; WindowTitle = 'Target21'; EnterCount = 1 }
    )
    PairTest = @{
        RunRootBase = 'C:\tmp\pair-test'
        DefaultPairId = 'pair02'
    }
}
"@ | Set-Content -LiteralPath $fallbackConfigPath -Encoding UTF8

$fallbackPairTest = Resolve-PairTestConfig -Root $root -ConfigPath $fallbackConfigPath
Assert-True ([string]$fallbackPairTest.PairDefinitionSource -eq 'fallback') 'target-order fallback pair definition source should be populated.'
Assert-True ([string]$fallbackPairTest.PairDefinitionSourceDetail -eq 'fallback-target-order') 'target-order fallback pair definition detail should be populated.'
Assert-True ([string]$fallbackPairTest.PairTopologyStrategy -eq 'fallback-target-order') 'target-order fallback pair topology strategy should be populated.'
Assert-True (@($fallbackPairTest.PairDefinitions).Count -eq 2) 'target-order fallback should create two pairs from four targets.'
$fallbackPair01 = @($fallbackPairTest.PairDefinitions | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
$fallbackPair02 = @($fallbackPairTest.PairDefinitions | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)
Assert-True ($fallbackPair01.Count -eq 1) 'fallback pair01 definition should exist.'
Assert-True ($fallbackPair02.Count -eq 1) 'fallback pair02 definition should exist.'
Assert-True ([string]$fallbackPair01[0].TopTargetId -eq 'target10') 'fallback pair01 top target mismatch.'
Assert-True ([string]$fallbackPair01[0].BottomTargetId -eq 'target20') 'fallback pair01 bottom target mismatch.'
Assert-True ([string]$fallbackPair02[0].TopTargetId -eq 'target11') 'fallback pair02 top target mismatch.'
Assert-True ([string]$fallbackPair02[0].BottomTargetId -eq 'target21') 'fallback pair02 bottom target mismatch.'
Assert-True ((Get-DefaultPairId -PairTest $fallbackPairTest) -eq 'pair02') 'default pair id should respect configured target-order fallback default pair id.'

Write-Host 'resolve pair test config pair definitions ok'
