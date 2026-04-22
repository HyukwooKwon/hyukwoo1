[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$PairId,
    [Parameter(Mandatory)][string[]]$ItemId,
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
$result = Complete-OneTimeQueueItems -Root $root -Config $config -PairId $PairId -ItemIds $ItemId

$payload = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    ConfigPath = $resolvedConfigPath
    QueuePath = $result.QueuePath
    PairId = $PairId
    ConsumedCount = $result.ConsumedCount
    ConsumedItems = @($result.ConsumedItems)
    ArchivePaths = @($result.ArchivePaths)
    QueueSummary = $result.QueueSummary
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 10
    return
}

Write-Host ("1회성 문구 consumed 처리 완료: {0}" -f $PairId)
Write-Host ("Queue: {0}" -f $result.QueuePath)
Write-Host ("Consumed: {0}" -f $result.ConsumedCount)
foreach ($item in @($result.ConsumedItems)) {
    Write-Host ("- {0}" -f [string]$item.Id)
}
