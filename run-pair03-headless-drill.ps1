[CmdletBinding()]
param(
    [string]$RunRoot,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$pairId = 'pair03'
$initialTargetId = 'target03'

$drillRaw = & (Join-Path $root 'run-headless-pair-drill.ps1') `
    -ConfigPath $configPath `
    -RunRoot $RunRoot `
    -PairId $pairId `
    -InitialTargetId $initialTargetId `
    -AsJson
$drill = $drillRaw | ConvertFrom-Json
$resolvedRunRoot = [string]$drill.RunRoot

$renderedMessages = @()
foreach ($targetId in @('target03', 'target07')) {
    $renderRaw = & (Join-Path $root 'render-pair-message.ps1') `
        -ConfigPath $configPath `
        -RunRoot $resolvedRunRoot `
        -PairId $pairId `
        -TargetId $targetId `
        -Mode both `
        -WriteOutputs `
        -AsJson
    $renderedMessages += ($renderRaw | ConvertFrom-Json)
}

$payload = [pscustomobject]@{
    SchemaVersion    = '1.0.0'
    GeneratedAt      = (Get-Date).ToString('o')
    ConfigPath       = $configPath
    PairId           = $pairId
    InitialTargetId  = $initialTargetId
    RunRoot          = $resolvedRunRoot
    Drill            = $drill
    RenderedMessages = @($renderedMessages)
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
    return
}

Write-Host ("pair03 전용 headless 드릴 완료")
Write-Host ("Config: {0}" -f $configPath)
Write-Host ("RunRoot: {0}" -f $resolvedRunRoot)
Write-Host ("done 개수: {0}" -f [string]$drill.ObservedCounts.DonePresentCount)
Write-Host ("error 개수: {0}" -f [string]$drill.ObservedCounts.ErrorPresentCount)
Write-Host ("forwarded 개수: {0}" -f [string]$drill.ObservedCounts.ForwardedStateCount)
foreach ($item in @($renderedMessages)) {
    Write-Host ("preview 저장: {0} -> {1}" -f [string]$item.TargetId, [string]$item.OutputRoot)
}
