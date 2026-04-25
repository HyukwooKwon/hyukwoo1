[CmdletBinding()]
param(
    [switch]$CompileOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

$compileTargets = @(
    "relay_operator_panel.py",
    "relay_panel_operator_state.py",
    "relay_panel_visible_workflow.py",
    "relay_panel_context_helpers.py",
    "relay_test_temp.py",
    "test_relay_panel_refactors.py",
    "test_relay_panel_context_helpers.py",
    "test_relay_panel_visible_workflow.py",
    "test_relay_panel_operator_state.py"
)

$testTargets = @(
    "test_relay_panel_refactors.py",
    "test_relay_panel_context_helpers.py",
    "test_relay_panel_visible_workflow.py",
    "test_relay_panel_operator_state.py"
)

Write-Host ("[relay-panel] compile: python -m py_compile {0}" -f ($compileTargets -join " "))
& python -m py_compile @compileTargets
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if ($CompileOnly) {
    Write-Host "[relay-panel] compile-only run complete"
    exit 0
}

Write-Host ("[relay-panel] tests: python -m unittest -q {0}" -f ($testTargets -join " "))
& python -m unittest -q @testTargets
exit $LASTEXITCODE
