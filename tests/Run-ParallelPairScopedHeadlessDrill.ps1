[CmdletBinding()]
param(
    [string]$BaseConfigPath,
    [string]$CoordinatorWorkRepoRoot,
    [string[]]$PairId,
    [int]$PairMaxRoundtripCount = 1,
    [int]$RunDurationSec = 1800,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

function Resolve-PowerShellExecutable {
    $candidates = @('pwsh.exe', 'powershell.exe')
    foreach ($name in $candidates) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            if ($command.Source) {
                return [string]$command.Source
            }
            if ($command.Path) {
                return [string]$command.Path
            }
            return [string]$name
        }
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Invoke-LocalScriptAndCaptureOutput {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $scriptOutput = @()
    try {
        foreach ($line in @(& $ScriptPath @Parameters 2>&1)) {
            $scriptOutput += [string]$line
        }
    }
    catch {
        $detail = ($scriptOutput -join [Environment]::NewLine)
        throw "스크립트 실행 실패 file=$ScriptPath output=$detail error=$($_.Exception.Message)"
    }

    return @($scriptOutput)
}

function Get-JsonObjectFromMixedOutput {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $start = $raw.IndexOf('{')
    $end = $raw.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) {
        throw "JSON payload를 찾지 못했습니다: $Path"
    }

    $jsonText = $raw.Substring($start, $end - $start + 1)
    return ($jsonText | ConvertFrom-Json)
}

function New-TempFilePath {
    param([Parameter(Mandatory)][string]$Prefix)

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'relay-pair-scoped-drill'
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    }

    return (Join-Path $tempRoot ('{0}_{1}.log' -f $Prefix, ([guid]::NewGuid().ToString('N'))))
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload,
        [int]$Depth = 10
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    [System.IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth $Depth), (New-Utf8NoBomEncoding))
}

function Write-WrapperStatus {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$BaseConfigPath,
        [Parameter(Mandatory)][string[]]$PairIds,
        [Parameter(Mandatory)][int]$PairMaxRoundtripCount,
        [Parameter(Mandatory)][int]$RunDurationSec,
        [string]$CoordinatorWorkRepoRoot = '',
        [string]$CoordinatorRunRoot = '',
        [string]$CoordinatorManifestPath = '',
        [string]$CoordinatorWatcherStatusPath = '',
        [string]$CoordinatorPairStatePath = '',
        [string]$Message = '',
        [object[]]$GeneratedConfigs = @(),
        [object[]]$ProcessRows = @(),
        [object[]]$PairRuns = @()
    )

    $payload = [pscustomobject]@{
        SchemaVersion = '1.0.0'
        Status = $Status
        UpdatedAt = (Get-Date).ToString('o')
        BaseConfigPath = $BaseConfigPath
        CoordinatorWorkRepoRoot = $CoordinatorWorkRepoRoot
        CoordinatorRunRoot = $CoordinatorRunRoot
        CoordinatorManifestPath = $CoordinatorManifestPath
        CoordinatorWatcherStatusPath = $CoordinatorWatcherStatusPath
        CoordinatorPairStatePath = $CoordinatorPairStatePath
        PairIds = @($PairIds)
        PairMaxRoundtripCount = $PairMaxRoundtripCount
        RunDurationSec = $RunDurationSec
        Message = $Message
        GeneratedConfigs = @(
            foreach ($item in @($GeneratedConfigs)) {
                [pscustomobject]@{
                    PairId = [string]$item.PairId
                    WorkRepoRoot = [string]$item.WorkRepoRoot
                    OutputConfigPath = [string]$item.OutputConfigPath
                    BookkeepingRoot = [string]$item.BookkeepingRoot
                    PairRunRootBase = [string]$item.PairRunRootBase
                }
            }
        )
        ChildProcesses = @(
            foreach ($item in @($ProcessRows)) {
                [pscustomobject]@{
                    PairId = [string]$item.PairId
                    InitialTargetId = [string]$item.InitialTargetId
                    ConfigPath = [string]$item.ConfigPath
                    WorkRepoRoot = [string]$item.WorkRepoRoot
                    BookkeepingRoot = [string]$item.BookkeepingRoot
                    PairRunRootBase = if ($null -ne $item.PSObject.Properties['PairRunRootBase']) { [string]$item.PairRunRootBase } else { '' }
                    StdOutPath = [string]$item.StdOutPath
                    StdErrPath = [string]$item.StdErrPath
                    ProcessId = if ($null -ne $item.Process) { [int]$item.Process.Id } else { 0 }
                    ProcessStartedAt = if ($null -ne $item.PSObject.Properties['ProcessStartedAt']) { [string]$item.ProcessStartedAt } else { '' }
                    ExitCode = if ($null -ne $item.PSObject.Properties['ExitCode']) { [int]$item.ExitCode } else { 0 }
                    RunRoot = if ($null -ne $item.PSObject.Properties['RunRoot']) { [string]$item.RunRoot } else { '' }
                    ProcessExitedAt = if ($null -ne $item.PSObject.Properties['ProcessExitedAt']) { [string]$item.ProcessExitedAt } else { '' }
                }
            }
        )
        PairRuns = @($PairRuns)
    }

    Write-JsonFile -Path $Path -Payload $payload -Depth 12
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')

if (-not (Test-NonEmptyString $BaseConfigPath)) {
    $BaseConfigPath = Get-DefaultConfigPath -Root $root
}
$resolvedBaseConfigPath = (Resolve-Path -LiteralPath $BaseConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedBaseConfigPath

$selectedPairs = if (@($PairId | Where-Object { Test-NonEmptyString $_ }).Count -gt 0) {
    @(Select-PairDefinitions -PairDefinitions @($pairTest.PairDefinitions) -IncludePairId @($PairId))
}
else {
    @($pairTest.PairDefinitions | Select-Object -First 2)
}
if ($selectedPairs.Count -lt 1) {
    throw 'parallel pair-scoped headless drill에 사용할 pair를 찾지 못했습니다.'
}

$resolvedPairIds = @($selectedPairs | ForEach-Object { [string]$_.PairId })
$pairConfigScriptPath = Join-Path $root 'tests\Write-PairExternalizedRelayConfigs.ps1'
$pairConfigOutput = Invoke-LocalScriptAndCaptureOutput -ScriptPath $pairConfigScriptPath -Parameters @{
    BaseConfigPath = $resolvedBaseConfigPath
    PairId = @($resolvedPairIds)
    AsJson = $true
}
$pairConfigJson = ($pairConfigOutput -join [Environment]::NewLine)
$pairConfigResult = $pairConfigJson | ConvertFrom-Json

$generatedConfigs = @($pairConfigResult.GeneratedConfigs)
$missingConfigPairs = @($resolvedPairIds | Where-Object { $_ -notin @($generatedConfigs | ForEach-Object { [string]$_.PairId }) })
if ($missingConfigPairs.Count -gt 0) {
    throw ("pair-scoped externalized config 누락: {0}" -f ($missingConfigPairs -join ', '))
}

$resolvedCoordinatorWorkRepoRoot = ''
$coordinatorRunRoot = ''
$coordinatorManifestPath = ''
$coordinatorWatcherStatusPath = ''
$coordinatorPairStatePath = ''
$coordinatorWrapperStatusPath = ''
if (Test-NonEmptyString $CoordinatorWorkRepoRoot) {
    $resolvedCoordinatorWorkRepoRoot = [System.IO.Path]::GetFullPath($CoordinatorWorkRepoRoot)
    Ensure-Directory -Path $resolvedCoordinatorWorkRepoRoot
    $coordinatorRunRoot = Join-Path (Join-Path $resolvedCoordinatorWorkRepoRoot '.relay-runs\bottest-live-visible\pair-scoped-shared') ('run_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Ensure-Directory -Path $coordinatorRunRoot
    Ensure-Directory -Path (Join-Path $coordinatorRunRoot '.state')
    $coordinatorManifestPath = Join-Path $coordinatorRunRoot 'manifest.json'
    $coordinatorWatcherStatusPath = Join-Path $coordinatorRunRoot '.state\watcher-status.json'
    $coordinatorPairStatePath = Join-Path $coordinatorRunRoot '.state\pair-state.json'
    $coordinatorWrapperStatusPath = Join-Path $coordinatorRunRoot '.state\wrapper-status.json'
    Write-WrapperStatus `
        -Path $coordinatorWrapperStatusPath `
        -Status 'initializing' `
        -BaseConfigPath $resolvedBaseConfigPath `
        -PairIds @($resolvedPairIds) `
        -PairMaxRoundtripCount $PairMaxRoundtripCount `
        -RunDurationSec $RunDurationSec `
        -CoordinatorWorkRepoRoot $resolvedCoordinatorWorkRepoRoot `
        -CoordinatorRunRoot $coordinatorRunRoot `
        -CoordinatorManifestPath $coordinatorManifestPath `
        -CoordinatorWatcherStatusPath $coordinatorWatcherStatusPath `
        -CoordinatorPairStatePath $coordinatorPairStatePath `
        -Message 'pair-scoped parallel wrapper initialized' `
        -GeneratedConfigs @($generatedConfigs)
}

$powershellPath = Resolve-PowerShellExecutable
$runnerScriptPath = Join-Path $root 'tests\Run-HeadlessMultiPairDrill.ps1'
$processRows = @()
try {
    foreach ($pair in @($selectedPairs)) {
        $pairIdValue = [string]$pair.PairId
        $pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId $pairIdValue
        $initialTargetId = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedTargetId' -DefaultValue ([string]$pair.TopTargetId))
        $configRow = @($generatedConfigs | Where-Object { [string]$_.PairId -eq $pairIdValue } | Select-Object -First 1)[0]
        if ($null -eq $configRow) {
            throw "pair-scoped config row 누락: $pairIdValue"
        }

        $stdoutPath = New-TempFilePath -Prefix ($pairIdValue + '_stdout')
        $stderrPath = New-TempFilePath -Prefix ($pairIdValue + '_stderr')
        $argumentList = @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $runnerScriptPath),
            '-ConfigPath', ('"{0}"' -f [string]$configRow.OutputConfigPath),
            '-PairId', $pairIdValue,
            '-InitialTargetId', $initialTargetId,
            '-PairMaxRoundtripCount', [string]$PairMaxRoundtripCount,
            '-RunDurationSec', [string]$RunDurationSec,
            '-AsJson'
        )
        $argumentString = $argumentList -join ' '
        $process = Start-Process -FilePath $powershellPath -ArgumentList $argumentString -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden

        $processRows += [pscustomobject]@{
            PairId = $pairIdValue
            InitialTargetId = $initialTargetId
            ConfigPath = [string]$configRow.OutputConfigPath
            WorkRepoRoot = [string]$configRow.WorkRepoRoot
            BookkeepingRoot = [string]$configRow.BookkeepingRoot
            PairRunRootBase = [string]$configRow.PairRunRootBase
            StdOutPath = $stdoutPath
            StdErrPath = $stderrPath
            Process = $process
            ProcessStartedAt = (Get-Date).ToString('o')
        }
    }

    if (Test-NonEmptyString $coordinatorWrapperStatusPath) {
        Write-WrapperStatus `
            -Path $coordinatorWrapperStatusPath `
            -Status 'running' `
            -BaseConfigPath $resolvedBaseConfigPath `
            -PairIds @($resolvedPairIds) `
            -PairMaxRoundtripCount $PairMaxRoundtripCount `
            -RunDurationSec $RunDurationSec `
            -CoordinatorWorkRepoRoot $resolvedCoordinatorWorkRepoRoot `
            -CoordinatorRunRoot $coordinatorRunRoot `
            -CoordinatorManifestPath $coordinatorManifestPath `
            -CoordinatorWatcherStatusPath $coordinatorWatcherStatusPath `
            -CoordinatorPairStatePath $coordinatorPairStatePath `
            -Message 'child pair runs started' `
            -GeneratedConfigs @($generatedConfigs) `
            -ProcessRows @($processRows)
    }

    $pairResults = @()
    foreach ($row in @($processRows)) {
        if (-not $row.Process.WaitForExit($RunDurationSec * 1000 + 600000)) {
            try {
                $row.Process.Kill($true)
            }
            catch {
            }
            throw "pair-scoped drill timeout: $($row.PairId)"
        }
    }

    foreach ($row in @($processRows)) {
        if ($row.Process.ExitCode -ne 0) {
            $stderrText = if (Test-Path -LiteralPath $row.StdErrPath) { Get-Content -LiteralPath $row.StdErrPath -Raw -Encoding UTF8 } else { '' }
            $stdoutText = if (Test-Path -LiteralPath $row.StdOutPath) { Get-Content -LiteralPath $row.StdOutPath -Raw -Encoding UTF8 } else { '' }
            throw "pair-scoped drill 실패 pair=$($row.PairId) exitCode=$($row.Process.ExitCode) stdout=$stdoutText stderr=$stderrText"
        }

        $payload = Get-JsonObjectFromMixedOutput -Path $row.StdOutPath
        $row | Add-Member -NotePropertyName ExitCode -NotePropertyValue ([int]$row.Process.ExitCode) -Force
        $row | Add-Member -NotePropertyName RunRoot -NotePropertyValue ([string]$payload.RunRoot) -Force
        $row | Add-Member -NotePropertyName ProcessExitedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
        $pairResults += [pscustomobject]@{
            PairId = [string]$row.PairId
            InitialTargetId = [string]$row.InitialTargetId
            ConfigPath = [string]$row.ConfigPath
            WorkRepoRoot = [string]$row.WorkRepoRoot
            BookkeepingRoot = [string]$row.BookkeepingRoot
            PairRunRootBase = [string]$row.PairRunRootBase
            StdOutPath = [string]$row.StdOutPath
            StdErrPath = [string]$row.StdErrPath
            ExitCode = [int]$row.Process.ExitCode
            RunRoot = [string]$payload.RunRoot
            Result = $payload
        }
    }

    if (Test-NonEmptyString $coordinatorWrapperStatusPath) {
        Write-WrapperStatus `
            -Path $coordinatorWrapperStatusPath `
            -Status 'child-runs-completed' `
            -BaseConfigPath $resolvedBaseConfigPath `
            -PairIds @($resolvedPairIds) `
            -PairMaxRoundtripCount $PairMaxRoundtripCount `
            -RunDurationSec $RunDurationSec `
            -CoordinatorWorkRepoRoot $resolvedCoordinatorWorkRepoRoot `
            -CoordinatorRunRoot $coordinatorRunRoot `
            -CoordinatorManifestPath $coordinatorManifestPath `
            -CoordinatorWatcherStatusPath $coordinatorWatcherStatusPath `
            -CoordinatorPairStatePath $coordinatorPairStatePath `
            -Message 'child pair runs completed and passed initial success criteria' `
            -GeneratedConfigs @($generatedConfigs) `
            -ProcessRows @($processRows)
    }

    $failedResults = @(
        $pairResults | Where-Object {
            [string]$_.Result.ObservedCounts.WatcherStatus -ne 'stopped' -or
            [int]$_.Result.ObservedCounts.ErrorPresentCount -ne 0 -or
            [int]$_.Result.ObservedCounts.DonePresentCount -lt 2
        }
    )
    if ($failedResults.Count -gt 0) {
        $summary = @(
            foreach ($row in @($failedResults)) {
                '{0}(watcher={1},done={2},error={3})' -f [string]$row.PairId, [string]$row.Result.ObservedCounts.WatcherStatus, [int]$row.Result.ObservedCounts.DonePresentCount, [int]$row.Result.ObservedCounts.ErrorPresentCount
            }
        ) -join '; '
        throw ("parallel pair-scoped drill success criteria not met: {0}" -f $summary)
    }

    $pairRunSummaries = @(
        foreach ($row in @($pairResults)) {
            $pairSummary = @($row.Result.PairResults | Select-Object -First 1)[0]
            [pscustomobject]@{
                PairId = [string]$row.PairId
                InitialTargetId = [string]$row.InitialTargetId
                ConfigPath = [string]$row.ConfigPath
                WorkRepoRoot = [string]$row.WorkRepoRoot
                BookkeepingRoot = [string]$row.BookkeepingRoot
                RunRoot = [string]$row.Result.RunRoot
                WatcherStatus = [string]$row.Result.ObservedCounts.WatcherStatus
                DonePresentCount = [int]$row.Result.ObservedCounts.DonePresentCount
                ErrorPresentCount = [int]$row.Result.ObservedCounts.ErrorPresentCount
                ForwardedStateCount = [int]$row.Result.ObservedCounts.ForwardedStateCount
                RoundtripCount = [int]$pairSummary.RoundtripCount
                CurrentPhase = [string]$pairSummary.CurrentPhase
                NextAction = [string]$pairSummary.NextAction
            }
        }
    )

    if (Test-NonEmptyString $coordinatorRunRoot) {
        $coordinatorManifestPath = Join-Path $coordinatorRunRoot 'manifest.json'
        $coordinatorWatcherStatusPath = Join-Path $coordinatorRunRoot '.state\watcher-status.json'
        $coordinatorPairStatePath = Join-Path $coordinatorRunRoot '.state\pair-state.json'
        $coordinatorForwardedCount = 0
        $coordinatorDoneCount = 0
        $coordinatorErrorCount = 0
        foreach ($summary in @($pairRunSummaries)) {
            $coordinatorForwardedCount += [int]$summary.ForwardedStateCount
            $coordinatorDoneCount += [int]$summary.DonePresentCount
            $coordinatorErrorCount += [int]$summary.ErrorPresentCount
        }

        $coordinatorManifest = [pscustomobject]@{
            SchemaVersion = '1.0.0'
            GeneratedAt = (Get-Date).ToString('o')
            Mode = 'pair-scoped-shared-coordinator'
            BaseConfigPath = $resolvedBaseConfigPath
            CoordinatorWorkRepoRoot = $resolvedCoordinatorWorkRepoRoot
            RunRoot = $coordinatorRunRoot
            PairIds = @($resolvedPairIds)
            PairMaxRoundtripCount = $PairMaxRoundtripCount
            RunDurationSec = $RunDurationSec
            PairRuns = @($pairRunSummaries)
        }
        Write-JsonFile -Path $coordinatorManifestPath -Payload $coordinatorManifest -Depth 12

        $coordinatorWatcherStatus = [pscustomobject]@{
            SchemaVersion = '1.0.0'
            Status = 'stopped'
            StatusReason = 'pair-scoped-shared-coordinator-limit-reached'
            StopCategory = 'expected-limit'
            UpdatedAt = (Get-Date).ToString('o')
            PairIds = @($resolvedPairIds)
            PairMaxRoundtripCount = $PairMaxRoundtripCount
            PairRunCount = @($pairResults).Count
            ForwardedCount = $coordinatorForwardedCount
        }
        Write-JsonFile -Path $coordinatorWatcherStatusPath -Payload $coordinatorWatcherStatus -Depth 8

        $coordinatorPairState = [pscustomobject]@{
            SchemaVersion = '1.0.0'
            GeneratedAt = (Get-Date).ToString('o')
            RunRoot = $coordinatorRunRoot
            PairIds = @($resolvedPairIds)
            DonePresentCount = $coordinatorDoneCount
            ErrorPresentCount = $coordinatorErrorCount
            ForwardedStateCount = $coordinatorForwardedCount
            Pairs = @($pairRunSummaries)
        }
        Write-JsonFile -Path $coordinatorPairStatePath -Payload $coordinatorPairState -Depth 12
    }

    if (Test-NonEmptyString $coordinatorWrapperStatusPath) {
        Write-WrapperStatus `
            -Path $coordinatorWrapperStatusPath `
            -Status 'completed' `
            -BaseConfigPath $resolvedBaseConfigPath `
            -PairIds @($resolvedPairIds) `
            -PairMaxRoundtripCount $PairMaxRoundtripCount `
            -RunDurationSec $RunDurationSec `
            -CoordinatorWorkRepoRoot $resolvedCoordinatorWorkRepoRoot `
            -CoordinatorRunRoot $coordinatorRunRoot `
            -CoordinatorManifestPath $coordinatorManifestPath `
            -CoordinatorWatcherStatusPath $coordinatorWatcherStatusPath `
            -CoordinatorPairStatePath $coordinatorPairStatePath `
            -Message 'pair-scoped parallel wrapper completed successfully' `
            -GeneratedConfigs @($generatedConfigs) `
            -ProcessRows @($processRows) `
            -PairRuns @($pairRunSummaries)
    }
}
catch {
    if (Test-NonEmptyString $coordinatorWrapperStatusPath) {
        Write-WrapperStatus `
            -Path $coordinatorWrapperStatusPath `
            -Status 'failed' `
            -BaseConfigPath $resolvedBaseConfigPath `
            -PairIds @($resolvedPairIds) `
            -PairMaxRoundtripCount $PairMaxRoundtripCount `
            -RunDurationSec $RunDurationSec `
            -CoordinatorWorkRepoRoot $resolvedCoordinatorWorkRepoRoot `
            -CoordinatorRunRoot $coordinatorRunRoot `
            -CoordinatorManifestPath $coordinatorManifestPath `
            -CoordinatorWatcherStatusPath $coordinatorWatcherStatusPath `
            -CoordinatorPairStatePath $coordinatorPairStatePath `
            -Message $_.Exception.Message `
            -GeneratedConfigs @($generatedConfigs) `
            -ProcessRows @($processRows)
    }
    throw
}
finally {
    foreach ($row in @($processRows)) {
        if ($null -ne $row.Process) {
            $row.Process.Dispose()
        }
    }
}

$payload = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    BaseConfigPath = $resolvedBaseConfigPath
    CoordinatorWorkRepoRoot = $resolvedCoordinatorWorkRepoRoot
    CoordinatorRunRoot = $coordinatorRunRoot
    CoordinatorManifestPath = $coordinatorManifestPath
    CoordinatorWatcherStatusPath = $coordinatorWatcherStatusPath
    CoordinatorPairStatePath = $coordinatorPairStatePath
    CoordinatorWrapperStatusPath = $coordinatorWrapperStatusPath
    PairIds = @($resolvedPairIds)
    PairMaxRoundtripCount = $PairMaxRoundtripCount
    RunDurationSec = $RunDurationSec
    GeneratedConfigs = @($generatedConfigs)
    PairRuns = @(
        foreach ($row in @($pairResults)) {
            [pscustomobject]@{
                PairId = [string]$row.PairId
                InitialTargetId = [string]$row.InitialTargetId
                ConfigPath = [string]$row.ConfigPath
                WorkRepoRoot = [string]$row.WorkRepoRoot
                BookkeepingRoot = [string]$row.BookkeepingRoot
                StdOutPath = [string]$row.StdOutPath
                StdErrPath = [string]$row.StdErrPath
                RunRoot = [string]$row.Result.RunRoot
                WatcherStatus = [string]$row.Result.ObservedCounts.WatcherStatus
                DonePresentCount = [int]$row.Result.ObservedCounts.DonePresentCount
                ErrorPresentCount = [int]$row.Result.ObservedCounts.ErrorPresentCount
                ForwardedStateCount = [int]$row.Result.ObservedCounts.ForwardedStateCount
                PairResults = @($row.Result.PairResults)
            }
        }
    )
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
    return
}

$payload
