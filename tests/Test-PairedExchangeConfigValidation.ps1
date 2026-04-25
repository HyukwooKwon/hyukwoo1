[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
    }
    catch {
        if ([string]$_.Exception.Message -match $Pattern) {
            return
        }

        throw ($Message + ' actual=' + [string]$_.Exception.Message)
    }

    throw ($Message + ' actual=<no exception>')
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

$tmpRoot = Join-Path $root '_tmp\Test-PairedExchangeConfigValidation'
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$duplicateTargetConfigPath = Join-Path $tmpRoot 'duplicate-target.psd1'
[System.IO.File]::WriteAllText($duplicateTargetConfigPath, @"
@{
    PairTest = @{
        PairDefinitions = @(
            @{ PairId = 'pair10'; TopTargetId = 'target10'; BottomTargetId = 'target20' }
            @{ PairId = 'pair11'; TopTargetId = 'target10'; BottomTargetId = 'target21' }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

Assert-ThrowsLike `
    -Action { Resolve-PairTestConfig -Root $root -ConfigPath $duplicateTargetConfigPath | Out-Null } `
    -Pattern 'assigned to multiple pairs' `
    -Message 'duplicate target assignment should fail fast.'

$invalidSeedTargetConfigPath = Join-Path $tmpRoot 'invalid-seed-target.psd1'
[System.IO.File]::WriteAllText($invalidSeedTargetConfigPath, @"
@{
    PairTest = @{
        PairDefinitions = @(
            @{ PairId = 'pair10'; TopTargetId = 'target10'; BottomTargetId = 'target20' }
        )
        PairPolicies = @{
            pair10 = @{
                DefaultSeedTargetId = 'target99'
            }
        }
    }
}
"@, (New-Utf8NoBomEncoding))

Assert-ThrowsLike `
    -Action { Resolve-PairTestConfig -Root $root -ConfigPath $invalidSeedTargetConfigPath | Out-Null } `
    -Pattern 'DefaultSeedTargetId must match TopTargetId or BottomTargetId' `
    -Message 'pair policy seed target outside the pair should fail fast.'

$negativeRoundtripConfigPath = Join-Path $tmpRoot 'negative-roundtrip.psd1'
[System.IO.File]::WriteAllText($negativeRoundtripConfigPath, @"
@{
    PairTest = @{
        PairDefinitions = @(
            @{ PairId = 'pair10'; TopTargetId = 'target10'; BottomTargetId = 'target20' }
        )
        PairPolicies = @{
            pair10 = @{
                DefaultPairMaxRoundtripCount = -1
            }
        }
    }
}
"@, (New-Utf8NoBomEncoding))

Assert-ThrowsLike `
    -Action { Resolve-PairTestConfig -Root $root -ConfigPath $negativeRoundtripConfigPath | Out-Null } `
    -Pattern 'DefaultPairMaxRoundtripCount must be a non-negative integer' `
    -Message 'negative pair roundtrip limit should fail fast.'

$unknownPolicyPairConfigPath = Join-Path $tmpRoot 'unknown-policy-pair.psd1'
[System.IO.File]::WriteAllText($unknownPolicyPairConfigPath, @"
@{
    PairTest = @{
        PairDefinitions = @(
            @{ PairId = 'pair10'; TopTargetId = 'target10'; BottomTargetId = 'target20' }
        )
        PairPolicies = @{
            pair99 = @{
                DefaultSeedTargetId = 'target99'
            }
        }
    }
}
"@, (New-Utf8NoBomEncoding))

Assert-ThrowsLike `
    -Action { Resolve-PairTestConfig -Root $root -ConfigPath $unknownPolicyPairConfigPath | Out-Null } `
    -Pattern 'PairPolicies\.pair99 has no matching PairDefinitions entry' `
    -Message 'unknown pair policy entry should fail fast.'

Write-Host 'paired exchange config validation ok'
