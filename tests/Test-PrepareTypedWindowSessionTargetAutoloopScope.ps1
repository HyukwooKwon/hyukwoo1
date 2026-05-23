[CmdletBinding()]
param()

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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-prepare-typed-window-session-target-autoloop-scope'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$runRoot = Join-Path $testRoot 'run'
$runtimeRoot = Join-Path $testRoot 'runtime'
$logsRoot = Join-Path $testRoot 'logs'
$sessionRoot = Join-Path $runtimeRoot 'typed-window-session'
foreach ($path in @($runRoot, $runtimeRoot, $logsRoot, $sessionRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    RuntimeRoot = '$($runtimeRoot.Replace("'", "''"))'
    LogsRoot = '$($logsRoot.Replace("'", "''"))'
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$sessionPath = Join-Path $sessionRoot 'target01.json'
$sessionPayload = [ordered]@{
    SchemaVersion = '1.0.0'
    TargetId = 'target01'
    State = 'active-run'
    SessionRunRoot = (Resolve-Path -LiteralPath $runRoot).Path
    SessionPairId = ''
    SessionScopeKind = 'target-autoloop'
    SessionScopeId = 'target01'
    SessionRouteKey = 'target-autoloop:target01'
    SessionTargetId = 'target01'
    SessionEpoch = 5
    LastPrepareAt = (Get-Date).AddMinutes(-2).ToString('o')
    LastSubmitAt = ''
    LastProgressAt = ''
    LastConfirmedArtifactAt = ''
    LastResetReason = 'reuse-session'
    ConsecutiveSubmitUnconfirmedCount = 0
    UpdatedAt = (Get-Date).ToString('o')
}
$sessionPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionPath -Encoding UTF8

$resultRaw = & (Join-Path $root 'tests\Prepare-TypedWindowSession.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId 'target01' `
    -SessionScopeKind 'target-autoloop' `
    -SessionScopeId 'target01' `
    -SessionRouteKey 'target-autoloop:target01' `
    -AsJson
$result = $resultRaw | ConvertFrom-Json

Assert-True ([string]$result.FinalState -eq 'reused') 'prepare script should reuse an active matching target-autoloop session.'
Assert-True ([string]$result.TypedWindowSessionScopeKind -eq 'target-autoloop') 'prepare result should preserve target-autoloop scope kind.'
Assert-True ([string]$result.TypedWindowSessionScopeId -eq 'target01') 'prepare result should preserve target-autoloop scope id.'
Assert-True ([string]$result.TypedWindowSessionRouteKey -eq 'target-autoloop:target01') 'prepare result should preserve target-autoloop route key.'

Write-Host 'prepare-typed-window-session target-autoloop scope ok'
