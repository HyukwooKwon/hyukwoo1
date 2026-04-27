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
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

$tmpRoot = Join-Path $root '_tmp\Test-PairedExchangeConfigPairPolicies'
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$configPath = Join-Path $tmpRoot 'settings.pair-policies.psd1'
$configText = @"
@{
    PairTest = @{
        PairDefinitions = @(
            @{
                PairId = 'pair10'
                TopTargetId = 'target10'
                BottomTargetId = 'target20'
                SeedTargetId = 'target20'
            }
        )
        DefaultPairId = 'pair10'
        DefaultSeedWorkRepoRoot = 'defaults\repo'
        DefaultSeedReviewInputSearchRelativePath = 'review-in'
        DefaultSeedReviewInputFilter = '*.review.zip'
        UseExternalWorkRepoContractPaths = `$true
        ExternalWorkRepoContractRelativeRoot = '.relay-contract\default-contract'
        DefaultWatcherRunDurationSec = 1800
        DefaultPairMaxRoundtripCount = 8
        PairPolicies = @{
            pair10 = @{
                DefaultSeedWorkRepoRoot = 'custom\pair10-repo'
                UseExternalWorkRepoContractPaths = `$false
                ExternalWorkRepoContractRelativeRoot = '.relay-contract\pair10-contract'
                DefaultWatcherRunDurationSec = 2400
                DefaultPairMaxRoundtripCount = 12
                PublishContractMode = 'relaxed'
                RecoveryPolicy = 'resume-queue'
                PauseAllowed = `$false
            }
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $configPath
$pair = @(Select-PairDefinitions -PairDefinitions @($pairTest.PairDefinitions) -IncludePairId @('pair10') | Select-Object -First 1)[0]
$policy = Get-PairPolicyForPair -PairTest $pairTest -PairId 'pair10'

Assert-True ([string]$pairTest.PairDefinitionSource -eq 'config') 'pair definitions should come from config.'
Assert-True ([string]$pairTest.PairDefinitionSourceDetail -eq 'config-pair-definitions') 'pair definition source detail should describe config pair definitions.'
Assert-True ([string]$pairTest.PairTopologyStrategy -eq 'configured') 'pair topology strategy should describe configured pair topology.'
Assert-True ([string]$pairTest.DefaultPairId -eq 'pair10') 'default pair id should be preserved.'
Assert-True ((Get-DefaultPairId -PairTest $pairTest) -eq 'pair10') 'default pair helper should respect configured default pair id.'
Assert-True ([string]$pair.PairId -eq 'pair10') 'pair10 definition should be selectable from config.'
Assert-True ([string]$pair.SeedTargetId -eq 'target20') 'pair definition should preserve explicit seed target.'
Assert-True ([string]$policy.DefaultSeedTargetId -eq 'target20') 'pair policy should inherit explicit seed target from pair definition.'
Assert-True ([string]$policy.DefaultSeedWorkRepoRoot -eq (Join-Path $root 'custom\pair10-repo')) 'pair policy should resolve relative work repo root against repo root.'
Assert-True (-not [bool]$policy.UseExternalWorkRepoContractPaths) 'pair policy should preserve external contract path override.'
Assert-True ([string]$policy.ExternalWorkRepoContractRelativeRoot -eq '.relay-contract\pair10-contract') 'pair policy should preserve external contract relative root override.'
Assert-True ([int]$policy.DefaultWatcherRunDurationSec -eq 2400) 'pair policy should preserve pair watcher run duration override.'
Assert-True ([int]$policy.DefaultPairMaxRoundtripCount -eq 12) 'pair policy should preserve pair roundtrip override.'
Assert-True ([string]$policy.PublishContractMode -eq 'relaxed') 'pair policy should preserve publish contract mode.'
Assert-True ([string]$policy.RecoveryPolicy -eq 'resume-queue') 'pair policy should preserve recovery policy.'
Assert-True (-not [bool]$policy.PauseAllowed) 'pair policy should preserve pause permission override.'

Write-Host 'paired exchange config pair policies ok'
