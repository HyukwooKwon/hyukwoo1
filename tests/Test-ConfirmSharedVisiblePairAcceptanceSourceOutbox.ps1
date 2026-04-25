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
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)

foreach ($functionName in @(
        'Test-SourceOutboxAcceptedRow',
        'Test-SourceOutboxTransitionReadyRow',
        'Get-SourceOutboxCloseoutSummary'
    )) {
    $functionAst = @(
        $scriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) |
            Select-Object -First 1
    )
    Assert-True (@($functionAst).Count -eq 1) ("missing function: " + $functionName)
    Invoke-Expression $functionAst[0].Extent.Text
}

$importedRow = [pscustomobject]@{
    SourceOutboxState = 'imported'
    SourceOutboxNextAction = 'handoff-ready'
    LatestState = 'ready-to-forward'
}
Assert-True (Test-SourceOutboxAcceptedRow -Row $importedRow) 'imported row should count as accepted.'
Assert-True (Test-SourceOutboxTransitionReadyRow -Row $importedRow) 'imported row should count as transition-ready.'

$duplicateForwardedRow = [pscustomobject]@{
    SourceOutboxState = 'duplicate-marker-archived'
    SourceOutboxNextAction = 'duplicate-skipped'
    LatestState = 'forwarded'
}
Assert-True (Test-SourceOutboxAcceptedRow -Row $duplicateForwardedRow) 'duplicate forwarded row should count as accepted.'
Assert-True (Test-SourceOutboxTransitionReadyRow -Row $duplicateForwardedRow) 'duplicate forwarded row should count as transition-ready.'

$waitingRow = [pscustomobject]@{
    SourceOutboxState = 'waiting'
    SourceOutboxNextAction = ''
    LatestState = 'no-zip'
}
Assert-True (-not (Test-SourceOutboxAcceptedRow -Row $waitingRow)) 'waiting row should not count as accepted.'
Assert-True (-not (Test-SourceOutboxTransitionReadyRow -Row $waitingRow)) 'waiting row should not count as transition-ready.'

$summary = Get-SourceOutboxCloseoutSummary -Rows @($importedRow, $duplicateForwardedRow, $waitingRow)
Assert-True ([int]$summary.AcceptedCount -eq 2) 'closeout summary should count two accepted rows.'
Assert-True ([int]$summary.TransitionReadyCount -eq 2) 'closeout summary should count two transition-ready rows.'

Write-Host 'confirm shared visible source-outbox closeout helpers ok'
