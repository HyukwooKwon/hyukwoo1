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

Assert-True ($scriptText.Contains("AcceptanceProfile = `$acceptanceProfile")) 'acceptance profile should be resolved once and carried into receipt.'
Assert-True ($scriptText.Contains("Get-ConfigValue -Object `$pairTest -Name 'SmokeSeedTaskText'")) 'smoke profile should source a configured smoke seed task text.'

Write-Host 'run-live-visible-pair-acceptance smoke seed task wiring ok'
