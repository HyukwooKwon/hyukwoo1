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
$sourcePath = Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1'
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
$closeoutFunction = @(
    $scriptAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-CloseoutStatus'
        }, $true) |
        Select-Object -First 1
)
Assert-True (@($closeoutFunction).Count -eq 1) 'Get-CloseoutStatus function should exist.'

Invoke-Expression $closeoutFunction[0].Extent.Text

$nullStatusPending = Get-CloseoutStatus -Status $null -AcceptanceForwardedStateCount 2 -CloseoutForwardedStateCount 4 -ExpectedDonePresentCount 2
Assert-True (-not [bool]$nullStatusPending.Satisfied) 'Closeout should remain pending when no paired status snapshot is available yet.'
Assert-True ([int]$nullStatusPending.ObservedForwardedStateCount -eq 0) 'Closeout should treat missing paired status as zero forwarded states.'
Assert-True ([string]$nullStatusPending.Status -eq 'pending') 'Closeout should remain pending when paired status is missing.'

$statusMissingDone = [pscustomobject]@{
    Counts = [pscustomobject]@{
        ForwardedStateCount = 4
        DonePresentCount = 1
        ErrorPresentCount = 0
    }
}
$pendingResult = Get-CloseoutStatus -Status $statusMissingDone -AcceptanceForwardedStateCount 2 -CloseoutForwardedStateCount 4 -ExpectedDonePresentCount 2
Assert-True (-not [bool]$pendingResult.Satisfied) 'Closeout should not satisfy when done count is below expected.'
Assert-True ([string]$pendingResult.Status -eq 'pending') 'Closeout should remain pending when done count is below expected.'

$statusSatisfied = [pscustomobject]@{
    Counts = [pscustomobject]@{
        ForwardedStateCount = 4
        DonePresentCount = 2
        ErrorPresentCount = 0
    }
}
$satisfiedResult = Get-CloseoutStatus -Status $statusSatisfied -AcceptanceForwardedStateCount 2 -CloseoutForwardedStateCount 4 -ExpectedDonePresentCount 2
Assert-True ([bool]$satisfiedResult.Satisfied) 'Closeout should satisfy when forwarded, done, and error counts match.'
Assert-True ([int]$satisfiedResult.ExpectedDonePresentCount -eq 2) 'Closeout should expose expected done count in the receipt object.'

Write-Host 'run-live-visible-pair-acceptance closeout requires done count ok'
