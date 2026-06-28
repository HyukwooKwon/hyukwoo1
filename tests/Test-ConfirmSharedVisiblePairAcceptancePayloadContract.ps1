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
$sourcePath = Join-Path $root 'tests\Confirm-SharedVisiblePairAcceptance.ps1'
$sourceText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8

Assert-True ($sourceText -match 'ConfirmPassed\s*=\s*\$confirmPassed') 'confirm payload should expose ConfirmPassed canonical flag.'
Assert-True ($sourceText -match 'ReceiptConfirmPassed\s*=\s*\$receiptConfirmPassed') 'confirm payload should expose ReceiptConfirmPassed canonical flag.'
Assert-True ($sourceText -match '\$confirmPassed\s*=\s*\(@\(\$failedRequiredChecks\)\.Count\s*-eq\s*0\)') 'ConfirmPassed should mean all required checks passed in both receipt and non-receipt modes.'
Assert-True ($sourceText -match '\$receiptConfirmPassed\s*=\s*\(\[bool\]\$RequireVisibleReceipt\s*-and\s*\[bool\]\$confirmPassed\)') 'ReceiptConfirmPassed should be receipt-mode success derived from ConfirmPassed.'

Write-Host 'confirm shared visible payload contract ok'
