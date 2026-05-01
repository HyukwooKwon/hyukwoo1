[CmdletBinding()]
param(
    [string]$BaseConfigPath,
    [string[]]$PairId,
    [switch]$BootstrapBindingProfile,
    [switch]$BootstrapRuntimeMap,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')

if (-not (Test-NonEmptyString $BaseConfigPath)) {
    $BaseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}
$resolvedBaseConfigPath = (Resolve-Path -LiteralPath $BaseConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedBaseConfigPath

$selectedPairs = if (@($PairId | Where-Object { Test-NonEmptyString $_ }).Count -gt 0) {
    @(Select-PairDefinitions -PairDefinitions @($pairTest.PairDefinitions) -IncludePairId @($PairId))
}
else {
    @($pairTest.PairDefinitions)
}
if ($selectedPairs.Count -lt 1) {
    throw 'pair-scoped externalized config를 생성할 pair를 찾지 못했습니다.'
}

$writerScriptPath = Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1'
$generated = @()
foreach ($pair in @($selectedPairs)) {
    $pairIdValue = [string]$pair.PairId
    $pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId $pairIdValue
    $pairWorkRepoRoot = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $pairWorkRepoRoot)) {
        throw "pair '$pairIdValue' is missing DefaultSeedWorkRepoRoot."
    }

    $invokeParams = @{
        BaseConfigPath          = $resolvedBaseConfigPath
        WorkRepoRoot            = $pairWorkRepoRoot
        PairId                  = $pairIdValue
        BootstrapBindingProfile = [bool]$BootstrapBindingProfile
        BootstrapRuntimeMap     = [bool]$BootstrapRuntimeMap
        AsJson                  = $true
    }

    $pairReviewInputPath = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedReviewInputPath' -DefaultValue '')
    if (Test-NonEmptyString $pairReviewInputPath) {
        $invokeParams.ReviewInputPath = $pairReviewInputPath
    }

    $result = & pwsh -NoProfile -ExecutionPolicy Bypass -File $writerScriptPath @invokeParams | ConvertFrom-Json
    $generated += [pscustomobject]@{
        PairId           = $pairIdValue
        WorkRepoRoot     = [string]$result.WorkRepoRoot
        OutputConfigPath = [string]$result.OutputConfigPath
        BookkeepingRoot  = [string]$result.BookkeepingRoot
        PairRunRootBase  = [string]$result.PairRunRootBase
        InboxRoot        = [string]$result.InboxRoot
        ProcessedRoot    = [string]$result.ProcessedRoot
        RuntimeRoot      = [string]$result.RuntimeRoot
        LogsRoot         = [string]$result.LogsRoot
        RouterMutexName  = [string]$result.RouterMutexName
    }
}

$payload = [pscustomobject]@{
    GeneratedAt     = (Get-Date).ToString('o')
    BaseConfigPath  = $resolvedBaseConfigPath
    PairIds         = @($generated | ForEach-Object { [string]$_.PairId })
    GeneratedConfigs = @($generated)
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 6
    return
}

$payload
