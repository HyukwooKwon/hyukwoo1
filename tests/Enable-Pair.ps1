[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$PairId,
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
$state = Set-PairActivationEnabled -Root $root -Config $config -PairId $PairId

$result = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    ConfigPath = $resolvedConfigPath
    PairId = $PairId
    PairActivation = $state
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Host ("pair 재활성화 완료: {0}" -f $PairId)
Write-Host ("상태 파일: {0}" -f [string]$state.StatePath)
Write-Host ("상태: {0}" -f [string]$state.State)
