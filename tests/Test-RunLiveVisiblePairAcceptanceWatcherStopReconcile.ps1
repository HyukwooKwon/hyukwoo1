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

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

Assert-True ($scriptText.Contains('function Test-WatcherStopSatisfied')) 'acceptance script should define watcher stop reconciliation helper.'
Assert-True ($scriptText.Contains('function New-WatcherReceiptSummary')) 'acceptance script should define watcher receipt stop summary helper.'
Assert-True ($scriptText.Contains('if (Test-WatcherStopSatisfied -Status $status -RequestId $RequestId)')) 'wait loop should use watcher stop reconciliation helper.'
Assert-True ($scriptText.Contains('if (Test-WatcherStopSatisfied -Status $latestWatcherStatus -RequestId $watcherStopRequestId)')) 'final receipt refresh should clear stale watcher stop errors when stop is later observed.'
Assert-True ($scriptText.Contains('StopSatisfied')) 'watcher receipt should expose StopSatisfied.'
Assert-True ($scriptText.Contains('StopObservedAt')) 'watcher receipt should expose StopObservedAt.'
Assert-True ($scriptText.Contains('StopReconciled')) 'watcher receipt should expose StopReconciled.'
Assert-True ($scriptText.Contains('StopErrorSuppressed')) 'watcher receipt should expose StopErrorSuppressed.'

Write-Host 'run-live-visible-pair-acceptance watcher stop reconcile wiring ok'
