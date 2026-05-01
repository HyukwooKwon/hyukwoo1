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

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]$Expected -cne [string]$Actual) {
        throw ("{0} expected='{1}' actual='{2}'" -f $Message, $Expected, $Actual)
    }
}

$root = Split-Path -Parent $PSScriptRoot
$fixtureRoot = 'C:\dev\python\_relay-test-fixtures'
$tempRoot = Join-Path $fixtureRoot 'Test-WriteExternalizedRelayConfigPairScoped'
$workRepoRoot = Join-Path $tempRoot 'shared-work-repo'
$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'

if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $workRepoRoot -Force | Out-Null

$pair01 = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath $baseConfigPath `
    -WorkRepoRoot $workRepoRoot `
    -PairId 'pair01' `
    -AsJson | ConvertFrom-Json

$pair02 = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath $baseConfigPath `
    -WorkRepoRoot $workRepoRoot `
    -PairId 'pair02' `
    -AsJson | ConvertFrom-Json

Assert-True (Test-Path -LiteralPath $pair01.OutputConfigPath -PathType Leaf) 'pair01 externalized config should be written.'
Assert-True (Test-Path -LiteralPath $pair02.OutputConfigPath -PathType Leaf) 'pair02 externalized config should be written.'
Assert-True ([string]$pair01.OutputConfigPath -ne [string]$pair02.OutputConfigPath) 'pair-scoped config paths should differ.'
Assert-True ([string]$pair01.BookkeepingRoot -ne [string]$pair02.BookkeepingRoot) 'pair-scoped bookkeeping roots should differ.'
Assert-True ([string]$pair01.PairRunRootBase -ne [string]$pair02.PairRunRootBase) 'pair-scoped run root bases should differ.'
Assert-True ([string]$pair01.RouterMutexName -ne [string]$pair02.RouterMutexName) 'pair-scoped router mutex names should differ.'

$expectedPair01BookkeepingRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\pairs\pair01'
$expectedPair02BookkeepingRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\pairs\pair02'
$expectedPair01RunRootBase = Join-Path $workRepoRoot '.relay-runs\bottest-live-visible\pairs\pair01'
$expectedPair02RunRootBase = Join-Path $workRepoRoot '.relay-runs\bottest-live-visible\pairs\pair02'

Assert-Equal $expectedPair01BookkeepingRoot ([string]$pair01.BookkeepingRoot) 'pair01 bookkeeping root'
Assert-Equal $expectedPair02BookkeepingRoot ([string]$pair02.BookkeepingRoot) 'pair02 bookkeeping root'
Assert-Equal $expectedPair01RunRootBase ([string]$pair01.PairRunRootBase) 'pair01 run root base'
Assert-Equal $expectedPair02RunRootBase ([string]$pair02.PairRunRootBase) 'pair02 run root base'

$pair01Config = Import-PowerShellDataFile -Path ([string]$pair01.OutputConfigPath)
$pair02Config = Import-PowerShellDataFile -Path ([string]$pair02.OutputConfigPath)

Assert-Equal ([string]$pair01.RouterMutexName) ([string]$pair01Config.RouterMutexName) 'pair01 mutex in config'
Assert-Equal ([string]$pair02.RouterMutexName) ([string]$pair02Config.RouterMutexName) 'pair02 mutex in config'
Assert-Equal (Join-Path $expectedPair01BookkeepingRoot 'inbox') ([string]$pair01Config.InboxRoot) 'pair01 inbox root'
Assert-Equal (Join-Path $expectedPair02BookkeepingRoot 'inbox') ([string]$pair02Config.InboxRoot) 'pair02 inbox root'

Write-Host 'write-externalized-relay-config pair scoped ok'
