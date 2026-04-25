[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string[]]$IncludePairId = @('pair01', 'pair02', 'pair03', 'pair04'),
    [int]$WatcherPollIntervalMs = 1500,
    [int]$WatcherRunDurationSec = 3600,
    [int]$WatcherMaxForwardCount = 0,
    [int]$WatcherPairMaxRoundtripCount = 0,
    [int]$StatusPollSeconds = 30,
    [int]$SoakDurationMinutes = 60,
    [int]$PauseAfterMinutes = 15,
    [int]$ResumeAfterMinutes = 18,
    [int]$RestartAfterMinutes = 30,
    [int]$MinRequiredSoakDurationMinutes = 60,
    [int]$MaxAllowedManualAttentionCount = 4,
    [int]$MaxAllowedWatcherRestartCount = 1,
    [int]$MaxAllowedPauseRequestCount = 1,
    [int]$MaxAllowedResumeRequestCount = 1,
    [int]$MinRequiredSnapshotCount = 3,
    [switch]$AutoCloseoutConfirm,
    [switch]$KnownLimitationsReviewed,
    [string]$KnownLimitationsReviewNote = '',
    [switch]$Execute,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')

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

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function ConvertTo-DisplayArgument {
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
        $parts += (ConvertTo-DisplayArgument -Value $argument)
    }

    return ($parts -join ' ')
}

function Get-TargetConfigById {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetId
    )

    $target = @(
        @($Config.Targets) |
            Where-Object { [string](Get-ConfigValue -Object $_ -Name 'Id' -DefaultValue '') -eq $TargetId } |
            Select-Object -First 1
    )
    if ($target.Count -eq 0) {
        throw "target relay config not found: $TargetId"
    }

    return $target[0]
}

function Test-OfficialSharedVisibleWindowTitle {
    param([string]$WindowTitle)

    if (-not (Test-NonEmptyString $WindowTitle)) {
        return $false
    }

    return [bool]($WindowTitle -match '^BotTestLive-Window-(0[1-8])$')
}

function Get-SharedVisibleWindowPolicy {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$SelectedPairs
    )

    $targetRows = New-Object System.Collections.Generic.List[object]
    foreach ($pair in @($SelectedPairs)) {
        $pairId = [string](Get-ConfigValue -Object $pair -Name 'PairId' -DefaultValue '')
        foreach ($targetId in @(
                [string](Get-ConfigValue -Object $pair -Name 'TopTargetId' -DefaultValue ''),
                [string](Get-ConfigValue -Object $pair -Name 'BottomTargetId' -DefaultValue '')
            )) {
            if (-not (Test-NonEmptyString $targetId)) {
                continue
            }

            $target = Get-TargetConfigById -Config $Config -TargetId $targetId
            $targetRows.Add([pscustomobject]@{
                    PairId       = $pairId
                    TargetId     = $targetId
                    WindowTitle  = [string](Get-ConfigValue -Object $target -Name 'WindowTitle' -DefaultValue '')
                    Folder       = [string](Get-ConfigValue -Object $target -Name 'Folder' -DefaultValue '')
                    WindowValid  = (Test-OfficialSharedVisibleWindowTitle -WindowTitle ([string](Get-ConfigValue -Object $target -Name 'WindowTitle' -DefaultValue '')))
                }) | Out-Null
        }
    }

    $rows = @($targetRows | Sort-Object TargetId -Unique)
    $invalidTitles = @($rows | Where-Object { -not [bool]$_.WindowValid } | ForEach-Object { [string]$_.WindowTitle })

    return [pscustomobject]@{
        Passed                   = (@($invalidTitles)).Count -eq 0
        OfficialWindowTitles     = @($rows | ForEach-Object { [string]$_.WindowTitle })
        ForbiddenWindowPatterns  = @('BotTestLive-Fresh-*', 'BotTestLive-Surrogate-*', 'BotTestLive-Candidate-*')
        TargetWindows            = @($rows)
        InvalidWindowTitles      = @($invalidTitles)
        ExecutionPathRequirement = 'visible worker queue -> Invoke-CodexExecTurn -> source-outbox publish -> watcher handoff'
        ActiveAcceptanceOrder    = 'cleanup -> preflight-only -> active acceptance -> post-cleanup'
        UsesOfficialSharedLane   = $true
    }
}

function New-PlanStep {
    param(
        [Parameter(Mandatory)][int]$Order,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [string]$PairId = '',
        [AllowEmptyCollection()][string[]]$TargetIds = @(),
        [string]$Note = ''
    )

    return [pscustomobject]@{
        Order         = $Order
        Id            = $Id
        Label         = $Label
        Mode          = $Mode
        PairId        = $PairId
        TargetIds     = @($TargetIds)
        ScriptPath    = $ScriptPath
        ArgumentList  = @($ArgumentList)
        Display       = (Join-DisplayCommand -FilePath $ScriptPath -ArgumentList $ArgumentList)
        Note          = $Note
    }
}

function Invoke-PowerShellScriptCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList
    )

    $output = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = @($output | ForEach-Object { [string]$_ })
    }
}

function Invoke-PowerShellJsonScript {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList
    )

    $result = Invoke-PowerShellScriptCapture -FilePath $FilePath -ArgumentList $ArgumentList
    if ($result.ExitCode -ne 0) {
        throw ("script failed exitCode={0} file={1} output={2}" -f $result.ExitCode, $FilePath, ($result.Lines -join [Environment]::NewLine))
    }

    $raw = ($result.Lines -join [Environment]::NewLine).Trim()
    if (-not (Test-NonEmptyString $raw)) {
        return [pscustomobject]@{
            RawLines = @($result.Lines)
            Data     = $null
        }
    }

    return [pscustomobject]@{
        RawLines = @($result.Lines)
        Data     = ($raw | ConvertFrom-Json)
    }
}

function Invoke-ExecutionStep {
    param(
        [Parameter(Mandatory)][pscustomobject]$Step,
        [Parameter(Mandatory)][string]$PowerShellPath
    )

    $startedAt = (Get-Date).ToString('o')
    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $Step.ScriptPath
    ) + @($Step.ArgumentList)
    $result = Invoke-PowerShellScriptCapture -FilePath $PowerShellPath -ArgumentList $argumentList
    $completedAt = (Get-Date).ToString('o')

    return [pscustomobject]@{
        StepId       = $Step.Id
        Label        = $Step.Label
        StartedAt    = $startedAt
        CompletedAt  = $completedAt
        ExitCode     = [int]$result.ExitCode
        OutputTail   = @($result.Lines | Select-Object -Last 12)
        Succeeded    = ([int]$result.ExitCode -eq 0)
    }
}

function Get-PairedStatusSnapshot {
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$ResolvedRunRoot
    )

    $statusResult = Invoke-PowerShellJsonScript -FilePath $PowerShellPath -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $ResolvedRunRoot,
        '-AsJson'
    )

    $status = $statusResult.Data
    return [pscustomobject]@{
        CapturedAt  = (Get-Date).ToString('o')
        Watcher     = [pscustomobject]@{
            Status                    = [string]$status.Watcher.Status
            StatusReason              = [string]$status.Watcher.StatusReason
            ForwardedCount            = [int]$status.Watcher.ForwardedCount
            ConfiguredMaxForwardCount = [int]$status.Watcher.ConfiguredMaxForwardCount
            ConfiguredRunDurationSec  = [int]$status.Watcher.ConfiguredRunDurationSec
            ConfiguredMaxRoundtripCount = [int]$status.Watcher.ConfiguredMaxRoundtripCount
        }
        Counts      = [pscustomobject]@{
            ManualAttentionCount = [int]$status.Counts.ManualAttentionCount
            HandoffReadyCount    = [int]$status.Counts.HandoffReadyCount
            ForwardedStateCount  = [int]$status.Counts.ForwardedStateCount
            DispatchRunningCount = [int]$status.Counts.DispatchRunningCount
        }
        Pairs       = @(
            @($status.Pairs) |
                ForEach-Object {
                    [pscustomobject]@{
                        PairId                   = [string]$_.PairId
                        CurrentPhase             = [string]$_.CurrentPhase
                        RoundtripCount           = [int]$_.RoundtripCount
                        ForwardedStateCount      = [int]$_.ForwardedStateCount
                        HandoffReadyCount        = [int]$_.HandoffReadyCount
                        NextExpectedHandoff      = [string]$_.NextExpectedHandoff
                        PolicySeedTargetId       = [string]$_.PolicySeedTargetId
                        ConfiguredMaxRoundtripCount = [int]$_.ConfiguredMaxRoundtripCount
                    }
                }
        )
    }
}

function Write-WatcherControlRequest {
    param(
        [Parameter(Mandatory)][string]$ResolvedRunRoot,
        [Parameter(Mandatory)][ValidateSet('stop', 'pause', 'resume')][string]$Action
    )

    $controlPath = Join-Path $ResolvedRunRoot '.state\watcher-control.json'
    Ensure-Directory -Path (Split-Path -Parent $controlPath)
    $request = [ordered]@{
        SchemaVersion = '1.0.0'
        RequestedAt   = (Get-Date).ToString('o')
        RequestedBy   = 'tests\Run-FourPairMixedSoak.ps1'
        Action        = $Action
        RunRoot       = $ResolvedRunRoot
        RequestId     = [guid]::NewGuid().ToString()
    }
    $request | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $controlPath -Encoding UTF8
    return $request
}

function Wait-ForWatcherState {
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$ResolvedRunRoot,
        [Parameter(Mandatory)][string]$DesiredState,
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
    do {
        $snapshot = Get-PairedStatusSnapshot -PowerShellPath $PowerShellPath -ResolvedConfigPath $ResolvedConfigPath -ResolvedRunRoot $ResolvedRunRoot
        if ([string]$snapshot.Watcher.Status -eq $DesiredState) {
            return $snapshot
        }

        Start-Sleep -Seconds ([math]::Max(1, $PollSeconds))
    } while ((Get-Date) -lt $deadline)

    throw ("watcher did not reach desired state '{0}' within {1} seconds." -f $DesiredState, $TimeoutSeconds)
}

function Invoke-SoakCloseoutConfirmation {
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$ResolvedRunRoot,
        [switch]$KnownLimitationsReviewed,
        [string]$KnownLimitationsReviewNote = ''
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'tests\Confirm-FourPairMixedSoakCloseout.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $ResolvedRunRoot,
        '-AsJson'
    )
    if ($KnownLimitationsReviewed) {
        $arguments += '-KnownLimitationsReviewed'
    }
    if (Test-NonEmptyString $KnownLimitationsReviewNote) {
        $arguments += @('-KnownLimitationsReviewNote', $KnownLimitationsReviewNote)
    }

    return (Invoke-PowerShellJsonScript -FilePath $PowerShellPath -ArgumentList $arguments)
}

function New-LifecycleRecord {
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Detail = '',
        [string]$RequestId = ''
    )

    return [pscustomobject]@{
        RecordedAt = (Get-Date).ToString('o')
        Action     = $Action
        Detail     = $Detail
        RequestId  = $RequestId
    }
}

function Get-SnapshotMetricMax {
    param(
        [Parameter(Mandatory)][object[]]$Snapshots,
        [Parameter(Mandatory)][string]$PropertyName
    )

    if (@($Snapshots).Count -eq 0) {
        return 0
    }

    return [int]((@($Snapshots | ForEach-Object { [int](Get-ConfigValue -Object $_.Counts -Name $PropertyName -DefaultValue 0) }) | Measure-Object -Maximum).Maximum)
}

function Get-ActualSoakDurationMinutes {
    param([Parameter(Mandatory)][object[]]$Snapshots)

    if (@($Snapshots).Count -lt 2) {
        return 0.0
    }

    $firstCapturedAt = [string](Get-ConfigValue -Object $Snapshots[0] -Name 'CapturedAt' -DefaultValue '')
    $lastCapturedAt = [string](Get-ConfigValue -Object $Snapshots[-1] -Name 'CapturedAt' -DefaultValue '')
    if (-not (Test-NonEmptyString $firstCapturedAt) -or -not (Test-NonEmptyString $lastCapturedAt)) {
        return 0.0
    }

    try {
        $first = [datetimeoffset]::Parse($firstCapturedAt)
        $last = [datetimeoffset]::Parse($lastCapturedAt)
        return [math]::Round(($last - $first).TotalMinutes, 3)
    }
    catch {
        return 0.0
    }
}

function Build-SoakThresholdEvaluation {
    param(
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)]$Thresholds,
        [int]$ExpectedPairCount = 0
    )

    $checks = @(
        [pscustomobject]@{
            Name = 'minimum-duration-minutes'
            Passed = ([double]$Summary.ActualDurationMinutes -ge [double]$Thresholds.MinRequiredSoakDurationMinutes)
            Expected = [double]$Thresholds.MinRequiredSoakDurationMinutes
            Observed = [double]$Summary.ActualDurationMinutes
        }
        [pscustomobject]@{
            Name = 'maximum-manual-attention-count'
            Passed = ([int]$Summary.MaxManualAttentionCount -le [int]$Thresholds.MaxAllowedManualAttentionCount)
            Expected = [int]$Thresholds.MaxAllowedManualAttentionCount
            Observed = [int]$Summary.MaxManualAttentionCount
        }
        [pscustomobject]@{
            Name = 'maximum-watcher-restart-count'
            Passed = ([int]$Summary.WatcherRestartCount -le [int]$Thresholds.MaxAllowedWatcherRestartCount)
            Expected = [int]$Thresholds.MaxAllowedWatcherRestartCount
            Observed = [int]$Summary.WatcherRestartCount
        }
        [pscustomobject]@{
            Name = 'maximum-pause-request-count'
            Passed = ([int]$Summary.PauseRequestCount -le [int]$Thresholds.MaxAllowedPauseRequestCount)
            Expected = [int]$Thresholds.MaxAllowedPauseRequestCount
            Observed = [int]$Summary.PauseRequestCount
        }
        [pscustomobject]@{
            Name = 'maximum-resume-request-count'
            Passed = ([int]$Summary.ResumeRequestCount -le [int]$Thresholds.MaxAllowedResumeRequestCount)
            Expected = [int]$Thresholds.MaxAllowedResumeRequestCount
            Observed = [int]$Summary.ResumeRequestCount
        }
        [pscustomobject]@{
            Name = 'minimum-snapshot-count'
            Passed = ([int]$Summary.SnapshotCount -ge [int]$Thresholds.MinRequiredSnapshotCount)
            Expected = [int]$Thresholds.MinRequiredSnapshotCount
            Observed = [int]$Summary.SnapshotCount
        }
        [pscustomobject]@{
            Name = 'required-final-watcher-status'
            Passed = ([string]$Summary.FinalWatcherStatus -eq [string]$Thresholds.RequiredFinalWatcherStatus)
            Expected = [string]$Thresholds.RequiredFinalWatcherStatus
            Observed = [string]$Summary.FinalWatcherStatus
        }
    )

    if ($ExpectedPairCount -gt 0) {
        $checks += [pscustomobject]@{
            Name = 'expected-pair-count'
            Passed = (@($Summary.FinalPairs)).Count -eq $ExpectedPairCount
            Expected = $ExpectedPairCount
            Observed = (@($Summary.FinalPairs)).Count
        }
    }

    return [pscustomobject]@{
        Passed     = (@($checks | Where-Object { -not [bool]$_.Passed })).Count -eq 0
        CheckCount = @($checks).Count
        Checks     = @($checks)
    }
}

function Build-SoakSummary {
    param(
        [Parameter(Mandatory)][object[]]$Snapshots,
        [Parameter(Mandatory)][object[]]$Lifecycle,
        [Parameter(Mandatory)]$SelectedPairs
    )

    $finalSnapshot = if (@($Snapshots).Count -gt 0) { $Snapshots[-1] } else { $null }

    return [pscustomobject]@{
        SnapshotCount               = @($Snapshots).Count
        FirstSnapshotAt             = if (@($Snapshots).Count -gt 0) { [string](Get-ConfigValue -Object $Snapshots[0] -Name 'CapturedAt' -DefaultValue '') } else { '' }
        LastSnapshotAt              = if (@($Snapshots).Count -gt 0) { [string](Get-ConfigValue -Object $Snapshots[-1] -Name 'CapturedAt' -DefaultValue '') } else { '' }
        ActualDurationMinutes       = (Get-ActualSoakDurationMinutes -Snapshots @($Snapshots))
        PauseRequestCount           = (@($Lifecycle | Where-Object { [string]$_.Action -eq 'pause-requested' })).Count
        ResumeRequestCount          = (@($Lifecycle | Where-Object { [string]$_.Action -eq 'resume-requested' })).Count
        WatcherRestartCount         = [math]::Max(0, (@($Lifecycle | Where-Object { [string]$_.Action -eq 'watcher-started' })).Count - 1)
        MaxManualAttentionCount     = Get-SnapshotMetricMax -Snapshots @($Snapshots) -PropertyName 'ManualAttentionCount'
        MaxHandoffReadyCount        = Get-SnapshotMetricMax -Snapshots @($Snapshots) -PropertyName 'HandoffReadyCount'
        MaxForwardedStateCount      = Get-SnapshotMetricMax -Snapshots @($Snapshots) -PropertyName 'ForwardedStateCount'
        FinalWatcherStatus          = $(if ($null -ne $finalSnapshot) { [string]$finalSnapshot.Watcher.Status } else { '' })
        FinalWatcherReason          = $(if ($null -ne $finalSnapshot) { [string]$finalSnapshot.Watcher.StatusReason } else { '' })
        FinalPairs                  = $(if ($null -ne $finalSnapshot) { @($finalSnapshot.Pairs) } else {
            @(
                @($SelectedPairs) | ForEach-Object {
                    [pscustomobject]@{
                        PairId                      = [string](Get-ConfigValue -Object $_ -Name 'PairId' -DefaultValue '')
                        CurrentPhase                = ''
                        RoundtripCount              = 0
                        ForwardedStateCount         = 0
                        HandoffReadyCount           = 0
                        NextExpectedHandoff         = ''
                        PolicySeedTargetId          = ''
                        ConfiguredMaxRoundtripCount = 0
                    }
                }
            )
        })
    }
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$selectedPairs = @(Select-PairDefinitions -PairDefinitions @($pairTest.PairDefinitions) -IncludePairId $IncludePairId)
if ($selectedPairs.Count -eq 0) {
    throw 'No pairs were selected for the mixed soak plan.'
}

$resolvedRunRoot = Resolve-PairRunRootPath -Root $root -RunRoot $RunRoot -PairTest $pairTest
$sharedVisiblePolicy = Get-SharedVisibleWindowPolicy -Config $config -SelectedPairs @($selectedPairs)
if (-not [bool]$sharedVisiblePolicy.Passed) {
    throw ("shared visible official window validation failed: " + ((@($sharedVisiblePolicy.InvalidWindowTitles)) -join ', '))
}

$powershellPath = Resolve-PowerShellExecutable
$selectedPairRows = @(
    @($selectedPairs) |
        ForEach-Object {
            $pairId = [string](Get-ConfigValue -Object $_ -Name 'PairId' -DefaultValue '')
            $pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId $pairId
            [pscustomobject]@{
                PairId                         = $pairId
                TopTargetId                    = [string](Get-ConfigValue -Object $_ -Name 'TopTargetId' -DefaultValue '')
                BottomTargetId                 = [string](Get-ConfigValue -Object $_ -Name 'BottomTargetId' -DefaultValue '')
                PolicySeedTargetId             = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedTargetId' -DefaultValue ([string](Get-ConfigValue -Object $_ -Name 'SeedTargetId' -DefaultValue '')))
                PolicyRoundtripLimit           = [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0)
                PolicyPauseAllowed             = [bool](Get-ConfigValue -Object $pairPolicy -Name 'PauseAllowed' -DefaultValue $true)
                PolicyPublishContractMode      = [string](Get-ConfigValue -Object $pairPolicy -Name 'PublishContractMode' -DefaultValue 'strict')
                PolicyRecoveryPolicy           = [string](Get-ConfigValue -Object $pairPolicy -Name 'RecoveryPolicy' -DefaultValue 'manual-review')
            }
        }
)
$targetIds = @($selectedPairRows | ForEach-Object { @([string]$_.TopTargetId, [string]$_.BottomTargetId) } | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique)
$planSteps = New-Object System.Collections.Generic.List[object]
$stepOrder = 1

$cleanupArguments = @(
    '-ConfigPath', $resolvedConfigPath,
    '-TargetId'
) + @($targetIds) + @(
    '-KeepRunRoot', $resolvedRunRoot,
    '-Apply',
    '-AsJson'
)
$planSteps.Add((New-PlanStep -Order $stepOrder -Id 'cleanup-visible-queue' -Label 'cleanup shared visible worker queue' -Mode 'execute-only' -ScriptPath (Join-Path $root 'visible\Cleanup-VisibleWorkerQueue.ps1') -ArgumentList $cleanupArguments -TargetIds $targetIds -Note 'required before shared visible soak')) | Out-Null
$stepOrder++

$startPairedExchangeArguments = @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $resolvedRunRoot,
    '-IncludePairId'
) + @($selectedPairRows | ForEach-Object { [string]$_.PairId })
$planSteps.Add((New-PlanStep -Order $stepOrder -Id 'start-paired-exchange' -Label 'prepare 4pair run root and manifest' -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') -ArgumentList $startPairedExchangeArguments -Note 'prepare run root without dispatching initial messages')) | Out-Null
$stepOrder++

foreach ($pair in @($selectedPairRows)) {
    $planSteps.Add((New-PlanStep -Order $stepOrder -Id ('preflight-' + [string]$pair.PairId) -Label ('preflight-only ' + [string]$pair.PairId) -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1') -ArgumentList @(
                '-ConfigPath', $resolvedConfigPath,
                '-RunRoot', $resolvedRunRoot,
                '-PairId', [string]$pair.PairId,
                '-ReuseExistingRunRoot',
                '-PreflightOnly',
                '-AsJson'
            ) -PairId ([string]$pair.PairId) -TargetIds @([string]$pair.TopTargetId, [string]$pair.BottomTargetId) -Note 'official shared visible preflight using existing run root')) | Out-Null
    $stepOrder++
}

foreach ($pair in @($selectedPairRows)) {
    $planSteps.Add((New-PlanStep -Order $stepOrder -Id ('seed-' + [string]$pair.PairId) -Label ('send initial seed ' + [string]$pair.PairId) -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1') -ArgumentList @(
                '-ConfigPath', $resolvedConfigPath,
                '-RunRoot', $resolvedRunRoot,
                '-TargetId', [string]$pair.PolicySeedTargetId,
                '-AsJson'
            ) -PairId ([string]$pair.PairId) -TargetIds @([string]$pair.PolicySeedTargetId) -Note 'seed target comes from PairPolicies.DefaultSeedTargetId')) | Out-Null
    $stepOrder++
}

$planSteps.Add((New-PlanStep -Order $stepOrder -Id 'start-watcher' -Label 'start watcher for mixed soak' -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -ArgumentList @(
            '-ConfigPath', $resolvedConfigPath,
            '-RunRoot', $resolvedRunRoot,
            '-PollIntervalMs', [string]$WatcherPollIntervalMs,
            '-RunDurationSec', [string]$WatcherRunDurationSec,
            '-MaxForwardCount', [string]$WatcherMaxForwardCount,
            '-PairMaxRoundtripCount', [string]$WatcherPairMaxRoundtripCount
        ) -Note 'starts detached watcher process for shared visible soak')) | Out-Null
$stepOrder++

$planSteps.Add((New-PlanStep -Order $stepOrder -Id 'snapshot-initial' -Label 'capture initial paired status snapshot' -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ArgumentList @(
            '-ConfigPath', $resolvedConfigPath,
            '-RunRoot', $resolvedRunRoot,
            '-AsJson'
        ) -Note 'records watcher/pair state at soak start')) | Out-Null
$stepOrder++

if ($PauseAfterMinutes -gt 0) {
    $planSteps.Add((New-PlanStep -Order $stepOrder -Id 'watcher-pause' -Label 'pause watcher mid-soak' -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ArgumentList @(
                '-ConfigPath', $resolvedConfigPath,
                '-RunRoot', $resolvedRunRoot,
                '-AsJson'
            ) -Note ('wrapper writes watcher-control pause request at +{0} minutes' -f $PauseAfterMinutes))) | Out-Null
    $stepOrder++
}

if ($ResumeAfterMinutes -gt 0) {
    $planSteps.Add((New-PlanStep -Order $stepOrder -Id 'watcher-resume' -Label 'resume watcher after pause' -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ArgumentList @(
                '-ConfigPath', $resolvedConfigPath,
                '-RunRoot', $resolvedRunRoot,
                '-AsJson'
            ) -Note ('wrapper writes watcher-control resume request at +{0} minutes' -f $ResumeAfterMinutes))) | Out-Null
    $stepOrder++
}

if ($RestartAfterMinutes -gt 0) {
    $planSteps.Add((New-PlanStep -Order $stepOrder -Id 'watcher-restart' -Label 'stop and restart watcher once during soak' -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ArgumentList @(
                '-ConfigPath', $resolvedConfigPath,
                '-RunRoot', $resolvedRunRoot,
                '-AsJson'
            ) -Note ('wrapper issues stop/start around +{0} minutes' -f $RestartAfterMinutes))) | Out-Null
    $stepOrder++
}

$planSteps.Add((New-PlanStep -Order $stepOrder -Id 'snapshot-final' -Label 'capture final paired status snapshot' -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ArgumentList @(
            '-ConfigPath', $resolvedConfigPath,
            '-RunRoot', $resolvedRunRoot,
            '-AsJson'
        ) -Note 'final receipt should match pair-state, watcher-status, and panel summary')) | Out-Null
$stepOrder++

$planSteps.Add((New-PlanStep -Order $stepOrder -Id 'stop-watcher' -Label 'final watcher stop request' -Mode 'execute-only' -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ArgumentList @(
            '-ConfigPath', $resolvedConfigPath,
            '-RunRoot', $resolvedRunRoot,
            '-AsJson'
        ) -Note 'wrapper writes watcher-control stop request during final shutdown')) | Out-Null
$stepOrder++

$planSteps.Add((New-PlanStep -Order $stepOrder -Id 'post-cleanup-visible-queue' -Label 'post-cleanup shared visible worker queue' -Mode 'execute-only' -ScriptPath (Join-Path $root 'visible\Cleanup-VisibleWorkerQueue.ps1') -ArgumentList $cleanupArguments -TargetIds $targetIds -Note 'post-run cleanup for shared visible lane')) | Out-Null

$stateRoot = Join-Path $resolvedRunRoot '.state'
$plannedReceiptPath = Join-Path $stateRoot 'four-pair-soak-receipt.json'
$executionMode = if ($Execute) { 'execute' } else { 'plan' }
$soakProfile = [pscustomobject]@{
    DurationMinutes              = $SoakDurationMinutes
    StatusPollSeconds            = $StatusPollSeconds
    WatcherPollIntervalMs        = $WatcherPollIntervalMs
    WatcherRunDurationSec        = $WatcherRunDurationSec
    WatcherMaxForwardCount       = $WatcherMaxForwardCount
    WatcherPairMaxRoundtripCount = $WatcherPairMaxRoundtripCount
    PauseAfterMinutes            = $PauseAfterMinutes
    ResumeAfterMinutes           = $ResumeAfterMinutes
    RestartAfterMinutes          = $RestartAfterMinutes
}
$closeoutThresholds = [pscustomobject]@{
    MinRequiredSoakDurationMinutes = $MinRequiredSoakDurationMinutes
    MaxAllowedManualAttentionCount = $MaxAllowedManualAttentionCount
    MaxAllowedWatcherRestartCount  = $MaxAllowedWatcherRestartCount
    MaxAllowedPauseRequestCount    = $MaxAllowedPauseRequestCount
    MaxAllowedResumeRequestCount   = $MaxAllowedResumeRequestCount
    MinRequiredSnapshotCount       = $MinRequiredSnapshotCount
    RequiredFinalWatcherStatus     = 'stopped'
    ExpectedPairCount              = @($selectedPairRows).Count
}
$sharedVisibleSummary = [pscustomobject]@{
    OfficialWindowValidation          = $sharedVisiblePolicy
    ExecuteRequiresOfficialWindowsOnly = $true
    PlanOnlyByDefault                 = $true
}
$recommendedCommands = [pscustomobject]@{
    PlanOnly = ('pwsh -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -RunRoot "{2}" -AsJson' -f (Join-Path $root 'tests\Run-FourPairMixedSoak.ps1'), $resolvedConfigPath, $resolvedRunRoot)
    Execute  = ('pwsh -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -RunRoot "{2}" -Execute -AsJson' -f (Join-Path $root 'tests\Run-FourPairMixedSoak.ps1'), $resolvedConfigPath, $resolvedRunRoot)
    Closeout = ('pwsh -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -RunRoot "{2}" -AsJson' -f (Join-Path $root 'tests\Confirm-FourPairMixedSoakCloseout.ps1'), $resolvedConfigPath, $resolvedRunRoot)
    ExecuteWithAutoCloseout = ('pwsh -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -RunRoot "{2}" -Execute -AutoCloseoutConfirm -AsJson' -f (Join-Path $root 'tests\Run-FourPairMixedSoak.ps1'), $resolvedConfigPath, $resolvedRunRoot)
}
$knownLimitations = @(
    'This wrapper defaults to plan mode. Shared visible execution requires -Execute.',
    'Long-run shared visible execution is not part of the normal regression suite.',
    'manual-attention, focus loss, and window-specific input faults still require real 8-window soak validation.',
    'Crash/stale recovery should still be cross-checked with Test-WatcherCrashRecoveryAutomation.ps1.'
)
$selectedPairArray = [object[]]@($selectedPairRows)
$planStepArray = [object[]]@($planSteps | ForEach-Object { $_ })
$knownLimitationArray = [object[]]@($knownLimitations)
$result = New-Object PSObject
$result | Add-Member -NotePropertyName 'SchemaVersion' -NotePropertyValue '1.0.0'
$result | Add-Member -NotePropertyName 'GeneratedAt' -NotePropertyValue ((Get-Date).ToString('o'))
$result | Add-Member -NotePropertyName 'ExecutionMode' -NotePropertyValue $executionMode
$result | Add-Member -NotePropertyName 'AutoCloseoutConfirm' -NotePropertyValue ([bool]$AutoCloseoutConfirm)
$result | Add-Member -NotePropertyName 'KnownLimitationsReviewed' -NotePropertyValue ([bool]$KnownLimitationsReviewed)
$result | Add-Member -NotePropertyName 'KnownLimitationsReviewNote' -NotePropertyValue $KnownLimitationsReviewNote
$result | Add-Member -NotePropertyName 'ConfigPath' -NotePropertyValue $resolvedConfigPath
$result | Add-Member -NotePropertyName 'RunRoot' -NotePropertyValue $resolvedRunRoot
$result | Add-Member -NotePropertyName 'PlannedReceiptPath' -NotePropertyValue $plannedReceiptPath
$result | Add-Member -NotePropertyName 'SoakProfile' -NotePropertyValue $soakProfile
$result | Add-Member -NotePropertyName 'CloseoutThresholds' -NotePropertyValue $closeoutThresholds
$result | Add-Member -NotePropertyName 'SharedVisiblePolicy' -NotePropertyValue $sharedVisibleSummary
$result | Add-Member -NotePropertyName 'SelectedPairs' -NotePropertyValue $selectedPairArray
$result | Add-Member -NotePropertyName 'PlanSteps' -NotePropertyValue $planStepArray
$result | Add-Member -NotePropertyName 'Execution' -NotePropertyValue ([pscustomobject]@{
        Records   = @()
        Snapshots = @()
        Summary   = $null
    })
$result | Add-Member -NotePropertyName 'RecommendedCommands' -NotePropertyValue $recommendedCommands
$result | Add-Member -NotePropertyName 'KnownLimitations' -NotePropertyValue $knownLimitationArray

if ($Execute) {
    Ensure-Directory -Path $stateRoot
    $lifecycle = New-Object System.Collections.Generic.List[object]
    $snapshots = New-Object System.Collections.Generic.List[object]
    $executionRecords = New-Object System.Collections.Generic.List[object]
    $watcherProcess = $null
    $pauseIssued = $false
    $resumeIssued = $false
    $restartIssued = $false
    $watcherStartCount = 0

    try {
        foreach ($step in @($planSteps | Where-Object { $_.Id -in @('cleanup-visible-queue', 'start-paired-exchange') })) {
            $record = Invoke-ExecutionStep -Step $step -PowerShellPath $powershellPath
            $executionRecords.Add($record) | Out-Null
            if (-not [bool]$record.Succeeded) {
                throw ("execution step failed: {0}" -f $step.Id)
            }
        }

        foreach ($step in @($planSteps | Where-Object { $_.Id -like 'preflight-*' })) {
            $record = Invoke-ExecutionStep -Step $step -PowerShellPath $powershellPath
            $executionRecords.Add($record) | Out-Null
            if (-not [bool]$record.Succeeded) {
                throw ("execution step failed: {0}" -f $step.Id)
            }
        }

        foreach ($step in @($planSteps | Where-Object { $_.Id -like 'seed-*' })) {
            $record = Invoke-ExecutionStep -Step $step -PowerShellPath $powershellPath
            $executionRecords.Add($record) | Out-Null
            if (-not [bool]$record.Succeeded) {
                throw ("execution step failed: {0}" -f $step.Id)
            }
        }

        $watcherStdOutPath = Join-Path $stateRoot 'four-pair-soak-watcher.stdout.log'
        $watcherStdErrPath = Join-Path $stateRoot 'four-pair-soak-watcher.stderr.log'
        $watcherArgumentList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
            '-ConfigPath', $resolvedConfigPath,
            '-RunRoot', $resolvedRunRoot,
            '-PollIntervalMs', [string]$WatcherPollIntervalMs,
            '-RunDurationSec', [string]$WatcherRunDurationSec,
            '-MaxForwardCount', [string]$WatcherMaxForwardCount,
            '-PairMaxRoundtripCount', [string]$WatcherPairMaxRoundtripCount
        )
        $watcherProcess = Start-Process -FilePath $powershellPath -ArgumentList $watcherArgumentList -PassThru -NoNewWindow -RedirectStandardOutput $watcherStdOutPath -RedirectStandardError $watcherStdErrPath
        $watcherStartCount++
        $lifecycle.Add((New-LifecycleRecord -Action 'watcher-started' -Detail ('pid=' + [string]$watcherProcess.Id))) | Out-Null
        $executionRecords.Add([pscustomobject]@{
                StepId      = 'start-watcher'
                Label       = 'start watcher for mixed soak'
                StartedAt   = (Get-Date).ToString('o')
                CompletedAt = (Get-Date).ToString('o')
                ExitCode    = 0
                OutputTail  = @('watcher-started')
                Succeeded   = $true
            }) | Out-Null

        $runningSnapshot = Wait-ForWatcherState -PowerShellPath $powershellPath -ResolvedConfigPath $resolvedConfigPath -ResolvedRunRoot $resolvedRunRoot -DesiredState 'running' -TimeoutSeconds 90 -PollSeconds ([math]::Max(1, [math]::Floor($StatusPollSeconds / 3)))
        $snapshots.Add($runningSnapshot) | Out-Null

        $startedAt = Get-Date
        $deadline = $startedAt.AddMinutes([math]::Max(1, $SoakDurationMinutes))
        while ((Get-Date) -lt $deadline) {
            $elapsedMinutes = ((Get-Date) - $startedAt).TotalMinutes

            if (-not $pauseIssued -and $PauseAfterMinutes -gt 0 -and $elapsedMinutes -ge $PauseAfterMinutes) {
                $request = Write-WatcherControlRequest -ResolvedRunRoot $resolvedRunRoot -Action 'pause'
                $lifecycle.Add((New-LifecycleRecord -Action 'pause-requested' -Detail 'mid-soak pause' -RequestId ([string]$request.RequestId))) | Out-Null
                $pauseIssued = $true
            }

            if (-not $resumeIssued -and $ResumeAfterMinutes -gt 0 -and $elapsedMinutes -ge $ResumeAfterMinutes) {
                $request = Write-WatcherControlRequest -ResolvedRunRoot $resolvedRunRoot -Action 'resume'
                $lifecycle.Add((New-LifecycleRecord -Action 'resume-requested' -Detail 'resume after pause' -RequestId ([string]$request.RequestId))) | Out-Null
                $resumeIssued = $true
            }

            if (-not $restartIssued -and $RestartAfterMinutes -gt 0 -and $elapsedMinutes -ge $RestartAfterMinutes) {
                $request = Write-WatcherControlRequest -ResolvedRunRoot $resolvedRunRoot -Action 'stop'
                $lifecycle.Add((New-LifecycleRecord -Action 'stop-requested' -Detail 'mid-soak restart stop' -RequestId ([string]$request.RequestId))) | Out-Null
                $stoppedSnapshot = Wait-ForWatcherState -PowerShellPath $powershellPath -ResolvedConfigPath $resolvedConfigPath -ResolvedRunRoot $resolvedRunRoot -DesiredState 'stopped' -TimeoutSeconds 90 -PollSeconds ([math]::Max(1, [math]::Floor($StatusPollSeconds / 3)))
                $snapshots.Add($stoppedSnapshot) | Out-Null
                if ($null -ne $watcherProcess) {
                    try {
                        $null = $watcherProcess.WaitForExit(5000)
                    }
                    catch {
                    }
                }

                $watcherProcess = Start-Process -FilePath $powershellPath -ArgumentList $watcherArgumentList -PassThru -NoNewWindow -RedirectStandardOutput $watcherStdOutPath -RedirectStandardError $watcherStdErrPath
                $watcherStartCount++
                $lifecycle.Add((New-LifecycleRecord -Action 'watcher-started' -Detail ('restart pid=' + [string]$watcherProcess.Id))) | Out-Null
                $restartIssued = $true
                $resumedSnapshot = Wait-ForWatcherState -PowerShellPath $powershellPath -ResolvedConfigPath $resolvedConfigPath -ResolvedRunRoot $resolvedRunRoot -DesiredState 'running' -TimeoutSeconds 90 -PollSeconds ([math]::Max(1, [math]::Floor($StatusPollSeconds / 3)))
                $snapshots.Add($resumedSnapshot) | Out-Null
            }

            $snapshot = Get-PairedStatusSnapshot -PowerShellPath $powershellPath -ResolvedConfigPath $resolvedConfigPath -ResolvedRunRoot $resolvedRunRoot
            $snapshots.Add($snapshot) | Out-Null
            Start-Sleep -Seconds ([math]::Max(1, $StatusPollSeconds))
        }
    }
    finally {
        try {
            $finalStop = Write-WatcherControlRequest -ResolvedRunRoot $resolvedRunRoot -Action 'stop'
            $lifecycle.Add((New-LifecycleRecord -Action 'stop-requested' -Detail 'final shutdown' -RequestId ([string]$finalStop.RequestId))) | Out-Null
        }
        catch {
        }

        try {
            $stoppedSnapshot = Wait-ForWatcherState -PowerShellPath $powershellPath -ResolvedConfigPath $resolvedConfigPath -ResolvedRunRoot $resolvedRunRoot -DesiredState 'stopped' -TimeoutSeconds 90 -PollSeconds ([math]::Max(1, [math]::Floor($StatusPollSeconds / 3)))
            $snapshots.Add($stoppedSnapshot) | Out-Null
        }
        catch {
        }

        if ($null -ne $watcherProcess) {
            try {
                if (-not $watcherProcess.HasExited) {
                    $null = $watcherProcess.WaitForExit(5000)
                }
            }
            catch {
            }
        }

        $postCleanupStep = @($planSteps | Where-Object { $_.Id -eq 'post-cleanup-visible-queue' } | Select-Object -First 1)
        if ($postCleanupStep.Count -gt 0) {
            try {
                $record = Invoke-ExecutionStep -Step $postCleanupStep[0] -PowerShellPath $powershellPath
                $executionRecords.Add($record) | Out-Null
            }
            catch {
            }
        }
    }

    $summary = Build-SoakSummary -Snapshots @($snapshots) -Lifecycle @($lifecycle) -SelectedPairs @($selectedPairRows)
    $summary | Add-Member -NotePropertyName 'ThresholdEvaluation' -NotePropertyValue (Build-SoakThresholdEvaluation -Summary $summary -Thresholds $closeoutThresholds -ExpectedPairCount (@($selectedPairRows).Count))
    $result.Execution = [pscustomobject]@{
        Records   = @($executionRecords)
        Snapshots = @($snapshots)
        Summary   = $summary
    }

    Ensure-Directory -Path $stateRoot
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $plannedReceiptPath -Encoding UTF8

    if ($AutoCloseoutConfirm) {
        $closeoutResult = Invoke-SoakCloseoutConfirmation `
            -PowerShellPath $powershellPath `
            -ResolvedConfigPath $resolvedConfigPath `
            -ResolvedRunRoot $resolvedRunRoot `
            -KnownLimitationsReviewed:$KnownLimitationsReviewed `
            -KnownLimitationsReviewNote $KnownLimitationsReviewNote
        $result | Add-Member -NotePropertyName 'CloseoutConfirmation' -NotePropertyValue $closeoutResult.Data -Force
        $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $plannedReceiptPath -Encoding UTF8
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
}
else {
    $result
}
