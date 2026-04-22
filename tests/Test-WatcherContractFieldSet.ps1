[CmdletBinding()]
param(
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$fieldSpecPath = Join-Path $root 'docs\WATCHER-CONTRACT-FIELDS.json'
$fieldSpec = Get-Content -LiteralPath $fieldSpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_watcher_fields_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$status = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ConfigPath $resolvedConfigPath -RunRoot $contractRunRoot -AsJson | ConvertFrom-Json
$watcherPropertyNames = @($status.Watcher.PSObject.Properties.Name)

foreach ($fieldName in @($fieldSpec.WatcherBridgeRequiredFields)) {
    Assert-True ($watcherPropertyNames -contains [string]$fieldName) ("Missing watcher bridge field: " + [string]$fieldName)
}

Write-Host ('watcher contract field set ok: runRoot=' + $contractRunRoot)
