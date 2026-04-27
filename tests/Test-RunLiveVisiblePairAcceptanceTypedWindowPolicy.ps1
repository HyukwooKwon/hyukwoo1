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

Assert-True ($scriptText.Contains("RequireUserVisibleCellExecution")) 'acceptance script should read the visible-cell execution requirement.'
Assert-True ($scriptText.Contains("shared real test policy requires typed-window execution in the user-visible cells.")) 'acceptance script should hard fail when shared real-test policy is violated.'
Assert-True ($scriptText.Contains("launcher\Check-TargetWindowVisibility.ps1")) 'typed-window preflight should invoke check-target-window-visibility.'
Assert-True ($scriptText.Contains("typed-window-preflight")) 'typed-window preflight stage should be recorded.'

Write-Host 'run-live-visible-pair-acceptance typed-window policy wiring ok'
