[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$PairId,
    [Parameter(Mandatory)][string]$ItemId,
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
$item = Set-OneTimeQueueItemState -QueueDocument $queueState.Document -ItemId $ItemId -State 'cancelled'
Save-OneTimeQueueDocument -Document $queueState.Document -QueuePath $queueState.QueuePath
$archivePath = Write-OneTimeQueueArchiveRecord -Root $root -Config $config -Item $item -Reason 'cancelled'

$result = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    ConfigPath = $resolvedConfigPath
    QueuePath = $queueState.QueuePath
    ArchivePath = $archivePath
    PairId = $PairId
    ItemId = $ItemId
    QueueSummary = (Get-OneTimeQueueSummary -QueueDocument $queueState.Document -QueuePath $queueState.QueuePath)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Host ("1회성 문구 취소 완료: {0}" -f $ItemId)
Write-Host ("Queue: {0}" -f $queueState.QueuePath)
Write-Host ("Archive: {0}" -f $archivePath)
