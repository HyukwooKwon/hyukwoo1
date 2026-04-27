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
$scriptPath = Join-Path $root 'tests\Watch-PairedExchange.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

Assert-True ($scriptText.Contains('$requestReferenceTicks = 0L')) 'watcher should derive a request reference timestamp for source-outbox readiness.'
Assert-True ($scriptText.Contains("Reason = 'source-summary-before-request'")) 'watcher should reject stale source summary files older than request creation.'
Assert-True ($scriptText.Contains("Reason = 'source-reviewzip-before-request'")) 'watcher should reject stale source review zips older than request creation.'
Assert-True ($scriptText.Contains("Reason = 'marker-before-request'")) 'watcher should reject stale publish markers older than request creation.'

Write-Host 'watch-paired-exchange stale source-outbox gating wiring ok'
