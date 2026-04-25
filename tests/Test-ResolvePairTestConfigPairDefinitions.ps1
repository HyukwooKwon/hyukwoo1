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
Assert-True ($null -ne $pairTest.PairPolicies) 'pair policy map should be populated.'
Assert-True ($pairTest.PairPolicies.ContainsKey('pair01')) 'pair policy map should contain pair01.'

$pair01 = @($pairTest.PairDefinitions | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
Assert-True ($pair01.Count -eq 1) 'pair01 definition should exist.'
Assert-True ([string]$pair01[0].TopTargetId -eq 'target01') 'pair01 top target mismatch.'
Assert-True ([string]$pair01[0].BottomTargetId -eq 'target05') 'pair01 bottom target mismatch.'

Write-Host 'resolve pair test config pair definitions ok'
