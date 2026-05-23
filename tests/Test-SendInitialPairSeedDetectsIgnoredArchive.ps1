[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

Assert-True ($scriptText.Contains('[AllowEmptyString()][string]$IgnoredRoot')) 'message transition wait should accept an ignored archive root.'
Assert-True ($scriptText.Contains("Find-ArchivedMessage -Root `$IgnoredRoot -BaseName `$BaseName")) 'message transition wait should search ignored archives by ready basename.'
Assert-True ($scriptText.Contains("State = 'ignored'")) 'ignored archive transition should be returned as an explicit ignored state.'
Assert-True ($scriptText.Contains("'launcher-session-mismatch'") -or $scriptText.Contains('$ignoredReason')) 'ignored archive reason should flow through the seed status path.'
Assert-True ($scriptText.Contains("-IgnoredPath `$ignoredPath")) 'final seed status should persist the ignored ready archive path.'
Assert-True ($scriptText.Contains("elseif (`$finalState -eq 'ignored')")) 'ignored final state should map to a non-timeout submit failure.'

Write-Host 'send-initial-pair-seed ignored archive detection wiring ok'
