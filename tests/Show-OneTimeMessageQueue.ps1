[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$PairId,
    [ValidateSet('', 'queued', 'previewed', 'consumed', 'cancelled', 'expired')][string]$State = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')
. (Join-Path $PSScriptRoot 'OneTimeMessageQueue.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$queueState = Get-OneTimeQueueDocument -Root $root -Config $config -PairId $PairId
$items = foreach ($item in @($queueState.Document.Items)) {
    $effectiveState = Get-OneTimeQueueItemEffectiveState -Item $item
    if ((Test-NonEmptyString $State) -and ($effectiveState -ne $State)) {
        continue
    }
    [pscustomobject]@{
        Id = [string](Get-ConfigValue -Object $item -Name 'Id' -DefaultValue '')
        Enabled = [bool](Get-ConfigValue -Object $item -Name 'Enabled' -DefaultValue $true)
        State = $effectiveState
        Placement = [string](Get-ConfigValue -Object $item -Name 'Placement' -DefaultValue '')
        Priority = [int](Get-ConfigValue -Object $item -Name 'Priority' -DefaultValue 100)
        Text = [string](Get-ConfigValue -Object $item -Name 'Text' -DefaultValue '')
        ConsumeOnce = [bool](Get-ConfigValue -Object $item -Name 'ConsumeOnce' -DefaultValue $true)
        Scope = (Get-ConfigValue -Object $item -Name 'Scope' -DefaultValue $null)
        CreatedAt = [string](Get-ConfigValue -Object $item -Name 'CreatedAt' -DefaultValue '')
        CreatedBy = [string](Get-ConfigValue -Object $item -Name 'CreatedBy' -DefaultValue '')
        Notes = [string](Get-ConfigValue -Object $item -Name 'Notes' -DefaultValue '')
        ExpiresAt = [string](Get-ConfigValue -Object $item -Name 'ExpiresAt' -DefaultValue '')
    }
}

$result = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    ConfigPath = $resolvedConfigPath
    QueuePath = $queueState.QueuePath
    LaneName = [string](Get-ConfigValue -Object $config -Name 'LaneName' -DefaultValue 'default')
    PairId = $PairId
    RequestedState = $State
    QueueSummary = (Get-OneTimeQueueSummary -QueueDocument $queueState.Document -QueuePath $queueState.QueuePath)
    Items = @($items)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Host ("1회성 문구 큐: {0}" -f [string]$result.QueuePath)
Write-Host ("Pair: {0}" -f [string]$PairId)
Write-Host ("Items: {0}" -f @($result.Items).Count)
foreach ($item in @($result.Items)) {
    Write-Host ("- [{0}] {1} / {2} / {3}" -f [string]$item.State, [string]$item.Id, [string]$item.Placement, [string]$item.Text)
}
