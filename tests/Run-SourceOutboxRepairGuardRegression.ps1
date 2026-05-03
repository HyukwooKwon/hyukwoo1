[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RegressionStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Host ("[source-outbox-repair-guard] {0}" -f $Name)
    & $Action
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

Invoke-RegressionStep -Name 'PowerShell parser check' -Action {
    foreach ($path in @(
            'executor\Invoke-CodexExecTurn.ps1',
            'show-paired-run-summary.ps1',
            'tests\Start-PairedExchangeTest.ps1',
            'tests\Watch-PairedExchange.ps1'
        )) {
        $tokens = $null
        $errors = $null
        $fullPath = Join-Path $repoRoot $path
        $null = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            $messages = @($errors | ForEach-Object { '{0}:{1}' -f $_.Extent.StartLineNumber, $_.Message })
            throw ('parser check failed for ' + $path + ': ' + ($messages -join '; '))
        }
    }
}

foreach ($testPath in @(
        'tests\Test-WatchPairedExchangeAutoRepairsManualPublishReady.ps1',
        'tests\Test-WatchPairedExchangeSkipsTargetMismatchMarkerAutoRepair.ps1',
        'tests\Test-InvokeCodexExecTurnAutoRepairsManualSourceOutboxMarker.ps1',
        'tests\Test-InvokeCodexExecTurnSkipsTargetMismatchMarkerAutoRepair.ps1',
        'tests\Test-SourceOutboxPublish.ps1',
        'tests\Test-StartPairedExchangeTestHeadlessDispatchGuard.ps1',
        'tests\Test-WatchPairedExchangeHeadlessDispatchGuard.ps1',
        'tests\Test-StartPairedExchangeInstructionUsesPublishHelper.ps1'
    )) {
    Invoke-RegressionStep -Name $testPath -Action {
        & (Join-Path $repoRoot $testPath)
    }
}

Invoke-RegressionStep -Name 'panel headless/seed Python unittest' -Action {
    & python -m unittest -v `
        test_relay_panel_refactors.RelayOperatorPanelRuntimeCommandTests.test_update_pair_button_states_disables_headless_drill_buttons_for_shared_visible_typed_window_lane `
        test_relay_panel_refactors.RelayOperatorPanelMessageSlotTests.test_preview_seed_kickoff_message_builds_contract_helper_and_full_preview
    if ($LASTEXITCODE -ne 0) {
        throw ('panel Python unittest failed with exit code ' + $LASTEXITCODE)
    }
}

Write-Host 'source-outbox repair guard regression ok'
