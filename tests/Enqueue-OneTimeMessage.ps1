[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$PairId,
    [ValidateSet('', 'top', 'bottom')][string]$Role = '',
    [string]$TargetId,
    [ValidateSet('initial', 'handoff', 'both')][string]$AppliesTo = 'both',
    [ValidateSet('one-time-prefix', 'one-time-suffix')][string]$Placement = 'one-time-prefix',
    [Parameter(Mandatory)][string]$Text,
    [int]$Priority = 100,
    [string]$Notes,
    [string]$CreatedBy,
    [string]$ExpiresAt,
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
$item = New-OneTimeQueueItem `
    -PairId $PairId `
    -Role $Role `
    -TargetId $TargetId `
    -AppliesTo $AppliesTo `
    -Placement $Placement `
    -Text $Text `
    -Priority $Priority `
    -Notes $Notes `
    -CreatedBy $CreatedBy `
    -ExpiresAt $ExpiresAt

$items = New-Object System.Collections.ArrayList
foreach ($existing in @($queueState.Document.Items)) {
    [void]$items.Add($existing)
}
[void]$items.Add($item)
$queueState.Document.Items = @($items)
Save-OneTimeQueueDocument -Document $queueState.Document -QueuePath $queueState.QueuePath

$result = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    ConfigPath = $resolvedConfigPath
    QueuePath = $queueState.QueuePath
    Item = $item
    QueueSummary = (Get-OneTimeQueueSummary -QueueDocument $queueState.Document -QueuePath $queueState.QueuePath)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Host ("1회성 문구 등록 완료: {0}" -f [string]$item.Id)
Write-Host ("Queue: {0}" -f [string]$queueState.QueuePath)
Write-Host ("Pair: {0}" -f [string]$PairId)
Write-Host ("Scope: role={0} target={1} applies_to={2}" -f $(if (Test-NonEmptyString $Role) { $Role } else { '(all)' }), $(if (Test-NonEmptyString $TargetId) { $TargetId } else { '(all)' }), $AppliesTo)
