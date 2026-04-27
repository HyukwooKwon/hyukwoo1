[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RegressionStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Host ("[show-paired-run-summary-regression] {0}" -f $Name)
    & $Action
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

Invoke-RegressionStep -Name 'PowerShell parser check' -Action {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'show-paired-run-summary.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $messages = @($errors | ForEach-Object { '{0}:{1}' -f $_.Extent.StartLineNumber, $_.Message })
        throw ('show-paired-run-summary.ps1 parser check failed: ' + ($messages -join '; '))
    }
}

foreach ($testPath in @(
        'tests\Test-ShowPairedRunSummaryEffectiveAcceptance.ps1',
        'tests\Test-ShowPairedRunSummaryImportantSummary.ps1',
        'tests\Test-ShowPairedRunSummaryInterpretationGuards.ps1',
        'tests\Test-ShowPairedRunSummaryPriorityRegression.ps1'
    )) {
    Invoke-RegressionStep -Name $testPath -Action {
        & (Join-Path $repoRoot $testPath)
    }
}

Invoke-RegressionStep -Name 'panel summary Python unittest' -Action {
    & python -m unittest -v `
        test_relay_panel_refactors.RelayOperatorPanelRuntimeCommandTests.test_run_paired_summary_routes_to_summary_script `
        test_relay_panel_refactors.RelayOperatorPanelRuntimeCommandTests.test_open_important_summary_text_uses_current_run_root `
        test_relay_panel_refactors.RelayOperatorPanelRuntimeCommandTests.test_open_important_summary_text_warns_when_file_missing
    if ($LASTEXITCODE -ne 0) {
        throw ('panel summary Python unittest failed with exit code ' + $LASTEXITCODE)
    }
}

Write-Host 'show-paired-run-summary regression ok'
