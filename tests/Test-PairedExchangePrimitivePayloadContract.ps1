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
$requiredFields = @(
    'PrimitiveName',
    'PrimitiveSuccess',
    'PrimitiveAccepted',
    'PrimitiveState',
    'PrimitiveReason',
    'NextPrimitiveAction',
    'SummaryLine',
    'Evidence',
    'PairId',
    'TargetId',
    'PartnerTargetId',
    'RunRoot'
)

foreach ($relativePath in @(
        'tests\Invoke-PairedExchangeOneShotSubmit.ps1',
        'tests\Confirm-PairedExchangePublishPrimitive.ps1',
        'tests\Confirm-PairedExchangeHandoffPrimitive.ps1'
    )) {
    $scriptPath = Join-Path $root $relativePath
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    foreach ($fieldName in $requiredFields) {
        Assert-True ($scriptText.Contains($fieldName + ' = ')) ("primitive payload contract missing field {0} in {1}" -f $fieldName, $relativePath)
    }
}

Write-Host 'paired exchange primitive payload contract ok'
