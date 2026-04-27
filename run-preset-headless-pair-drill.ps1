[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PairId,
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$InitialTargetId,
    [int]$MaxForwardCount = 2,
    [int]$RunDurationSec = 900,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

$root = $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$pairDefinition = Get-PairDefinition -PairTest $pairTest -PairId $PairId
if (-not (Test-NonEmptyString $InitialTargetId)) {
    $InitialTargetId = if (Test-NonEmptyString ([string]$pairDefinition.SeedTargetId)) {
        [string]$pairDefinition.SeedTargetId
    }
    else {
        [string]$pairDefinition.TopTargetId
    }
}

$drillRaw = & (Join-Path $root 'run-headless-pair-drill.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $RunRoot `
    -PairId $PairId `
    -InitialTargetId $InitialTargetId `
    -MaxForwardCount $MaxForwardCount `
    -RunDurationSec $RunDurationSec `
    -AsJson
$drill = $drillRaw | ConvertFrom-Json
$resolvedRunRoot = [string]$drill.RunRoot

$renderTargetIds = @()
foreach ($targetId in @([string]$pairDefinition.TopTargetId, [string]$pairDefinition.BottomTargetId)) {
    if ((Test-NonEmptyString $targetId) -and $targetId -notin $renderTargetIds) {
        $renderTargetIds += $targetId
    }
}

$renderedMessages = @()
foreach ($targetId in $renderTargetIds) {
    $renderRaw = & (Join-Path $root 'render-pair-message.ps1') `
        -ConfigPath $resolvedConfigPath `
        -RunRoot $resolvedRunRoot `
        -PairId $PairId `
        -TargetId $targetId `
        -Mode both `
        -WriteOutputs `
        -AsJson
    $renderedMessages += ($renderRaw | ConvertFrom-Json)
}

$payload = [pscustomobject]@{
    SchemaVersion    = '1.0.0'
    GeneratedAt      = (Get-Date).ToString('o')
    ConfigPath       = $resolvedConfigPath
    PairId           = $PairId
    InitialTargetId  = $InitialTargetId
    RunRoot          = $resolvedRunRoot
    Drill            = $drill
    RenderedMessages = @($renderedMessages)
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
    return
}

Write-Host ("{0} preset headless 드릴 완료" -f $PairId)
Write-Host ("Config: {0}" -f $resolvedConfigPath)
Write-Host ("RunRoot: {0}" -f $resolvedRunRoot)
Write-Host ("done 개수: {0}" -f [string]$drill.ObservedCounts.DonePresentCount)
Write-Host ("error 개수: {0}" -f [string]$drill.ObservedCounts.ErrorPresentCount)
Write-Host ("forwarded 개수: {0}" -f [string]$drill.ObservedCounts.ForwardedStateCount)
foreach ($item in @($renderedMessages)) {
    Write-Host ("preview 저장: {0} -> {1}" -f [string]$item.TargetId, [string]$item.OutputRoot)
}
