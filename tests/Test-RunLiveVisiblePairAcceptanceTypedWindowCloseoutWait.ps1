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

Assert-True ($scriptText.Contains('function Wait-ForAcceptanceCloseout')) 'acceptance script should define closeout wait helper.'
Assert-True ($scriptText.Contains('$result.Stage = ''closeout-running''')) 'acceptance script should record closeout-running stage.'
Assert-True ($scriptText.Contains('$result.Stage = ''closeout-completed''')) 'acceptance script should record closeout-completed stage.'
Assert-True ($scriptText.Contains('$result.Stage = ''closeout-failed''')) 'acceptance script should record closeout-failed stage.'
Assert-True ($scriptText.Contains('$closeoutOutcome = Wait-ForAcceptanceCloseout')) 'acceptance script should wait for closeout when requested.'
Assert-True ($scriptText.Contains('WatcherStopped')) 'closeout wait helper should report watcher stopped state.'

Write-Host 'run-live-visible-pair-acceptance typed-window closeout wait wiring ok'
