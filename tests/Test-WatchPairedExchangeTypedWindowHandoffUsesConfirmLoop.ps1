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
$watchScriptPath = Join-Path $root 'tests\Watch-PairedExchange.ps1'
$watchText = Get-Content -LiteralPath $watchScriptPath -Raw -Encoding UTF8

Assert-True ($watchText.Contains("tests\Send-InitialPairSeedWithRetry.ps1")) 'typed-window handoff branch should use Send-InitialPairSeedWithRetry.ps1.'
Assert-True ($watchText.Contains("tests\Prepare-TypedWindowSession.ps1")) 'typed-window handoff branch should bootstrap/recover the typed-window session before direct submit.'
Assert-True ($watchText.Contains("-MessageTextFilePath `$messagePath")) 'typed-window handoff branch should pass the generated handoff message path into the submit-confirm loop.'
Assert-True ($watchText.Contains("-DisallowInlineTypedWindowPrepare")) 'typed-window handoff branch should block inline typed-window prepare during active orchestration.'
Assert-True ($watchText.Contains("typed-window handoff prepare retry")) 'typed-window handoff branch should retry once after an inline prepare block by running official typed-window prepare.'
Assert-True ($watchText.Contains("typed-window handoff blocked after prepare retry")) 'typed-window handoff branch should fail clearly after prepare retry is exhausted.'
Assert-True ($watchText.Contains("typed-window handoff not confirmed")) 'typed-window handoff branch should hard-fail when publish confirmation is missing.'
Assert-True ($watchText.Contains("Wait-TypedWindowHandoffLateSuccess")) 'typed-window handoff branch should wait for late source-outbox success before hard-failing.'
Assert-True ($watchText.Contains("typed-window handoff late success")) 'typed-window handoff branch should log late publish confirmation when partner artifacts arrive after submit.'

Write-Host 'watch-paired-exchange-typed-window-handoff-uses-confirm-loop ok'
