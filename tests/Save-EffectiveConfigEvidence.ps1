[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string[]]$PairId,
    [string]$TargetId,
    [ValidateSet('both', 'initial', 'handoff')][string]$Mode = 'both',
    [int]$StaleRunThresholdSec = 1800,
    [switch]$Force,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$jsonPayload = & (Join-Path $root 'tests\Show-EffectiveConfig.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $RunRoot `
    -PairId $PairId `
    -TargetId $TargetId `
    -Mode $Mode `
    -StaleRunThresholdSec $StaleRunThresholdSec `
    -AsJson

$effectiveConfig = $jsonPayload | ConvertFrom-Json
$evidencePolicy = $effectiveConfig.EvidencePolicy
$reasonCodes = @($evidencePolicy.ReasonCodes)

if ((-not [bool]$evidencePolicy.Recommended) -and (-not $Force)) {
    $reasonsText = if ($reasonCodes.Count -gt 0) { $reasonCodes -join ', ' } else { '(none)' }
    throw ("effective config evidence save is not recommended for this state. reasons=" + $reasonsText + ". Use -Force only if you intentionally want an evidence snapshot of a warned state.")
}

$evidenceRoot = [string]$evidencePolicy.EvidenceSnapshotRoot
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null

$laneToken = [string]$effectiveConfig.Config.LaneName
if ([string]::IsNullOrWhiteSpace($laneToken)) {
    $laneToken = 'default'
}

$pairToken = if (@($effectiveConfig.RequestedFilters.PairIds).Count -gt 0) {
    (@($effectiveConfig.RequestedFilters.PairIds) -join '_')
}
else {
    'all'
}

$targetToken = [string]$effectiveConfig.RequestedFilters.TargetId
if ([string]::IsNullOrWhiteSpace($targetToken)) {
    $targetToken = 'alltargets'
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$snapshotPath = Join-Path $evidenceRoot ("effective-config.evidence.{0}.{1}.{2}.{3}.json" -f $laneToken, $pairToken, $targetToken, $timestamp)
$savedAt = (Get-Date).ToString('o')

$snapshotPayload = [ordered]@{
    SnapshotPurpose = 'operations-evidence'
    SnapshotSavedAt = $savedAt
    SnapshotForceUsed = [bool]$Force
    EffectiveConfig = $effectiveConfig
}

$snapshotPayload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $snapshotPath -Encoding UTF8

$result = [pscustomobject]@{
    SnapshotPurpose = 'operations-evidence'
    Path = $snapshotPath
    SavedAt = $savedAt
    Recommended = [bool]$evidencePolicy.Recommended
    ReasonCodes = @($reasonCodes)
    ForceUsed = [bool]$Force
    LaneName = $laneToken
    PairIds = @($effectiveConfig.RequestedFilters.PairIds)
    TargetId = [string]$effectiveConfig.RequestedFilters.TargetId
    SelectedRunRoot = [string]$effectiveConfig.RunContext.SelectedRunRoot
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
    return
}

Write-Host ("saved effective config evidence: {0}" -f $snapshotPath)
Write-Host ("recommended: {0}" -f [bool]$evidencePolicy.Recommended)
Write-Host ("force used: {0}" -f [bool]$Force)
Write-Host ("selected run root: {0}" -f [string]$effectiveConfig.RunContext.SelectedRunRoot)
