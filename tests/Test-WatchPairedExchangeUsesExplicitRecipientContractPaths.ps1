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

Assert-True ($watchText.Contains("Get-ConfigValue -Object `$RecipientItem -Name 'SourceOutboxPath'")) 'handoff message should prefer RecipientItem.SourceOutboxPath.'
Assert-True ($watchText.Contains("Get-ConfigValue -Object `$RecipientItem -Name 'SourceSummaryPath'")) 'handoff message should prefer RecipientItem.SourceSummaryPath.'
Assert-True ($watchText.Contains("Get-ConfigValue -Object `$RecipientItem -Name 'SourceReviewZipPath'")) 'handoff message should prefer RecipientItem.SourceReviewZipPath.'
Assert-True ($watchText.Contains("Get-ConfigValue -Object `$RecipientItem -Name 'PublishReadyPath'")) 'handoff message should prefer RecipientItem.PublishReadyPath.'

Write-Host 'watch paired exchange explicit recipient contract paths ok'
