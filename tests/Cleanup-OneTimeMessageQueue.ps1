[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$PairId,
    [ValidateSet('all', 'cancelled', 'expired')][string]$State = 'all',
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

$removedItems = @()
$archivePaths = @()
$retainedItems = New-Object System.Collections.Generic.List[object]

foreach ($item in @($queueState.Document.Items)) {
    $effectiveState = Get-OneTimeQueueItemEffectiveState -Item $item
    $shouldRemove = switch ($State) {
        'all' { $effectiveState -in @('cancelled', 'expired') }
        default { $effectiveState -eq $State }
    }

    if ($shouldRemove) {
        $archiveReason = 'cleanup-' + $effectiveState
        $archivePath = Write-OneTimeQueueArchiveRecord -Root $root -Config $config -Item $item -Reason $archiveReason
        $archivePaths += $archivePath
        $removedItems += [pscustomobject]@{
            Id = [string](Get-ConfigValue -Object $item -Name 'Id' -DefaultValue '')
            State = $effectiveState
            ArchivePath = $archivePath
        }
        continue
    }

    [void]$retainedItems.Add($item)
}

$retainedItemsArray = [object[]]$retainedItems.ToArray()
$queueState.Document.PSObject.Properties.Remove('Items')
$queueState.Document | Add-Member -NotePropertyName Items -NotePropertyValue $retainedItemsArray
Save-OneTimeQueueDocument -Document $queueState.Document -QueuePath $queueState.QueuePath

$result = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    ConfigPath = $resolvedConfigPath
    QueuePath = $queueState.QueuePath
    PairId = $PairId
    RequestedState = $State
    RemovedCount = @($removedItems).Count
    RemovedItems = @($removedItems)
    ArchivePaths = @($archivePaths)
    QueueSummary = (Get-OneTimeQueueSummary -QueueDocument $queueState.Document -QueuePath $queueState.QueuePath)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Host ("1회성 문구 정리 완료: {0}" -f $queueState.QueuePath)
Write-Host ("Pair: {0}" -f $PairId)
Write-Host ("Removed: {0}" -f @($removedItems).Count)
foreach ($removed in @($removedItems)) {
    Write-Host ("- [{0}] {1}" -f [string]$removed.State, [string]$removed.Id)
}
