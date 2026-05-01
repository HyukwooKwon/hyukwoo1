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
$tempRoot = Join-Path $fixtureRoot 'Test-WritePairExternalizedRelayConfigs'
$repoA = Join-Path $tempRoot 'repo-a'
$repoB = Join-Path $tempRoot 'repo-b'
$configPath = Join-Path $tempRoot 'settings.multi-repo.test.psd1'

if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $repoA -Force | Out-Null
New-Item -ItemType Directory -Path $repoB -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $repoA 'reviewfile') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $repoB 'reviewfile') -Force | Out-Null

$configText = @"
@{
    RouterMutexName = 'Global\RelayRouter_Test'
    PairTest = @{
        PairDefinitions = @(
            @{
                PairId = 'pair01'
                TopTargetId = 'target01'
                BottomTargetId = 'target05'
                SeedTargetId = 'target01'
            }
            @{
                PairId = 'pair02'
                TopTargetId = 'target02'
                BottomTargetId = 'target06'
                SeedTargetId = 'target02'
            }
        )
        PairPolicies = @{
            pair01 = @{
                DefaultSeedWorkRepoRoot = '$($repoA.Replace("'", "''"))'
                DefaultSeedReviewInputPath = '$((Join-Path $repoA 'reviewfile\seed_review_input_latest.zip').Replace("'", "''"))'
            }
            pair02 = @{
                DefaultSeedWorkRepoRoot = '$($repoB.Replace("'", "''"))'
                DefaultSeedReviewInputPath = '$((Join-Path $repoB 'reviewfile\seed_review_input_latest.zip').Replace("'", "''"))'
            }
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$result = & (Join-Path $root 'tests\Write-PairExternalizedRelayConfigs.ps1') `
    -BaseConfigPath $configPath `
    -PairId @('pair01', 'pair02') `
    -AsJson | ConvertFrom-Json

Assert-True (@($result.GeneratedConfigs).Count -eq 2) 'should generate two pair-scoped configs.'
$pair01 = @($result.GeneratedConfigs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
$pair02 = @($result.GeneratedConfigs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)
Assert-True (@($pair01).Count -eq 1) 'pair01 generated config missing.'
Assert-True (@($pair02).Count -eq 1) 'pair02 generated config missing.'

Assert-True ([string]$pair01[0].WorkRepoRoot -eq $repoA) 'pair01 should use repo-a.'
Assert-True ([string]$pair02[0].WorkRepoRoot -eq $repoB) 'pair02 should use repo-b.'
Assert-True ([string]$pair01[0].BookkeepingRoot -ne [string]$pair02[0].BookkeepingRoot) 'pair-scoped bookkeeping roots should differ.'
Assert-True (Test-Path -LiteralPath ([string]$pair01[0].OutputConfigPath) -PathType Leaf) 'pair01 config file should exist.'
Assert-True (Test-Path -LiteralPath ([string]$pair02[0].OutputConfigPath) -PathType Leaf) 'pair02 config file should exist.'

Write-Host 'write-pair-externalized-relay-configs ok'
