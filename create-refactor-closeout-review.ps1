[CmdletBinding()]
param(
    [string]$Stamp,
    [string]$OutputRoot = 'reviewfile',
    [switch]$IncludePairTransportAcceptance,
    [string[]]$AdditionalRelativePaths = @(),
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-DefaultCloseoutRelativePaths {
    return @(
        'config\settings.bottest-live-visible.psd1',
        'create-refactor-closeout-review.ps1',
        'test-create-refactor-closeout-review.ps1',
        'relay_operator_panel.py',
        'relay_panel_models.py',
        'relay_panel_pair_controller.py',
        'relay_panel_state.py',
        'relay_panel_watchers.py',
        'relay_panel_watcher_controller.py',
        'relay_panel_artifact_workflow.py',
        'relay_panel_runtime_workflow.py',
        'relay_panel_watcher_workflow.py',
        'test_relay_panel_refactors.py',
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
                'test_relay_panel_refactors.py'
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
        [Parameter(Mandatory)][string]$Profile
    )

    $passCount = @($CommandResults | Where-Object { [bool]$_.passed }).Count
    $failCount = @($CommandResults | Where-Object { -not [bool]$_.passed }).Count

    return [pscustomobject][ordered]@{
        generated_at     = (Get-Date).ToString('o')
        repo_root        = $RepoRoot
        review_zip       = $ReviewZipName
        receipt_file     = $ReceiptFileName
        profile          = $Profile
        suite_pass_count = [int]$passCount
        suite_fail_count = [int]$failCount
        commands         = @($CommandResults)
    }
}

function Assert-ReviewReceiptContract {
    param([Parameter(Mandatory)]$Receipt)

    foreach ($propertyName in @('generated_at', 'repo_root', 'review_zip', 'receipt_file', 'profile', 'suite_pass_count', 'suite_fail_count', 'commands')) {
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

    $commands = @($Receipt.commands)
    $passCount = @($commands | Where-Object { [bool]$_.passed }).Count
    $failCount = @($commands | Where-Object { -not [bool]$_.passed }).Count
    if ([int]$Receipt.suite_pass_count -ne $passCount) {
        throw 'receipt suite_pass_count must match command pass count.'
    }
    if ([int]$Receipt.suite_fail_count -ne $failCount) {
        throw 'receipt suite_fail_count must match command fail count.'
    }

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
        [Parameter(Mandatory)][string]$StageRoot
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
        [string[]]$AdditionalRelativePaths = @()
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
    $receipt = New-ReviewReceiptObject `
        -RepoRoot $repoRoot `
        -ReviewZipName $reviewZipName `
        -ReceiptFileName $receiptFileName `
        -CommandResults @($commandResults) `
        -Profile $profile
    Assert-ReviewReceiptContract -Receipt $receipt
    Write-ReviewReceiptFile -Receipt $receipt -ReceiptPath $receiptPath

    $relativePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @(Get-DefaultCloseoutRelativePaths)) {
        if (-not $relativePaths.Contains($relativePath)) {
            $relativePaths.Add($relativePath) | Out-Null
        }
    }
    foreach ($relativePath in @($AdditionalRelativePaths)) {
        if (-not [string]::IsNullOrWhiteSpace($relativePath) -and -not $relativePaths.Contains($relativePath)) {
            $relativePaths.Add($relativePath) | Out-Null
        }
    }
    $relativeReceiptPath = Join-Path (Split-Path -Leaf $resolvedOutputRoot) $receiptFileName
    $externalFiles = @{
        $relativeReceiptPath = $receiptPath
    }

    $zipPath = Join-Path $resolvedOutputRoot $reviewZipName
    $stageRoot = Join-Path $repoRoot ('.tmp-review\' + $Stamp)
    try {
        New-ReviewZipArchive -RepoRoot $repoRoot -ZipPath $zipPath -RelativePaths @($relativePaths) -ExternalFiles $externalFiles -StageRoot $stageRoot
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force
        }
    }

    $includedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @($relativePaths) + @($externalFiles.Keys)) {
        if (-not $includedPaths.Contains([string]$relativePath)) {
            $includedPaths.Add([string]$relativePath) | Out-Null
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
        Write-Host ('closeout review bundle created: zip=' + $result.ZipPath + ' receipt=' + $result.ReceiptPath + ' profile=' + $result.Profile)
    }
}
