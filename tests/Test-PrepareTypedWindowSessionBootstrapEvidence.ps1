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
$testRoot = Join-Path $root '_tmp\test-prepare-typed-window-session-bootstrap-evidence'
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
    SessionPairId = 'pair01'
    SessionTargetId = 'target01'
    SessionEpoch = 7
    LastPrepareAt = (Get-Date).AddMinutes(-1).ToString('o')
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
    -PairId 'pair01' `
    -TargetId 'target01' `
    -AsJson
$result = $resultRaw | ConvertFrom-Json

Assert-True ([string]$result.FinalState -eq 'reused') 'prepare script should reuse an active matching session.'
Assert-True ($result.PSObject.Properties.Name -contains 'VisibleBeaconObserved') 'prepare result should expose VisibleBeaconObserved.'
Assert-True ($result.PSObject.Properties.Name -contains 'FocusStealDetected') 'prepare result should expose FocusStealDetected.'
Assert-True ($result.PSObject.Properties.Name -contains 'VisibleFailureReason') 'prepare result should expose VisibleFailureReason.'
Assert-True ($result.PSObject.Properties.Name -contains 'CompletedAt') 'prepare result should expose CompletedAt.'
Assert-True (-not [bool]$result.VisibleBeaconObserved) 'reused prepare should not claim a visible beacon was observed.'
Assert-True (-not [bool]$result.FocusStealDetected) 'reused prepare should not report focus steal.'
Assert-True ([string]::IsNullOrWhiteSpace([string]$result.VisibleFailureReason)) 'reused prepare should not report a visible failure reason.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$result.CompletedAt)) 'prepare result should stamp CompletedAt.'

Write-Host 'prepare-typed-window-session bootstrap evidence ok'
