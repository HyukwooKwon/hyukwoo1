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

function Assert-SequenceEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw ($Message + ' count mismatch expected=' + $Expected.Count + ' actual=' + $Actual.Count)
    }

    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$Actual[$index] -ne [string]$Expected[$index]) {
            throw ($Message + ' mismatch at index ' + $index + ' expected=' + $Expected[$index] + ' actual=' + $Actual[$index])
        }
    }
}

function Assert-ContainsAll {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    $actualStrings = @($Actual | ForEach-Object { [string]$_ })
    foreach ($expectedValue in $Expected) {
        if ($actualStrings -notcontains [string]$expectedValue) {
            throw ($Message + ' missing=' + $expectedValue)
        }
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'create-refactor-closeout-review.ps1')

$defaultPaths = @(Get-DefaultCloseoutRelativePaths)
Assert-ContainsAll -Actual $defaultPaths -Expected @(
    'config\settings.bottest-live-visible.psd1',
    'relay_panel_models.py',
    'relay_panel_pair_controller.py',
    'relay_panel_state.py',
    'relay_panel_watchers.py',
    'relay_panel_watcher_controller.py',
    'tests\Confirm-SharedVisiblePairAcceptance.ps1',
    'tests\Import-PairedExchangeArtifact.ps1',
    'launcher\Start-TargetShell.ps1',
    'tests\Manual-E2E-AllTargets.ps1',
    'tests\Manual-E2E-Target01.ps1',
    'tests\PairedExchangeConfig.ps1',
    'tests\Run-LiveVisiblePairAcceptance.ps1',
    'tests\Send-InitialPairSeed.ps1',
    'tests\Send-InitialPairSeedWithRetry.ps1',
    'tests\Show-PairedExchangeStatus.ps1',
    'tests\Test-CleanupVisibleWorkerQueue.ps1',
    'tests\Test-CleanupVisibleWorkerQueueStopsLiveForeignWorker.ps1',
    'tests\Test-ConfirmSharedVisiblePairAcceptanceSourceOutbox.ps1',
    'tests\Test-ImportPairedExchangeArtifact.ps1',
    'tests\Test-ImportPairedExchangeArtifactStaleErrorCleanup.ps1',
    'tests\Test-InvokeCodexExecTurnCodexShimResolution.ps1',
    'tests\Test-InvokeCodexExecTurnTimeoutSourceOutboxPublish.ps1',
    'tests\Test-PairedExchangeConfigVisibleWorkerPreflight.ps1',
    'tests\Test-RunLiveVisiblePairAcceptancePreflightOnly.ps1',
    'tests\Test-RunLiveVisiblePairAcceptancePreflightOnlyDirtyLane.ps1',
    'tests\Test-ShowPairedExchangeStatusPairSummary.ps1',
    'tests\Test-SourceOutboxArtifactValidation.ps1',
    'tests\Test-StartTargetShellVisibleWorkerBootstrap.ps1',
    'tests\Test-VisibleWorkerCommandExecutionSucceeded.ps1',
    'tests\Test-WatcherForwardsLatestZipOnly.ps1',
    'tests\Watch-PairedExchange.ps1',
    'visible\Cleanup-VisibleWorkerQueue.ps1',
    'visible\Queue-VisibleWorkerCommand.ps1',
    'visible\Start-VisibleTargetWorker.ps1'
) -Message 'Default closeout path list should cover the visible-worker/preflight refactor surface.'

$baselineSpecs = @(Get-DefaultCloseoutCommandSpecs -RepoRoot $root)
$baselineLabels = @($baselineSpecs | ForEach-Object { [string]$_.Label })
Assert-True ($baselineLabels -contains 'closeout_receipt_contract') 'Baseline closeout command set should include the receipt contract test.'
Assert-True ($baselineLabels -contains 'pytest_refactors') 'Baseline closeout command set should include the panel refactor pytest suite.'
Assert-True ($baselineLabels -contains 'smoke_temp_root') 'Baseline closeout command set should include the smoke test.'
$pyCompileSpec = @($baselineSpecs | Where-Object { [string]$_.Label -eq 'py_compile' } | Select-Object -First 1)[0]
Assert-True ($null -ne $pyCompileSpec) 'Baseline closeout command set should include the py_compile command.'
Assert-ContainsAll -Actual @($pyCompileSpec.ArgumentList) -Expected @(
    'relay_panel_models.py',
    'relay_panel_pair_controller.py',
    'relay_panel_state.py',
    'relay_panel_watchers.py',
    'relay_panel_watcher_controller.py'
) -Message 'py_compile command should cover the full refactor Python surface.'
Assert-ContainsAll -Actual $baselineLabels -Expected @(
    'exec_codex_shim_resolution',
    'exec_timeout_source_outbox_publish',
    'visible_cleanup_queue',
    'visible_cleanup_queue_foreign_worker',
    'visible_worker_command_execution_succeeded',
    'source_outbox_artifact_validation',
    'import_paired_exchange_artifact',
    'import_paired_exchange_artifact_stale_cleanup',
    'pair_visible_preflight_config',
    'pair_live_visible_preflight',
    'pair_live_visible_preflight_dirty_lane',
    'confirm_shared_visible_pair_acceptance_source_outbox',
    'show_paired_exchange_status_pair_summary',
    'visible_worker_bootstrap',
    'watcher_latest_zip_only'
) -Message 'Baseline closeout command set should cover the visible-worker/preflight regression suites.'
Assert-True (-not ($baselineLabels -contains 'pair_transport_acceptance')) 'Acceptance command must stay opt-in.'

$acceptanceSpecs = @(Get-DefaultCloseoutCommandSpecs -RepoRoot $root -IncludePairTransportAcceptance)
$acceptanceLabels = @($acceptanceSpecs | ForEach-Object { [string]$_.Label })
Assert-True ($acceptanceLabels -contains 'pair_transport_acceptance') 'Acceptance profile should append the pair transport acceptance command.'

$receipt = New-ReviewReceiptObject `
    -RepoRoot 'C:\repo' `
    -ReviewZipName '20260101010101.zip' `
    -ReceiptFileName '20260101010101.receipt.json' `
    -Profile 'baseline' `
    -CommandResults @(
        [pscustomobject]@{
            label       = 'pytest_refactors'
            command     = 'pytest -q test_relay_panel_refactors.py'
            passed      = $true
            exit_code   = 0
            duration_ms = 16123
            summary     = '160 passed in 16.52s'
            output_tail = @('160 passed in 16.52s')
            error       = $null
        },
        [pscustomobject]@{
            label       = 'smoke_temp_root'
            command     = 'powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Smoke-Test.ps1 -UseTempRoot'
            passed      = $false
            exit_code   = 1
            duration_ms = 450
            summary     = 'smoke failed'
            output_tail = @('line a', 'smoke failed')
            error       = 'smoke failed'
        }
    )

Assert-ReviewReceiptContract -Receipt $receipt
Assert-True ([int]$receipt.suite_pass_count -eq 1) 'Receipt pass count should match the passing commands.'
Assert-True ([int]$receipt.suite_fail_count -eq 1) 'Receipt fail count should match the failing commands.'
Assert-True ([string]$receipt.commands[0].summary -eq '160 passed in 16.52s') 'Receipt should preserve per-command summary output.'

$invalidReceiptDetected = $false
try {
    Assert-ReviewReceiptContract -Receipt ([pscustomobject]@{
            generated_at     = '2026-01-01T01:01:01+09:00'
            repo_root        = 'C:\repo'
            review_zip       = 'x.zip'
            receipt_file     = 'x.receipt.json'
            profile          = 'baseline'
            suite_pass_count = 0
            suite_fail_count = 0
            commands         = @(
                [pscustomobject]@{
                    label       = 'broken'
                    command     = 'cmd'
                    passed      = $true
                    exit_code   = 0
                    duration_ms = 0
                    output_tail = @()
                    error       = $null
                }
            )
        })
}
catch {
    $invalidReceiptDetected = $true
}
Assert-True $invalidReceiptDetected 'Receipt contract validator should reject command objects missing summary.'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('closeout-review-contract-' + [guid]::NewGuid().ToString('N'))
$externalRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('closeout-review-contract-external-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
New-Item -ItemType Directory -Path $externalRoot -Force | Out-Null
try {
    [System.IO.File]::WriteAllText((Join-Path $tempRoot 'alpha.txt'), 'alpha')
    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'nested') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tempRoot 'nested\beta.txt'), 'beta')
    $externalReceiptPath = Join-Path $externalRoot 'receipt.json'
    [System.IO.File]::WriteAllText($externalReceiptPath, '{"ok":true}')
    $zipPath = Join-Path $tempRoot 'bundle.zip'
    $stageRoot = Join-Path $tempRoot '.stage'
    New-ReviewZipArchive `
        -RepoRoot $tempRoot `
        -ZipPath $zipPath `
        -RelativePaths @('alpha.txt', 'nested\beta.txt') `
        -ExternalFiles @{ 'nested-output\receipt.json' = $externalReceiptPath } `
        -StageRoot $stageRoot

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = @(
            $archive.Entries |
                Select-Object -ExpandProperty FullName |
                ForEach-Object { ([string]$_).Replace('\', '/').TrimStart('/') } |
                Sort-Object
        )
    }
    finally {
        $archive.Dispose()
    }

    $expectedEntries = @('alpha.txt', 'nested-output/receipt.json', 'nested/beta.txt')
    Assert-True ($entries.Count -eq $expectedEntries.Count) 'Closeout zip helper should preserve the expected archive entry count.'
    Assert-ContainsAll -Actual $entries -Expected $expectedEntries -Message 'Closeout zip helper should preserve repo-relative and external paths in the archive.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $externalRoot) {
        Remove-Item -LiteralPath $externalRoot -Recurse -Force
    }
}

Write-Host 'create refactor closeout review contract ok'
