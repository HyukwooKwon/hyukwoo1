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

Assert-True ($watchText.Contains('$ForbiddenArtifactLiterals')) 'watcher should define forbidden artifact literals.'
Assert-True ($watchText.Contains('$ForbiddenArtifactRegexes')) 'watcher should define forbidden artifact regexes.'
Assert-True ($watchText.Contains("Reason = 'source-summary-forbidden-literal'")) 'watcher should reject forbidden literals found in summary.txt.'
Assert-True ($watchText.Contains("Reason = 'source-reviewzip-forbidden-literal'")) 'watcher should reject forbidden literals found inside review.zip.'
Assert-True ($watchText.Contains('Get-ForbiddenArtifactTextFileMatch')) 'watcher should inspect summary content with shared forbidden artifact helper.'
Assert-True ($watchText.Contains('Get-ForbiddenArtifactZipMatch')) 'watcher should inspect review zip entries with shared forbidden artifact helper.'
Assert-True ($watchText.Contains('forbidden summary artifact detected')) 'watcher should surface detailed summary artifact contamination messages.'
Assert-True ($watchText.Contains('forbidden review zip artifact detected')) 'watcher should surface detailed review zip artifact contamination messages.'

Write-Host 'watch-paired-exchange forbidden literal rejection wiring ok'
