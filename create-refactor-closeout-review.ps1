[CmdletBinding()]
param(
    [string]$Stamp,
    [string]$OutputRoot = 'reviewfile',
    [switch]$IncludePairTransportAcceptance,
    [string[]]$AdditionalRelativePaths = @(),
    [switch]$IncludeGitModifiedPaths,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CloseoutContaminationScannedExtensions = @('.json', '.md', '.txt')
# Exclude source/config scripts because forbidden-artifact policy literals live in code/settings.
$script:CloseoutContaminationExcludedExtensions = @('.ahk', '.cmd', '.ini', '.ps1', '.psd1', '.psm1', '.py', '.vbs')

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }

        if ($command.Source) {
            return [string]$command.Source
        }

        if ($command.Path) {
            return [string]$command.Path
        }

        return [string]$name
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Format-CommandPart {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match '[\s"]') {
        return ('"' + $Value.Replace('"', '\"') + '"')
    }

    return $Value
}

function Join-DisplayCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList
    )

    $parts = @([System.IO.Path]::GetFileName($FilePath))
    foreach ($argument in $ArgumentList) {
        $parts += (Format-CommandPart -Value $argument)
    }

    return ($parts -join ' ')
}

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-DefaultCloseoutRelativePaths {
    return @(
        'config\settings.bottest-live-visible.psd1',
        'create-refactor-closeout-review.ps1',
        'test-create-refactor-closeout-review.ps1',
        'pytest.ini',
        'relay_operator_panel.py',
        'relay_panel_models.py',
        'relay_panel_pair_controller.py',
        'relay_panel_state.py',
        'relay_panel_watchers.py',
        'relay_panel_watcher_controller.py',
        'relay_panel_artifact_workflow.py',
        'relay_panel_runtime_workflow.py',
        'relay_panel_watcher_workflow.py',
        'test_relay_panel_context_helpers.py',
        'test_relay_panel_operator_state.py',
        'test_relay_panel_refactors.py',
        'test_relay_panel_visible_workflow.py',
        'docs\REFACTOR-STABILITY-CONTRACTS.md',
        'launcher\Attach-Targets.ps1',
        'launcher\Attach-TargetsFromBindings.ps1',
        'launcher\Check-TargetWindowVisibility.ps1',
        'launcher\Refresh-BindingProfileFromExisting.ps1',
        'launcher\Start-TargetShell.ps1',
        'launcher\Start-Targets.ps1',
        'launcher\WindowDiscovery.ps1',
        'executor\Invoke-CodexExecTurn.ps1',
        'router\Start-Router.ps1',
        'tests\Confirm-SharedVisiblePairAcceptance.ps1',
        'tests\Import-PairedExchangeArtifact.ps1',
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
        'tests\Test-CreateRefactorCloseoutReview.ps1',
        'tests\Test-ImportPairedExchangeArtifact.ps1',
        'tests\Test-ImportPairedExchangeArtifactStaleErrorCleanup.ps1',
        'tests\Test-InvokeCodexExecTurnCodexShimResolution.ps1',
        'tests\Test-InvokeCodexExecTurnTimeoutSourceOutboxPublish.ps1',
        'tests\Test-LauncherWindowDiscoveryContract.ps1',
        'tests\Test-PairedExchangeConfigVisibleWorkerPreflight.ps1',
        'tests\Test-RunLiveVisiblePairAcceptancePreflightOnly.ps1',
        'tests\Test-RunLiveVisiblePairAcceptancePreflightOnlyDirtyLane.ps1',
        'tests\Test-ShowPairedExchangeStatusPairSummary.ps1',
        'tests\Test-SourceOutboxArtifactValidation.ps1',
        'tests\Test-StartTargetShellVisibleWorkerBootstrap.ps1',
        'tests\Test-VisibleWorkerCommandExecutionSucceeded.ps1',
        'tests\Test-WatcherForwardsLatestZipOnly.ps1',
        'tests\Test-InvokeCodexExecTurnDryRun.ps1',
        'tests\Test-InvokeCodexExecTurnContractPaths.ps1',
        'tests\Test-InvokeCodexExecTurnProcessInvocation.ps1',
        'tests\Test-RouterProcessValidPairTransport.ps1',
        'tests\Test-RouterIgnorePreexistingReadyFiles.ps1',
        'tests\Test-RouterUserActiveHold.ps1',
        'tests\Test-RouterRequirePairTransportMetadata.ps1',
        'tests\Test-RouterIgnoreLauncherSessionMismatch.ps1',
        'tests\Smoke-Test.ps1',
        'tests\Watch-PairedExchange.ps1',
        'visible\Cleanup-VisibleWorkerQueue.ps1',
        'visible\Queue-VisibleWorkerCommand.ps1',
        'visible\Start-VisibleTargetWorker.ps1'
    )
}

function New-CommandSpec {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList
    )

    return [pscustomobject]@{
        Label        = $Label
        FilePath     = $FilePath
        ArgumentList = @($ArgumentList)
        Display      = (Join-DisplayCommand -FilePath $FilePath -ArgumentList $ArgumentList)
    }
}

function Get-DefaultCloseoutCommandSpecs {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$IncludePairTransportAcceptance
    )

    $powershellPath = Resolve-PowerShellExecutable
    $specs = [System.Collections.Generic.List[object]]::new()

    $specs.Add((New-CommandSpec -Label 'py_compile' -FilePath 'python' -ArgumentList @(
                '-m', 'py_compile',
                'relay_operator_panel.py',
                'relay_panel_message_config.py',
                'relay_panel_models.py',
                'relay_panel_pair_controller.py',
                'relay_panel_state.py',
                'relay_panel_watchers.py',
                'relay_panel_watcher_controller.py',
                'relay_panel_artifact_workflow.py',
                'relay_panel_runtime_workflow.py',
                'relay_panel_watcher_workflow.py',
                'test_relay_panel_refactors.py'
            ))) | Out-Null

    $specs.Add((New-CommandSpec -Label 'closeout_receipt_contract' -FilePath $powershellPath -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Join-Path $RepoRoot 'tests\Test-CreateRefactorCloseoutReview.ps1')
            ))) | Out-Null

    $specs.Add((New-CommandSpec -Label 'pytest_refactors' -FilePath 'pytest' -ArgumentList @(
                '-q',
                'test_relay_panel_context_helpers.py',
                'test_relay_panel_operator_state.py',
                'test_relay_panel_refactors.py',
                'test_relay_panel_visible_workflow.py'
            ))) | Out-Null

    $specs.Add((New-CommandSpec -Label 'pytest_repo_boundary' -FilePath 'pytest' -ArgumentList @(
                '-q'
            ))) | Out-Null

    foreach ($entry in @(
            @{ Label = 'launcher_contract'; Script = 'tests\Test-LauncherWindowDiscoveryContract.ps1' },
            @{ Label = 'exec_dry_run'; Script = 'tests\Test-InvokeCodexExecTurnDryRun.ps1' },
            @{ Label = 'exec_contract_paths'; Script = 'tests\Test-InvokeCodexExecTurnContractPaths.ps1' },
            @{ Label = 'exec_codex_shim_resolution'; Script = 'tests\Test-InvokeCodexExecTurnCodexShimResolution.ps1' },
            @{ Label = 'exec_process_invocation'; Script = 'tests\Test-InvokeCodexExecTurnProcessInvocation.ps1' },
            @{ Label = 'exec_timeout_source_outbox_publish'; Script = 'tests\Test-InvokeCodexExecTurnTimeoutSourceOutboxPublish.ps1' },
            @{ Label = 'visible_cleanup_queue'; Script = 'tests\Test-CleanupVisibleWorkerQueue.ps1' },
            @{ Label = 'visible_cleanup_queue_foreign_worker'; Script = 'tests\Test-CleanupVisibleWorkerQueueStopsLiveForeignWorker.ps1' },
            @{ Label = 'visible_worker_command_execution_succeeded'; Script = 'tests\Test-VisibleWorkerCommandExecutionSucceeded.ps1' },
            @{ Label = 'source_outbox_artifact_validation'; Script = 'tests\Test-SourceOutboxArtifactValidation.ps1' },
            @{ Label = 'import_paired_exchange_artifact'; Script = 'tests\Test-ImportPairedExchangeArtifact.ps1' },
            @{ Label = 'import_paired_exchange_artifact_stale_cleanup'; Script = 'tests\Test-ImportPairedExchangeArtifactStaleErrorCleanup.ps1' },
            @{ Label = 'pair_visible_preflight_config'; Script = 'tests\Test-PairedExchangeConfigVisibleWorkerPreflight.ps1' },
            @{ Label = 'pair_live_visible_preflight'; Script = 'tests\Test-RunLiveVisiblePairAcceptancePreflightOnly.ps1' },
            @{ Label = 'pair_live_visible_preflight_dirty_lane'; Script = 'tests\Test-RunLiveVisiblePairAcceptancePreflightOnlyDirtyLane.ps1' },
            @{ Label = 'confirm_shared_visible_pair_acceptance_source_outbox'; Script = 'tests\Test-ConfirmSharedVisiblePairAcceptanceSourceOutbox.ps1' },
            @{ Label = 'show_paired_exchange_status_pair_summary'; Script = 'tests\Test-ShowPairedExchangeStatusPairSummary.ps1' },
            @{ Label = 'visible_worker_bootstrap'; Script = 'tests\Test-StartTargetShellVisibleWorkerBootstrap.ps1' },
            @{ Label = 'watcher_latest_zip_only'; Script = 'tests\Test-WatcherForwardsLatestZipOnly.ps1' },
            @{ Label = 'router_valid_pair'; Script = 'tests\Test-RouterProcessValidPairTransport.ps1' },
            @{ Label = 'router_ignore_preexisting'; Script = 'tests\Test-RouterIgnorePreexistingReadyFiles.ps1' },
            @{ Label = 'router_user_active_hold'; Script = 'tests\Test-RouterUserActiveHold.ps1' },
            @{ Label = 'router_require_metadata'; Script = 'tests\Test-RouterRequirePairTransportMetadata.ps1' },
            @{ Label = 'router_ignore_session_mismatch'; Script = 'tests\Test-RouterIgnoreLauncherSessionMismatch.ps1' },
            @{ Label = 'smoke_temp_root'; Script = 'tests\Smoke-Test.ps1'; Extra = @('-UseTempRoot') }
        )) {
        $argumentList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $RepoRoot $entry.Script)
        )
        if ($entry.ContainsKey('Extra')) {
            $argumentList += @($entry.Extra)
        }
        $specs.Add((New-CommandSpec -Label $entry.Label -FilePath $powershellPath -ArgumentList $argumentList)) | Out-Null
    }

    if ($IncludePairTransportAcceptance) {
        $specs.Add((New-CommandSpec -Label 'pair_transport_acceptance' -FilePath $powershellPath -ArgumentList @(
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-File', (Join-Path $RepoRoot 'tests\Run-PairTransportClosureAcceptance.ps1'),
                    '-AsJson'
                ))) | Out-Null
    }

    return @($specs)
}

function Get-OutputSummary {
    param([AllowEmptyCollection()][string[]]$Lines)

    $nonEmpty = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($nonEmpty.Count -eq 0) {
        return ''
    }

    return [string]$nonEmpty[-1]
}

function Get-OutputTail {
    param(
        [AllowEmptyCollection()][string[]]$Lines,
        [int]$MaxLines = 8
    )

    $nonEmpty = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($nonEmpty.Count -le $MaxLines) {
        return @($nonEmpty)
    }

    return @($nonEmpty[($nonEmpty.Count - $MaxLines)..($nonEmpty.Count - 1)])
}

function Invoke-ExternalCommandCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Native stderr can be part of a passing contract test.
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    return [pscustomobject]@{
        ExitCode   = [int]$exitCode
        OutputLines = @($output | ForEach-Object { [string]$_ })
    }
}

function Invoke-CloseoutCommandSpec {
    param([Parameter(Mandatory)]$Spec)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $capture = Invoke-ExternalCommandCapture -FilePath $Spec.FilePath -ArgumentList $Spec.ArgumentList
    $sw.Stop()

    $passed = ($capture.ExitCode -eq 0)
    $summary = Get-OutputSummary -Lines $capture.OutputLines
    $outputTail = Get-OutputTail -Lines $capture.OutputLines
    $errorText = if ($passed) { $null } else { $summary }

    return [pscustomobject]@{
        label       = [string]$Spec.Label
        command     = [string]$Spec.Display
        passed      = [bool]$passed
        exit_code   = [int]$capture.ExitCode
        duration_ms = [int]$sw.ElapsedMilliseconds
        summary     = [string]$summary
        output_tail = @($outputTail)
        error       = $errorText
    }
}

function New-ReviewReceiptObject {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ReviewZipName,
        [Parameter(Mandatory)][string]$ReceiptFileName,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CommandResults,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$PackagingMode,
        [Parameter(Mandatory)][string]$CoverageGuarantee,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FailureReason,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FailureDetail,
        [Parameter(Mandatory)][bool]$ZipCreated,
        [Parameter(Mandatory)][bool]$ContaminationGuardEnabled,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ContaminationScannedExtensions,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ContaminationExcludedExtensions,
        [Parameter(Mandatory)][string]$ForbiddenPolicySource,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ForbiddenArtifactHits,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$IncludedFiles,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MissingExpectedFiles
    )

    $passCount = @($CommandResults | Where-Object { [bool]$_.passed }).Count
    $failCount = @($CommandResults | Where-Object { -not [bool]$_.passed }).Count

    return [pscustomobject][ordered]@{
        generated_at     = (Get-Date).ToString('o')
        repo_root        = $RepoRoot
        review_zip       = $ReviewZipName
        receipt_file     = $ReceiptFileName
        profile          = $Profile
        packaging_mode   = $PackagingMode
        coverage_guarantee = $CoverageGuarantee
        status           = $Status
        failure_reason   = $FailureReason
        failure_detail   = $FailureDetail
        zip_created      = $ZipCreated
        contamination_guard_enabled = $ContaminationGuardEnabled
        contamination_scanned_extensions = @($ContaminationScannedExtensions)
        contamination_excluded_extensions = @($ContaminationExcludedExtensions)
        forbidden_policy_source = $ForbiddenPolicySource
        forbidden_artifact_hits = @($ForbiddenArtifactHits)
        suite_pass_count = [int]$passCount
        suite_fail_count = [int]$failCount
        included_file_count   = @($IncludedFiles).Count
        included_files        = @($IncludedFiles)
        missing_expected_files = @($MissingExpectedFiles)
        commands         = @($CommandResults)
    }
}

function Assert-ReviewReceiptContract {
    param([Parameter(Mandatory)]$Receipt)

    foreach ($propertyName in @('generated_at', 'repo_root', 'review_zip', 'receipt_file', 'profile', 'packaging_mode', 'coverage_guarantee', 'status', 'failure_reason', 'failure_detail', 'zip_created', 'contamination_guard_enabled', 'contamination_scanned_extensions', 'contamination_excluded_extensions', 'forbidden_policy_source', 'forbidden_artifact_hits', 'suite_pass_count', 'suite_fail_count', 'included_file_count', 'included_files', 'missing_expected_files', 'commands')) {
        if ($null -eq $Receipt.PSObject.Properties[$propertyName]) {
            throw "receipt contract field missing: $propertyName"
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Receipt.generated_at)) {
        throw 'receipt generated_at must be present.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Receipt.review_zip)) {
        throw 'receipt review_zip must be present.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Receipt.receipt_file)) {
        throw 'receipt receipt_file must be present.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Receipt.profile)) {
        throw 'receipt profile must be present.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Receipt.packaging_mode)) {
        throw 'receipt packaging_mode must be present.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Receipt.coverage_guarantee)) {
        throw 'receipt coverage_guarantee must be present.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Receipt.status)) {
        throw 'receipt status must be present.'
    }

    $commands = @($Receipt.commands)
    $includedFiles = @($Receipt.included_files)
    $missingExpectedFiles = @($Receipt.missing_expected_files)
    [void]@($Receipt.contamination_scanned_extensions)
    [void]@($Receipt.contamination_excluded_extensions)
    [void]@($Receipt.forbidden_artifact_hits)
    $passCount = @($commands | Where-Object { [bool]$_.passed }).Count
    $failCount = @($commands | Where-Object { -not [bool]$_.passed }).Count
    if ([int]$Receipt.suite_pass_count -ne $passCount) {
        throw 'receipt suite_pass_count must match command pass count.'
    }
    if ([int]$Receipt.suite_fail_count -ne $failCount) {
        throw 'receipt suite_fail_count must match command fail count.'
    }
    if ([int]$Receipt.included_file_count -ne $includedFiles.Count) {
        throw 'receipt included_file_count must match included_files count.'
    }
    [void]$missingExpectedFiles

    foreach ($command in $commands) {
        foreach ($propertyName in @('label', 'command', 'passed', 'exit_code', 'duration_ms', 'summary', 'output_tail', 'error')) {
            if ($null -eq $command.PSObject.Properties[$propertyName]) {
                throw "receipt command field missing: $propertyName"
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$command.label)) {
            throw 'receipt command label must be present.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$command.command)) {
            throw 'receipt command string must be present.'
        }
        if ([int]$command.duration_ms -lt 0) {
            throw 'receipt command duration_ms must be non-negative.'
        }
        [void]@($command.output_tail)
    }
}

function Set-ReviewReceiptOutcome {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyString()][string]$FailureReason = '',
        [AllowEmptyString()][string]$FailureDetail = '',
        [bool]$ZipCreated = $false,
        [AllowEmptyCollection()][object[]]$ForbiddenArtifactHits = @()
    )

    $Receipt.status = $Status
    $Receipt.failure_reason = $FailureReason
    $Receipt.failure_detail = $FailureDetail
    $Receipt.zip_created = $ZipCreated
    $Receipt.forbidden_artifact_hits = @($ForbiddenArtifactHits)
}

function Format-CloseoutReceiptSummary {
    param([Parameter(Mandatory)]$Receipt)

    $failureReason = if (Test-NonEmptyString ([string]$Receipt.failure_reason)) {
        [string]$Receipt.failure_reason
    }
    else {
        'none'
    }

    return (
        'status={0} reason={1} zip_created={2} coverage={3}' -f
        [string]$Receipt.status,
        $failureReason,
        ([string]([bool]$Receipt.zip_created)).ToLowerInvariant(),
        [string]$Receipt.coverage_guarantee
    )
}

function Test-CloseoutAutoPackagedPath {
    param([string]$RelativePath)

    if (-not (Test-NonEmptyString $RelativePath)) {
        return $false
    }

    $normalizedPath = [string]$RelativePath -replace '/', '\'
    if ($normalizedPath -match '^(?:\.git|\.pytest_cache|__pycache__|\.tmp-review|\.tmp-smoke|_tmp|pair-test|reviewfile|venv|\.browser-ps-pair)(?:\\|$)') {
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($normalizedPath)
    return ($extension -in @('.ahk', '.cmd', '.ini', '.json', '.md', '.ps1', '.psd1', '.psm1', '.py', '.vbs'))
}

function Convert-GitStatusLineToRelativePath {
    param([string]$Line)

    if (-not (Test-NonEmptyString $Line) -or $Line.Length -lt 4) {
        return ''
    }

    $status = $Line.Substring(0, 2)
    if ($status.Contains('D')) {
        return ''
    }

    $relativePath = $Line.Substring(3).Trim()
    if ($relativePath -match ' -> ') {
        $relativePath = ($relativePath -split ' -> ')[-1]
    }

    return [string]$relativePath
}

function Get-GitModifiedCloseoutRelativePaths {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$StatusLines = @()
    )

    $statusOutput = if (@($StatusLines).Count -gt 0) {
        @($StatusLines)
    }
    else {
        @(& git -C $RepoRoot status --short --untracked-files=all 2>$null)
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($statusOutput)) {
        $relativePath = Convert-GitStatusLineToRelativePath -Line ([string]$line)
        if (-not (Test-CloseoutAutoPackagedPath -RelativePath $relativePath)) {
            continue
        }

        if (-not $paths.Contains($relativePath)) {
            $paths.Add($relativePath) | Out-Null
        }
    }

    return @($paths)
}

function Resolve-CloseoutRelativePaths {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$AdditionalRelativePaths = @(),
        [switch]$IncludeGitModifiedPaths
    )

    $relativePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @(Get-DefaultCloseoutRelativePaths)) {
        if (-not $relativePaths.Contains($relativePath)) {
            $relativePaths.Add($relativePath) | Out-Null
        }
    }
    foreach ($relativePath in @($AdditionalRelativePaths)) {
        if ((Test-NonEmptyString $relativePath) -and -not $relativePaths.Contains($relativePath)) {
            $relativePaths.Add($relativePath) | Out-Null
        }
    }
    if ($IncludeGitModifiedPaths) {
        foreach ($relativePath in @(Get-GitModifiedCloseoutRelativePaths -RepoRoot $RepoRoot)) {
            if (-not $relativePaths.Contains($relativePath)) {
                $relativePaths.Add($relativePath) | Out-Null
            }
        }
    }

    return @($relativePaths)
}

function Get-CloseoutForbiddenArtifactPolicy {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ConfigPath = ''
    )

    . (Join-Path $RepoRoot 'tests\PairedExchangeConfig.ps1')
    $effectiveConfigPath = if (Test-NonEmptyString $ConfigPath) {
        $ConfigPath
    }
    else {
        Join-Path $RepoRoot 'config\settings.bottest-live-visible.psd1'
    }

    $pairTest = Resolve-PairTestConfig -Root $RepoRoot -ConfigPath $effectiveConfigPath
    return [pscustomobject]@{
        ConfigPath = $effectiveConfigPath
        Literals   = @($pairTest.ForbiddenArtifactLiterals)
        Regexes    = @($pairTest.ForbiddenArtifactRegexes)
    }
}

function Get-CloseoutForbiddenArtifactHits {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)]$Policy
    )

    . (Join-Path $RepoRoot 'tests\PairedExchangeConfig.ps1')
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $StageRoot -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($file.Extension -notin @($script:CloseoutContaminationScannedExtensions)) {
            continue
        }

        $match = Get-ForbiddenArtifactTextFileMatch -Path $file.FullName -LiteralList @($Policy.Literals) -RegexPatternList @($Policy.Regexes)
        if (-not [bool]$match.Found) {
            continue
        }

        $relativePath = [System.IO.Path]::GetRelativePath($StageRoot, $file.FullName)
        $hits.Add([pscustomobject]@{
                Path       = $file.FullName
                RelativePath = [string]$relativePath
                MatchKind  = [string]$match.MatchKind
                Pattern    = [string]$match.Pattern
                MatchText  = [string]$match.MatchText
            }) | Out-Null
    }

    return @($hits.ToArray())
}

function Assert-CloseoutBundleNotContaminated {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)]$Policy
    )

    $hits = @(Get-CloseoutForbiddenArtifactHits -RepoRoot $RepoRoot -StageRoot $StageRoot -Policy $Policy)
    if ($hits.Count -eq 0) {
        return
    }

    $firstHit = $hits[0]
    throw ("closeout forbidden artifact detected path={0} type={1} pattern={2} match={3}" -f [string]$firstHit.RelativePath, [string]$firstHit.MatchKind, [string]$firstHit.Pattern, [string]$firstHit.MatchText)
}

function Write-ReviewReceiptFile {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath
    )

    $receiptDir = Split-Path -Parent $ReceiptPath
    if (-not (Test-Path -LiteralPath $receiptDir)) {
        New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    }

    $Receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8
}

function New-ReviewZipArchive {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelativePaths,
        [hashtable]$ExternalFiles = @{},
        [Parameter(Mandatory)][string]$StageRoot,
        $ForbiddenArtifactPolicy = $null
    )

    if (Test-Path -LiteralPath $StageRoot) {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $StageRoot -Force | Out-Null

    foreach ($relativePath in $RelativePaths) {
        $sourcePath = Join-Path $RepoRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "missing review bundle path: $relativePath"
        }

        $destinationPath = Join-Path $StageRoot $relativePath
        $destinationDir = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }

    foreach ($relativePath in @($ExternalFiles.Keys)) {
        $sourcePath = [string]$ExternalFiles[$relativePath]
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "missing review bundle external path: $relativePath <= $sourcePath"
        }

        $destinationPath = Join-Path $StageRoot $relativePath
        $destinationDir = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }

    if ($null -ne $ForbiddenArtifactPolicy) {
        Assert-CloseoutBundleNotContaminated -RepoRoot $RepoRoot -StageRoot $StageRoot -Policy $ForbiddenArtifactPolicy
    }

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    Compress-Archive -Path (Join-Path $StageRoot '*') -DestinationPath $ZipPath -CompressionLevel Optimal

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @(
            $archive.Entries |
                Select-Object -ExpandProperty FullName |
                ForEach-Object { ([string]$_).Replace('\', '/').TrimStart('/') }
        )
        foreach ($relativePath in @($RelativePaths) + @($ExternalFiles.Keys)) {
            $zipEntryPath = ($relativePath -replace '\\', '/')
            if ($entries -notcontains $zipEntryPath) {
                throw "zip contract missing path: $zipEntryPath"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Invoke-RefactorCloseoutReview {
    param(
        [string]$Stamp,
        [string]$OutputRoot = 'reviewfile',
        [switch]$IncludePairTransportAcceptance,
        [string[]]$AdditionalRelativePaths = @(),
        [switch]$IncludeGitModifiedPaths
    )

    $repoRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($Stamp)) {
        $Stamp = Get-Date -Format 'yyyyMMddHHmmss'
    }

    $resolvedOutputRoot = if ([System.IO.Path]::IsPathRooted($OutputRoot)) {
        $OutputRoot
    }
    else {
        Join-Path $repoRoot $OutputRoot
    }
    if (-not (Test-Path -LiteralPath $resolvedOutputRoot)) {
        New-Item -ItemType Directory -Path $resolvedOutputRoot -Force | Out-Null
    }

    $profile = if ($IncludePairTransportAcceptance) { 'baseline-plus-pair-transport-acceptance' } else { 'baseline' }
    $commandResults = [System.Collections.Generic.List[object]]::new()
    foreach ($spec in @(Get-DefaultCloseoutCommandSpecs -RepoRoot $repoRoot -IncludePairTransportAcceptance:$IncludePairTransportAcceptance)) {
        $result = Invoke-CloseoutCommandSpec -Spec $spec
        $commandResults.Add($result) | Out-Null
        if (-not [bool]$result.passed) {
            throw ("closeout verification failed: " + $result.label + " :: " + [string]$result.summary)
        }
    }

    $reviewZipName = $Stamp + '.zip'
    $receiptFileName = $Stamp + '.receipt.json'
    $receiptPath = Join-Path $resolvedOutputRoot $receiptFileName
    $relativePaths = @(Resolve-CloseoutRelativePaths -RepoRoot $repoRoot -AdditionalRelativePaths @($AdditionalRelativePaths) -IncludeGitModifiedPaths:$IncludeGitModifiedPaths)
    $relativeReceiptPath = Join-Path (Split-Path -Leaf $resolvedOutputRoot) $receiptFileName
    $externalFiles = @{
        $relativeReceiptPath = $receiptPath
    }
    $forbiddenArtifactPolicy = Get-CloseoutForbiddenArtifactPolicy -RepoRoot $repoRoot
    $includedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @($relativePaths) + @($externalFiles.Keys)) {
        if (-not $includedPaths.Contains([string]$relativePath)) {
            $includedPaths.Add([string]$relativePath) | Out-Null
        }
    }
    $receipt = New-ReviewReceiptObject `
        -RepoRoot $repoRoot `
        -ReviewZipName $reviewZipName `
        -ReceiptFileName $receiptFileName `
        -CommandResults @($commandResults) `
        -Profile $profile `
        -PackagingMode $(if ($IncludeGitModifiedPaths) { 'curated-allowlist-plus-explicit-paths-plus-git-modified' } else { 'curated-allowlist-plus-explicit-paths' }) `
        -CoverageGuarantee $(if ($IncludeGitModifiedPaths) { 'explicit-plus-git-modified-candidates' } else { 'explicit-curated-only' }) `
        -Status 'pending-package' `
        -FailureReason '' `
        -FailureDetail '' `
        -ZipCreated $false `
        -ContaminationGuardEnabled $true `
        -ContaminationScannedExtensions @($script:CloseoutContaminationScannedExtensions) `
        -ContaminationExcludedExtensions @($script:CloseoutContaminationExcludedExtensions) `
        -ForbiddenPolicySource ([string]$forbiddenArtifactPolicy.ConfigPath) `
        -ForbiddenArtifactHits @() `
        -IncludedFiles @($includedPaths) `
        -MissingExpectedFiles @()
    Assert-ReviewReceiptContract -Receipt $receipt
    Write-ReviewReceiptFile -Receipt $receipt -ReceiptPath $receiptPath

    $zipPath = Join-Path $resolvedOutputRoot $reviewZipName
    $stageRoot = Join-Path $repoRoot ('.tmp-review\' + $Stamp)
    try {
        New-ReviewZipArchive -RepoRoot $repoRoot -ZipPath $zipPath -RelativePaths @($relativePaths) -ExternalFiles $externalFiles -StageRoot $stageRoot -ForbiddenArtifactPolicy $forbiddenArtifactPolicy
        Set-ReviewReceiptOutcome -Receipt $receipt -Status 'succeeded' -ZipCreated (Test-Path -LiteralPath $zipPath)
        Assert-ReviewReceiptContract -Receipt $receipt
        Write-ReviewReceiptFile -Receipt $receipt -ReceiptPath $receiptPath
    }
    catch {
        $failureMessage = $_.Exception.Message
        $failureReason = 'packaging-error'
        $forbiddenArtifactHits = @()
        if (Test-NonEmptyString $failureMessage -and $failureMessage.StartsWith('closeout forbidden artifact detected')) {
            $failureReason = 'forbidden_artifact'
            if (Test-Path -LiteralPath $stageRoot) {
                $forbiddenArtifactHits = @(Get-CloseoutForbiddenArtifactHits -RepoRoot $repoRoot -StageRoot $stageRoot -Policy $forbiddenArtifactPolicy)
            }
        }
        Set-ReviewReceiptOutcome `
            -Receipt $receipt `
            -Status 'failed' `
            -FailureReason $failureReason `
            -FailureDetail $failureMessage `
            -ZipCreated (Test-Path -LiteralPath $zipPath) `
            -ForbiddenArtifactHits @($forbiddenArtifactHits)
        Assert-ReviewReceiptContract -Receipt $receipt
        Write-ReviewReceiptFile -Receipt $receipt -ReceiptPath $receiptPath
        throw
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force
        }
    }

    return [pscustomobject]@{
        Stamp         = $Stamp
        Profile       = $profile
        ZipPath       = $zipPath
        ReceiptPath   = $receiptPath
        IncludedPaths = @($includedPaths)
        Receipt       = $receipt
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-RefactorCloseoutReview @PSBoundParameters
    if ($AsJson) {
        $result | ConvertTo-Json -Depth 8
    }
    else {
        Write-Host ('closeout review bundle created: zip=' + $result.ZipPath + ' receipt=' + $result.ReceiptPath + ' profile=' + $result.Profile + ' ' + (Format-CloseoutReceiptSummary -Receipt $result.Receipt))
    }
}
