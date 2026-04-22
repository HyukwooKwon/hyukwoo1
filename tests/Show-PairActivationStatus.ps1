[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$PairId,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')
. (Join-Path $PSScriptRoot 'PairActivation.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$requestedPairIds = @($PairId | Where-Object { Test-NonEmptyString $_ })
$summary = @(Get-PairActivationSummary -Root $root -Config $config -PairIds $requestedPairIds)

$enabledCount = @($summary | Where-Object { [bool]$_.EffectiveEnabled -and [string]$_.State -eq 'enabled' }).Count
$disabledCount = @($summary | Where-Object { -not [bool]$_.EffectiveEnabled }).Count
$expiredAutoEnabledCount = @($summary | Where-Object { [string]$_.State -eq 'expired-auto-enabled' }).Count
$statePath = ''
$laneName = ''
$defaultEnabled = $true

if ($summary.Count -gt 0) {
    $statePath = [string]$summary[0].StatePath
    $laneName = [string]$summary[0].LaneName
    $defaultEnabled = [bool]$summary[0].DefaultEnabled
}
else {
    $resolvedActivation = Resolve-PairActivationConfig -Root $root -Config $config
    $statePath = [string]$resolvedActivation.StatePath
    $laneName = [string]$resolvedActivation.LaneName
    $defaultEnabled = [bool]$resolvedActivation.DefaultEnabled
}

$result = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = (Get-Date).ToString('o')
    ConfigPath = $resolvedConfigPath
    LaneName = $laneName
    StatePath = $statePath
    DefaultEnabled = $defaultEnabled
    RequestedPairIds = @($requestedPairIds)
    Summary = [pscustomobject]@{
        PairCount = $summary.Count
        EnabledCount = $enabledCount
        DisabledCount = $disabledCount
        ExpiredAutoEnabledCount = $expiredAutoEnabledCount
    }
    Pairs = @($summary)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Host 'Pair Activation Status'
Write-Host ('Config: ' + $result.ConfigPath)
Write-Host ('Lane: ' + $result.LaneName)
Write-Host ('StatePath: ' + $result.StatePath)
Write-Host ('DefaultEnabled: ' + $result.DefaultEnabled)
Write-Host ('Summary: enabled={0} disabled={1} expired-auto-enabled={2}' -f $enabledCount, $disabledCount, $expiredAutoEnabledCount)

foreach ($item in @($summary | Sort-Object PairId)) {
    $reasonPart = if (Test-NonEmptyString ([string]$item.DisableReason)) { (' / reason=' + [string]$item.DisableReason) } else { '' }
    $untilPart = if (Test-NonEmptyString ([string]$item.DisabledUntil)) { (' / until=' + [string]$item.DisabledUntil) } else { '' }
    Write-Host ('- {0}: {1} / effective={2}{3}{4}' -f [string]$item.PairId, [string]$item.State, [bool]$item.EffectiveEnabled, $reasonPart, $untilPart)
}
