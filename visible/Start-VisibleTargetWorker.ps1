[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$TargetId,
    [int]$IdleExitSeconds = 0,
    [switch]$ProcessOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-ConfigValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

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

function Get-ProcessObjectById {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $null
    }

    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Test-ProcessAlive {
    param([int]$ProcessId)

    return ($null -ne (Get-ProcessObjectById -ProcessId $ProcessId))
}

function Stop-ProcessTree {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return
    }

    $taskKillPath = Join-Path $env:WINDIR 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $taskKillPath -PathType Leaf) {
        & $taskKillPath /PID $ProcessId /T /F | Out-Null
        return
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "json file is empty: $Path"
    }

    return ($raw | ConvertFrom-Json)
}

function Get-NormalizedFullPath {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    }
    catch {
        return ([string]$Path).ToLowerInvariant()
    }
}

function Test-ZipArchiveReadable {
    param([Parameter(Mandatory)][string]$Path)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    }
    catch {
    }

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $null = $archive.Entries.Count
        }
        finally {
            if ($null -ne $archive) {
                $archive.Dispose()
            }
        }

        return [pscustomobject]@{
            Ok = $true
            ErrorMessage = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Ok = $false
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Get-FileHashHex {
    param([Parameter(Mandatory)][string]$Path)

    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Test-SourceOutboxPublishReadyValid {
    param([Parameter(Mandatory)]$Paths)

    if (-not (Test-Path -LiteralPath $Paths.SourceSummaryPath -PathType Leaf)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $Paths.SourceReviewZipPath -PathType Leaf)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $Paths.PublishReadyPath -PathType Leaf)) {
        return $false
    }

    try {
        $marker = Read-JsonObject -Path $Paths.PublishReadyPath
    }
    catch {
        return $false
    }

    if ($null -eq $marker) {
        return $false
    }

    foreach ($requiredField in @('SchemaVersion', 'PairId', 'TargetId', 'SummaryPath', 'ReviewZipPath', 'PublishedAt', 'SummarySizeBytes', 'ReviewZipSizeBytes', 'PublishedBy', 'ValidationCompletedAt')) {
        if (-not (Test-NonEmptyString ([string](Get-ConfigValue -Object $marker -Name $requiredField -DefaultValue '')))) {
            return $false
        }
    }

    $validationPassed = Get-ConfigValue -Object $marker -Name 'ValidationPassed' -DefaultValue $null
    if ($validationPassed -isnot [bool]) {
        return $false
    }
    if (-not [bool]$validationPassed) {
        return $false
    }

    if ([string](Get-ConfigValue -Object $marker -Name 'SchemaVersion' -DefaultValue '') -notin @('1.0.0', '1.0')) {
        return $false
    }

    if ([string](Get-ConfigValue -Object $marker -Name 'PublishedBy' -DefaultValue '') -ne 'publish-paired-exchange-artifact.ps1') {
        return $false
    }

    if ((Test-NonEmptyString ([string]$Paths.PairId)) -and ([string](Get-ConfigValue -Object $marker -Name 'PairId' -DefaultValue '') -ne [string]$Paths.PairId)) {
        return $false
    }

    if ((Test-NonEmptyString ([string]$Paths.TargetId)) -and ([string](Get-ConfigValue -Object $marker -Name 'TargetId' -DefaultValue '') -ne [string]$Paths.TargetId)) {
        return $false
    }

    if ((Get-NormalizedFullPath -Path ([string](Get-ConfigValue -Object $marker -Name 'SummaryPath' -DefaultValue ''))) -ne (Get-NormalizedFullPath -Path ([string]$Paths.SourceSummaryPath))) {
        return $false
    }

    if ((Get-NormalizedFullPath -Path ([string](Get-ConfigValue -Object $marker -Name 'ReviewZipPath' -DefaultValue ''))) -ne (Get-NormalizedFullPath -Path ([string]$Paths.SourceReviewZipPath))) {
        return $false
    }

    $summaryItem = Get-Item -LiteralPath $Paths.SourceSummaryPath -ErrorAction Stop
    $zipItem = Get-Item -LiteralPath $Paths.SourceReviewZipPath -ErrorAction Stop
    $readyItem = Get-Item -LiteralPath $Paths.PublishReadyPath -ErrorAction Stop
    $zipValidation = Test-ZipArchiveReadable -Path $Paths.SourceReviewZipPath
    if (-not [bool]$zipValidation.Ok) {
        return $false
    }

    if ($readyItem.LastWriteTimeUtc -lt $summaryItem.LastWriteTimeUtc -or $readyItem.LastWriteTimeUtc -lt $zipItem.LastWriteTimeUtc) {
        return $false
    }

    $summarySizeExpected = 0L
    if (-not [int64]::TryParse([string](Get-ConfigValue -Object $marker -Name 'SummarySizeBytes' -DefaultValue ''), [ref]$summarySizeExpected)) {
        return $false
    }

    $reviewZipSizeExpected = 0L
    if (-not [int64]::TryParse([string](Get-ConfigValue -Object $marker -Name 'ReviewZipSizeBytes' -DefaultValue ''), [ref]$reviewZipSizeExpected)) {
        return $false
    }

    if ($summarySizeExpected -ne [int64]$summaryItem.Length) {
        return $false
    }

    if ($reviewZipSizeExpected -ne [int64]$zipItem.Length) {
        return $false
    }

    $summaryHashExpected = [string](Get-ConfigValue -Object $marker -Name 'SummarySha256' -DefaultValue '')
    if (Test-NonEmptyString $summaryHashExpected) {
        if ((Get-FileHashHex -Path $Paths.SourceSummaryPath).ToLowerInvariant() -ne $summaryHashExpected.ToLowerInvariant()) {
            return $false
        }
    }

    $reviewZipHashExpected = [string](Get-ConfigValue -Object $marker -Name 'ReviewZipSha256' -DefaultValue '')
    if (Test-NonEmptyString $reviewZipHashExpected) {
        if ((Get-FileHashHex -Path $Paths.SourceReviewZipPath).ToLowerInvariant() -ne $reviewZipHashExpected.ToLowerInvariant()) {
            return $false
        }
    }

    return $true
}

function Write-JsonFileAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $tempPath = ($Path + '.tmp')
    $Payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Get-WorkerMutexName {
    param(
        [Parameter(Mandatory)][string]$QueueRoot,
        [Parameter(Mandatory)][string]$TargetKey
    )

    $seed = ($QueueRoot.ToLowerInvariant() + '|' + $TargetKey.ToLowerInvariant())
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return ('Global\VisiblePairWorker_' + $hash)
}

function Get-VisibleWorkerDispatchMutexName {
    param(
        [Parameter(Mandatory)][string]$RunRootPath,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$Scope
    )

    $scopeKey = if ($Scope -eq 'target') { $TargetKey } else { $PairId }
    $hashInput = ('{0}|{1}|{2}' -f $RunRootPath.ToLowerInvariant(), $scopeKey.ToLowerInvariant(), $Scope.ToLowerInvariant())
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return ('Global\VisibleWorkerDispatch_' + $hash)
}

function Acquire-WorkerMutex {
    param([Parameter(Mandatory)][string]$Name)

    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, $Name, [ref]$createdNew)
    $acquired = $false

    try {
        try {
            $acquired = $mutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw "visible worker mutex already held: $Name"
        }

        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Acquire-BlockingMutex {
    param([Parameter(Mandatory)][string]$Name)

    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, $Name, [ref]$createdNew)
    $acquired = $false

    try {
        try {
            $acquired = $mutex.WaitOne()
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw "visible worker dispatch mutex wait failed: $Name"
        }

        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Get-WorkerStatusPath {
    param(
        [Parameter(Mandatory)][string]$StatusRoot,
        [Parameter(Mandatory)][string]$TargetKey
    )

    return (Join-Path (Join-Path $StatusRoot 'workers') ("worker_{0}.json" -f $TargetKey))
}

function Save-WorkerStatus {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$State,
        [string]$CurrentCommandId = '',
        [string]$CurrentRunRoot = '',
        [string]$CurrentPromptFilePath = '',
        [string]$Reason = '',
        [string]$StdOutLogPath = '',
        [string]$StdErrLogPath = '',
        [string]$LastCommandId = '',
        [string]$LastCompletedAt = '',
        [string]$LastFailedAt = '',
        [string]$HeartbeatAt = '',
        [int]$ChildProcessId = 0,
        [double]$ChildCpuSeconds = -1,
        [int64]$ObservedStdOutBytes = -1,
        [int64]$ObservedStdErrBytes = -1,
        [int]$ObservedElapsedSeconds = -1
    )

    $existing = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $existing = Read-JsonObject -Path $Path
        }
        catch {
            $existing = $null
        }
    }

    $payload = [ordered]@{
        SchemaVersion     = '1.0.0'
        TargetId          = $TargetKey
        WorkerPid         = $PID
        State             = $State
        CurrentCommandId  = $CurrentCommandId
        CurrentRunRoot    = $CurrentRunRoot
        CurrentPromptFilePath = $CurrentPromptFilePath
        Reason            = $Reason
        StdOutLogPath     = if (Test-NonEmptyString $StdOutLogPath) { $StdOutLogPath } elseif ($null -ne $existing) { [string]$existing.StdOutLogPath } else { '' }
        StdErrLogPath     = if (Test-NonEmptyString $StdErrLogPath) { $StdErrLogPath } elseif ($null -ne $existing) { [string]$existing.StdErrLogPath } else { '' }
        LastCommandId     = if (Test-NonEmptyString $LastCommandId) { $LastCommandId } elseif ($null -ne $existing) { [string]$existing.LastCommandId } else { '' }
        LastCompletedAt   = if (Test-NonEmptyString $LastCompletedAt) { $LastCompletedAt } elseif ($null -ne $existing) { [string]$existing.LastCompletedAt } else { '' }
        LastFailedAt      = if (Test-NonEmptyString $LastFailedAt) { $LastFailedAt } elseif ($null -ne $existing) { [string]$existing.LastFailedAt } else { '' }
        HeartbeatAt       = if (Test-NonEmptyString $HeartbeatAt) { $HeartbeatAt } elseif ($null -ne $existing) { [string](Get-ConfigValue -Object $existing -Name 'HeartbeatAt' -DefaultValue '') } else { '' }
        ChildProcessId    = if ($ChildProcessId -gt 0) { $ChildProcessId } elseif ($null -ne $existing) { [int](Get-ConfigValue -Object $existing -Name 'ChildProcessId' -DefaultValue 0) } else { 0 }
        ChildCpuSeconds   = if ($ChildCpuSeconds -ge 0) { $ChildCpuSeconds } elseif ($null -ne $existing) { [double](Get-ConfigValue -Object $existing -Name 'ChildCpuSeconds' -DefaultValue -1) } else { -1 }
        ObservedStdOutBytes = if ($ObservedStdOutBytes -ge 0) { $ObservedStdOutBytes } elseif ($null -ne $existing) { [int64](Get-ConfigValue -Object $existing -Name 'ObservedStdOutBytes' -DefaultValue -1) } else { -1 }
        ObservedStdErrBytes = if ($ObservedStdErrBytes -ge 0) { $ObservedStdErrBytes } elseif ($null -ne $existing) { [int64](Get-ConfigValue -Object $existing -Name 'ObservedStdErrBytes' -DefaultValue -1) } else { -1 }
        ObservedElapsedSeconds = if ($ObservedElapsedSeconds -ge 0) { $ObservedElapsedSeconds } elseif ($null -ne $existing) { [int](Get-ConfigValue -Object $existing -Name 'ObservedElapsedSeconds' -DefaultValue -1) } else { -1 }
        UpdatedAt         = (Get-Date).ToString('o')
    }

    Write-JsonFileAtomically -Path $Path -Payload $payload
}

function Get-DispatchStatusPath {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetKey
    )

    return (Join-Path (Join-Path $RunRoot '.state\headless-dispatch') ("dispatch_{0}.json" -f $TargetKey))
}

function Save-DispatchStatus {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload
    )

    $persisted = [ordered]@{
        SchemaVersion = '1.0.0'
    }

    foreach ($property in $Payload.PSObject.Properties) {
        $persisted[[string]$property.Name] = $property.Value
    }

    $persisted.UpdatedAt = (Get-Date).ToString('o')
    Write-JsonFileAtomically -Path $Path -Payload $persisted
}

function Get-CommandTimeoutMilliseconds {
    param([Parameter(Mandatory)]$PairTest)

    $seconds = [int](Get-ConfigValue -Object $PairTest.VisibleWorker -Name 'CommandTimeoutSeconds' -DefaultValue 0)
    if ($seconds -le 0) {
        $seconds = [math]::Max(60, [int](Get-ConfigValue -Object $PairTest.HeadlessExec -Name 'MaxRunSeconds' -DefaultValue 900))
    }

    return ([math]::Max(60, $seconds) * 1000)
}

function Get-OptionalFileLength {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path)) {
        return 0
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 0
    }

    try {
        return [int64](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
    }
    catch {
        return 0
    }
}

function Get-CommandContractPaths {
    param(
        [Parameter(Mandatory)]$Command,
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TargetKey
    )

    $runRoot = [string]$Command.RunRoot
    $pairId = [string]$Command.PairId
    $targetFolder = Join-Path (Join-Path $runRoot $pairId) $TargetKey
    $sourceOutboxPath = Join-Path $targetFolder ([string](Get-ConfigValue -Object $PairTest -Name 'SourceOutboxFolderName' -DefaultValue 'source-outbox'))

    return [pscustomobject]@{
        PairId           = $pairId
        TargetId         = $TargetKey
        TargetFolder     = $targetFolder
        DonePath         = Join-Path $targetFolder ([string](Get-ConfigValue -Object $PairTest.HeadlessExec -Name 'DoneFileName' -DefaultValue 'done.json'))
        ErrorPath        = Join-Path $targetFolder ([string](Get-ConfigValue -Object $PairTest.HeadlessExec -Name 'ErrorFileName' -DefaultValue 'error.json'))
        ResultPath       = Join-Path $targetFolder ([string](Get-ConfigValue -Object $PairTest.HeadlessExec -Name 'ResultFileName' -DefaultValue 'result.json'))
        SourceSummaryPath = Join-Path $sourceOutboxPath ([string](Get-ConfigValue -Object $PairTest -Name 'SourceSummaryFileName' -DefaultValue 'summary.txt'))
        SourceReviewZipPath = Join-Path $sourceOutboxPath ([string](Get-ConfigValue -Object $PairTest -Name 'SourceReviewZipFileName' -DefaultValue 'review.zip'))
        PublishReadyPath = Join-Path $sourceOutboxPath ([string](Get-ConfigValue -Object $PairTest -Name 'PublishReadyFileName' -DefaultValue 'publish.ready.json'))
    }
}

function Test-CommandExecutionSucceeded {
    param([Parameter(Mandatory)]$Paths)

    if (Test-Path -LiteralPath $Paths.DonePath -PathType Leaf) {
        return $true
    }

    if (Test-Path -LiteralPath $Paths.ResultPath -PathType Leaf) {
        try {
            $resultDoc = Read-JsonObject -Path $Paths.ResultPath
            if ([bool](Get-ConfigValue -Object $resultDoc -Name 'ContractArtifactsReady' -DefaultValue $false)) {
                return $true
            }
            if ([bool](Get-ConfigValue -Object $resultDoc -Name 'SourceOutboxReady' -DefaultValue $false)) {
                return [bool](Test-SourceOutboxPublishReadyValid -Paths $Paths)
            }
        }
        catch {
        }
    }

    if (Test-Path -LiteralPath $Paths.PublishReadyPath -PathType Leaf) {
        if (-not (Test-SourceOutboxPublishReadyValid -Paths $Paths)) {
            return $false
        }
        return $true
    }

    if (Test-Path -LiteralPath $Paths.ErrorPath -PathType Leaf) {
        return $false
    }

    return $false
}

function Recover-StaleProcessingCommands {
    param(
        [Parameter(Mandatory)][string]$ProcessingRoot,
        [Parameter(Mandatory)][string]$QueuedRoot,
        [Parameter(Mandatory)][string]$CompletedRoot,
        [Parameter(Mandatory)][string]$FailedRoot,
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$WorkerStatusPath
    )

    $commandTimeoutMs = Get-CommandTimeoutMilliseconds -PairTest $PairTest
    $processingFiles = @(
        Get-ChildItem -LiteralPath $ProcessingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc, Name
    )

    foreach ($processingFile in $processingFiles) {
        $command = $null
        try {
            $command = Read-JsonObject -Path $processingFile.FullName
        }
        catch {
            [void](Move-CommandToArchive -CommandPath $processingFile.FullName -ArchiveRoot $FailedRoot)
            continue
        }

        $commandId = [string](Get-ConfigValue -Object $command -Name 'CommandId' -DefaultValue '')
        $runRoot = [string](Get-ConfigValue -Object $command -Name 'RunRoot' -DefaultValue '')
        $dispatchStatusPath = if (Test-NonEmptyString $runRoot) { Get-DispatchStatusPath -RunRoot $runRoot -TargetKey $TargetKey } else { '' }
        $dispatchDoc = $null
        if (Test-NonEmptyString $dispatchStatusPath -and (Test-Path -LiteralPath $dispatchStatusPath -PathType Leaf)) {
            try {
                $dispatchDoc = Read-JsonObject -Path $dispatchStatusPath
            }
            catch {
                $dispatchDoc = $null
            }
        }

        $commandPaths = Get-CommandContractPaths -Command $command -PairTest $PairTest -TargetKey $TargetKey
        $processId = [int](Get-ConfigValue -Object $dispatchDoc -Name 'ProcessId' -DefaultValue 0)
        $process = Get-ProcessObjectById -ProcessId $processId
        $startedAt = $processingFile.LastWriteTime
        $startedAtText = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StartedAt' -DefaultValue '')
        if (Test-NonEmptyString $startedAtText) {
            try {
                $startedAt = [datetime]::Parse($startedAtText)
            }
            catch {
            }
        }

        if ($null -ne $process) {
            $elapsedMs = [math]::Max(0, [int]((Get-Date) - $startedAt).TotalMilliseconds)
            $remainingMs = [math]::Max(0, ($commandTimeoutMs - $elapsedMs))
            Save-WorkerStatus -Path $WorkerStatusPath -TargetKey $TargetKey -State 'recovering' -CurrentCommandId $commandId -CurrentRunRoot $runRoot -CurrentPromptFilePath ([string](Get-ConfigValue -Object $command -Name 'PromptFilePath' -DefaultValue ''))

            $exited = $false
            if ($remainingMs -gt 0) {
                $exited = $process.WaitForExit($remainingMs)
            }

            if (-not $exited) {
                Stop-ProcessTree -ProcessId $process.Id
                try {
                    $process.WaitForExit(5000) | Out-Null
                }
                catch {
                }
            }

            $completedAt = (Get-Date).ToString('o')
            $succeeded = Test-CommandExecutionSucceeded -Paths $commandPaths
            if ($succeeded) {
                if (Test-NonEmptyString $dispatchStatusPath) {
                    Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
                            TargetId       = $TargetKey
                            RunRoot        = $runRoot
                            ConfigPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'ConfigPath' -DefaultValue '')
                            PromptFilePath = [string](Get-ConfigValue -Object $command -Name 'PromptFilePath' -DefaultValue '')
                            StdOutPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdOutPath' -DefaultValue '')
                            StdErrPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdErrPath' -DefaultValue '')
                            AcceptedAt     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'AcceptedAt' -DefaultValue '')
                            StartedAt      = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StartedAt' -DefaultValue '')
                            CompletedAt    = $completedAt
                            ExitCode       = [int](Get-ConfigValue -Object $dispatchDoc -Name 'ExitCode' -DefaultValue 0)
                            ProcessId      = $processId
                            State          = 'completed'
                            Reason         = 'recovered-completed'
                            CommandId      = $commandId
                            Mode           = [string](Get-ConfigValue -Object $command -Name 'Mode' -DefaultValue '')
                            ExecutionMode  = 'visible-worker'
                        })
                }

                [void](Move-CommandToArchive -CommandPath $processingFile.FullName -ArchiveRoot $CompletedRoot)
                continue
            }

            if (Test-NonEmptyString $dispatchStatusPath) {
                Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
                        TargetId       = $TargetKey
                        RunRoot        = $runRoot
                        ConfigPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'ConfigPath' -DefaultValue '')
                        PromptFilePath = [string](Get-ConfigValue -Object $command -Name 'PromptFilePath' -DefaultValue '')
                        StdOutPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdOutPath' -DefaultValue '')
                        StdErrPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdErrPath' -DefaultValue '')
                        AcceptedAt     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'AcceptedAt' -DefaultValue '')
                        StartedAt      = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StartedAt' -DefaultValue '')
                        CompletedAt    = $completedAt
                        ExitCode       = -1
                        ProcessId      = $processId
                        State          = 'failed'
                        Reason         = if ($exited) { 'recovered-process-exited-without-success-marker' } else { 'recovered-process-timeout' }
                        CommandId      = $commandId
                        Mode           = [string](Get-ConfigValue -Object $command -Name 'Mode' -DefaultValue '')
                        ExecutionMode  = 'visible-worker'
                    })
            }

            [void](Move-CommandToArchive -CommandPath $processingFile.FullName -ArchiveRoot $FailedRoot)
            continue
        }

        if (Test-CommandExecutionSucceeded -Paths $commandPaths) {
            if (Test-NonEmptyString $dispatchStatusPath) {
                Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
                        TargetId       = $TargetKey
                        RunRoot        = $runRoot
                        ConfigPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'ConfigPath' -DefaultValue '')
                        PromptFilePath = [string](Get-ConfigValue -Object $command -Name 'PromptFilePath' -DefaultValue '')
                        StdOutPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdOutPath' -DefaultValue '')
                        StdErrPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdErrPath' -DefaultValue '')
                        AcceptedAt     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'AcceptedAt' -DefaultValue '')
                        StartedAt      = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StartedAt' -DefaultValue '')
                        CompletedAt    = (Get-Date).ToString('o')
                        ExitCode       = [int](Get-ConfigValue -Object $dispatchDoc -Name 'ExitCode' -DefaultValue 0)
                        ProcessId      = $processId
                        State          = 'completed'
                        Reason         = 'recovered-success-marker'
                        CommandId      = $commandId
                        Mode           = [string](Get-ConfigValue -Object $command -Name 'Mode' -DefaultValue '')
                        ExecutionMode  = 'visible-worker'
                    })
            }

            [void](Move-CommandToArchive -CommandPath $processingFile.FullName -ArchiveRoot $CompletedRoot)
            continue
        }

        if (Test-Path -LiteralPath $commandPaths.ErrorPath -PathType Leaf) {
            if (Test-NonEmptyString $dispatchStatusPath) {
                Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
                        TargetId       = $TargetKey
                        RunRoot        = $runRoot
                        ConfigPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'ConfigPath' -DefaultValue '')
                        PromptFilePath = [string](Get-ConfigValue -Object $command -Name 'PromptFilePath' -DefaultValue '')
                        StdOutPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdOutPath' -DefaultValue '')
                        StdErrPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdErrPath' -DefaultValue '')
                        AcceptedAt     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'AcceptedAt' -DefaultValue '')
                        StartedAt      = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StartedAt' -DefaultValue '')
                        CompletedAt    = (Get-Date).ToString('o')
                        ExitCode       = [int](Get-ConfigValue -Object $dispatchDoc -Name 'ExitCode' -DefaultValue -1)
                        ProcessId      = $processId
                        State          = 'failed'
                        Reason         = 'recovered-error-marker'
                        CommandId      = $commandId
                        Mode           = [string](Get-ConfigValue -Object $command -Name 'Mode' -DefaultValue '')
                        ExecutionMode  = 'visible-worker'
                    })
            }

            [void](Move-CommandToArchive -CommandPath $processingFile.FullName -ArchiveRoot $FailedRoot)
            continue
        }

        $requeuedPath = Join-Path $QueuedRoot ([System.IO.Path]::GetFileName($processingFile.FullName))
        Move-Item -LiteralPath $processingFile.FullName -Destination $requeuedPath -Force
        if (Test-NonEmptyString $dispatchStatusPath) {
            Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
                    TargetId       = $TargetKey
                    RunRoot        = $runRoot
                    ConfigPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'ConfigPath' -DefaultValue '')
                    PromptFilePath = [string](Get-ConfigValue -Object $command -Name 'PromptFilePath' -DefaultValue '')
                    StdOutPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdOutPath' -DefaultValue '')
                    StdErrPath     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StdErrPath' -DefaultValue '')
                    AcceptedAt     = [string](Get-ConfigValue -Object $dispatchDoc -Name 'AcceptedAt' -DefaultValue '')
                    StartedAt      = [string](Get-ConfigValue -Object $dispatchDoc -Name 'StartedAt' -DefaultValue '')
                    CompletedAt    = ''
                    ExitCode       = $null
                    ProcessId      = 0
                    State          = 'requeued'
                    Reason         = 'stale-processing-requeued'
                    CommandId      = $commandId
                    Mode           = [string](Get-ConfigValue -Object $command -Name 'Mode' -DefaultValue '')
                    ExecutionMode  = 'visible-worker'
                })
        }
    }
}

function Get-NextQueuedCommandFile {
    param([Parameter(Mandatory)][string]$QueuedRoot)

    return Get-ChildItem -LiteralPath $QueuedRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, Name |
        Select-Object -First 1
}

function Get-WatcherPauseSnapshot {
    param([string]$RunRoot)

    if (-not (Test-NonEmptyString $RunRoot)) {
        return [pscustomobject]@{
            Paused = $false
            StatusState = ''
            ControlAction = ''
            Reason = ''
        }
    }

    $stateRoot = Join-Path $RunRoot '.state'
    $statusPath = Join-Path $stateRoot 'watcher-status.json'
    $controlPath = Join-Path $stateRoot 'watcher-control.json'
    $statusDoc = $null
    $controlDoc = $null
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try {
            $statusDoc = Read-JsonObject -Path $statusPath
        }
        catch {
            $statusDoc = $null
        }
    }
    if (Test-Path -LiteralPath $controlPath -PathType Leaf) {
        try {
            $controlDoc = Read-JsonObject -Path $controlPath
        }
        catch {
            $controlDoc = $null
        }
    }

    $statusState = if ($null -ne $statusDoc) { [string](Get-ConfigValue -Object $statusDoc -Name 'State' -DefaultValue '') } else { '' }
    $controlAction = if ($null -ne $controlDoc) { [string](Get-ConfigValue -Object $controlDoc -Name 'Action' -DefaultValue '') } else { '' }
    $paused = ($statusState -eq 'paused') -or ($controlAction -eq 'pause')
    $reason = if ($controlAction -eq 'pause') { 'watcher-pause-requested' } elseif ($statusState -eq 'paused') { 'watcher-paused' } else { '' }

    return [pscustomobject]@{
        Paused = [bool]$paused
        StatusState = $statusState
        ControlAction = $controlAction
        Reason = $reason
    }
}

function Claim-QueuedCommand {
    param(
        [Parameter(Mandatory)]$QueuedFile,
        [Parameter(Mandatory)][string]$ProcessingRoot
    )

    $claimedPath = Join-Path $ProcessingRoot $QueuedFile.Name
    Move-Item -LiteralPath $QueuedFile.FullName -Destination $claimedPath -Force
    return $claimedPath
}

function Move-CommandToArchive {
    param(
        [Parameter(Mandatory)][string]$CommandPath,
        [Parameter(Mandatory)][string]$ArchiveRoot
    )

    Ensure-Directory -Path $ArchiveRoot
    $destinationPath = Join-Path $ArchiveRoot ([System.IO.Path]::GetFileName($CommandPath))
    Move-Item -LiteralPath $CommandPath -Destination $destinationPath -Force
    return $destinationPath
}

function Invoke-VisibleWorkerCommand {
    param(
        [Parameter(Mandatory)]$Command,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$WorkerStatusPath
    )

    $runRoot = [string]$Command.RunRoot
    $promptFilePath = [string]$Command.PromptFilePath
    $mode = [string]$Command.Mode
    $commandId = [string]$Command.CommandId

    if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) {
        throw "run root not found for visible worker command: $runRoot"
    }
    if (-not (Test-Path -LiteralPath $promptFilePath -PathType Leaf)) {
        throw "prompt file not found for visible worker command: $promptFilePath"
    }

    $dispatchStatusPath = Get-DispatchStatusPath -RunRoot $runRoot -TargetKey $TargetKey
    $dispatchRoot = Split-Path -Parent $dispatchStatusPath
    Ensure-Directory -Path $dispatchRoot
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $logStem = "{0}_{1}_{2}_{3}" -f $mode, $TargetKey, $timestamp, $commandId
    $stdoutLogPath = Join-Path $dispatchRoot ($logStem + '.log')
    $stderrLogPath = ($stdoutLogPath + '.stderr')
    $acceptedAt = (Get-Date).ToString('o')
    $dispatchGateName = Get-VisibleWorkerDispatchMutexName -RunRootPath $runRoot -PairId ([string]$Command.PairId) -TargetKey $TargetKey -Scope ([string]$PairTest.HeadlessExec.MutexScope)
    $dispatchGate = $null
    $commandTimeoutMs = Get-CommandTimeoutMilliseconds -PairTest $PairTest
    $commandPaths = Get-CommandContractPaths -Command $Command -PairTest $PairTest -TargetKey $TargetKey

    Save-WorkerStatus -Path $WorkerStatusPath -TargetKey $TargetKey -State 'running' -CurrentCommandId $commandId -CurrentRunRoot $runRoot -CurrentPromptFilePath $promptFilePath -StdOutLogPath $stdoutLogPath -StdErrLogPath $stderrLogPath

    Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
            TargetId       = $TargetKey
            RunRoot        = $runRoot
            ConfigPath     = $ResolvedConfigPath
            PromptFilePath = $promptFilePath
            StdOutPath     = $stdoutLogPath
            StdErrPath     = $stderrLogPath
            AcceptedAt     = $acceptedAt
            StartedAt      = ''
            CompletedAt    = ''
            ExitCode       = $null
            ProcessId      = 0
            State          = 'accepted'
            Reason         = ''
            CommandId      = $commandId
            Mode           = $mode
            ExecutionMode  = 'visible-worker'
        })

    $powershellPath = Resolve-PowerShellExecutable
    $processArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'invoke-codex-exec-turn.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $runRoot,
        '-TargetId', $TargetKey,
        '-PromptFilePath', $promptFilePath
    )
    Save-WorkerStatus -Path $WorkerStatusPath -TargetKey $TargetKey -State 'waiting-for-dispatch-slot' -CurrentCommandId $commandId -CurrentRunRoot $runRoot -CurrentPromptFilePath $promptFilePath -Reason $dispatchGateName -StdOutLogPath $stdoutLogPath -StdErrLogPath $stderrLogPath
    $dispatchGate = Acquire-BlockingMutex -Name $dispatchGateName
    $startedAt = (Get-Date).ToString('o')
    Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
            TargetId       = $TargetKey
            RunRoot        = $runRoot
            ConfigPath     = $ResolvedConfigPath
            PromptFilePath = $promptFilePath
            StdOutPath     = $stdoutLogPath
            StdErrPath     = $stderrLogPath
            AcceptedAt     = $acceptedAt
            StartedAt      = $startedAt
            CompletedAt    = ''
            ExitCode       = $null
            ProcessId      = 0
            State          = 'running'
            Reason         = ''
            CommandId      = $commandId
            Mode           = $mode
            ExecutionMode  = 'visible-worker'
        })
    Save-WorkerStatus -Path $WorkerStatusPath -TargetKey $TargetKey -State 'running' -CurrentCommandId $commandId -CurrentRunRoot $runRoot -CurrentPromptFilePath $promptFilePath -StdOutLogPath $stdoutLogPath -StdErrLogPath $stderrLogPath

    $process = $null
    try {
        $process = Start-Process -FilePath $powershellPath -ArgumentList $processArguments -PassThru -NoNewWindow -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath
    }
    catch {
        $completedAt = (Get-Date).ToString('o')
        Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
                TargetId       = $TargetKey
                RunRoot        = $runRoot
                ConfigPath     = $ResolvedConfigPath
                PromptFilePath = $promptFilePath
                StdOutPath     = $stdoutLogPath
                StdErrPath     = $stderrLogPath
                AcceptedAt     = $acceptedAt
                StartedAt      = $startedAt
                CompletedAt    = $completedAt
                ExitCode       = $null
                ProcessId      = 0
                State          = 'failed'
                Reason         = $_.Exception.Message
                CommandId      = $commandId
                Mode           = $mode
                ExecutionMode  = 'visible-worker'
            })
        Save-WorkerStatus -Path $WorkerStatusPath -TargetKey $TargetKey -State 'idle' -Reason $_.Exception.Message -LastCommandId $commandId -LastFailedAt $completedAt
        if ($null -ne $dispatchGate) {
            try {
                $dispatchGate.ReleaseMutex()
            }
            catch {
            }
            $dispatchGate.Dispose()
            $dispatchGate = $null
        }
        throw
    }

    Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
            TargetId       = $TargetKey
            RunRoot        = $runRoot
            ConfigPath     = $ResolvedConfigPath
            PromptFilePath = $promptFilePath
            StdOutPath     = $stdoutLogPath
            StdErrPath     = $stderrLogPath
            AcceptedAt     = $acceptedAt
            StartedAt      = $startedAt
            CompletedAt    = ''
            ExitCode       = $null
            ProcessId      = [int]$process.Id
            State          = 'running'
            Reason         = ''
            CommandId      = $commandId
            Mode           = $mode
            ExecutionMode  = 'visible-worker'
        })

    $completedAt = ''
    $commandTimedOut = $false
    $heartbeatIntervalMs = 5000
    $deadlineAt = [DateTime]::UtcNow.AddMilliseconds($commandTimeoutMs)

    while (-not $process.HasExited) {
        $waitMs = [int][Math]::Min($heartbeatIntervalMs, [Math]::Max(0, ($deadlineAt - [DateTime]::UtcNow).TotalMilliseconds))
        if ($waitMs -le 0) {
            $commandTimedOut = $true
            break
        }

        [void]$process.WaitForExit($waitMs)
        $process.Refresh()

        if ($process.HasExited) {
            break
        }

        $heartbeatAt = (Get-Date).ToString('o')
        $elapsedSeconds = [int][Math]::Floor(((Get-Date) - ([datetime]$startedAt)).TotalSeconds)
        $stdoutBytes = Get-OptionalFileLength -Path $stdoutLogPath
        $stderrBytes = Get-OptionalFileLength -Path $stderrLogPath
        $cpuSeconds = -1
        try {
            $cpuSeconds = [double]$process.CPU
        }
        catch {
            $cpuSeconds = -1
        }

        Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
                TargetId       = $TargetKey
                RunRoot        = $runRoot
                ConfigPath     = $ResolvedConfigPath
                PromptFilePath = $promptFilePath
                StdOutPath     = $stdoutLogPath
                StdErrPath     = $stderrLogPath
                AcceptedAt     = $acceptedAt
                StartedAt      = $startedAt
                CompletedAt    = ''
                ExitCode       = $null
                ProcessId      = [int]$process.Id
                State          = 'running'
                Reason         = 'heartbeat'
                CommandId      = $commandId
                Mode           = $mode
                ExecutionMode  = 'visible-worker'
                HeartbeatAt    = $heartbeatAt
                ElapsedSeconds = $elapsedSeconds
                CpuSeconds     = $cpuSeconds
                StdOutBytes    = $stdoutBytes
                StdErrBytes    = $stderrBytes
            })
        Save-WorkerStatus -Path $WorkerStatusPath -TargetKey $TargetKey -State 'running' -CurrentCommandId $commandId -CurrentRunRoot $runRoot -CurrentPromptFilePath $promptFilePath -Reason 'heartbeat' -StdOutLogPath $stdoutLogPath -StdErrLogPath $stderrLogPath -HeartbeatAt $heartbeatAt -ChildProcessId ([int]$process.Id) -ChildCpuSeconds $cpuSeconds -ObservedStdOutBytes $stdoutBytes -ObservedStdErrBytes $stderrBytes -ObservedElapsedSeconds $elapsedSeconds
    }

    if ($commandTimedOut) {
        Stop-ProcessTree -ProcessId $process.Id
        try {
            $process.WaitForExit(5000) | Out-Null
        }
        catch {
        }

        $completedAt = (Get-Date).ToString('o')
        Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
                TargetId       = $TargetKey
                RunRoot        = $runRoot
                ConfigPath     = $ResolvedConfigPath
                PromptFilePath = $promptFilePath
                StdOutPath     = $stdoutLogPath
                StdErrPath     = $stderrLogPath
                AcceptedAt     = $acceptedAt
                StartedAt      = $startedAt
                CompletedAt    = $completedAt
                ExitCode       = -1
                ProcessId      = [int]$process.Id
                State          = 'failed'
                Reason         = 'visible-worker-command-timeout'
                CommandId      = $commandId
                Mode           = $mode
                ExecutionMode  = 'visible-worker'
            })
        Save-WorkerStatus -Path $WorkerStatusPath -TargetKey $TargetKey -State 'idle' -Reason 'visible-worker-command-timeout' -LastCommandId $commandId -LastFailedAt $completedAt
        if ($null -ne $dispatchGate) {
            try {
                $dispatchGate.ReleaseMutex()
            }
            catch {
            }
            $dispatchGate.Dispose()
            $dispatchGate = $null
        }
        throw "visible worker command timed out target=$TargetKey commandId=$commandId timeoutMs=$commandTimeoutMs"
    }

    $completedAt = (Get-Date).ToString('o')
    $state = if ($process.ExitCode -eq 0 -and (Test-CommandExecutionSucceeded -Paths $commandPaths)) { 'completed' } else { 'failed' }
    $reason = if ($state -eq 'completed') {
        ''
    }
    elseif ($process.ExitCode -eq 0) {
        'process-exited-without-success-marker'
    }
    else {
        ('exit-code:' + [string]$process.ExitCode)
    }
    Save-DispatchStatus -Path $dispatchStatusPath -Payload ([pscustomobject]@{
            TargetId       = $TargetKey
            RunRoot        = $runRoot
            ConfigPath     = $ResolvedConfigPath
            PromptFilePath = $promptFilePath
            StdOutPath     = $stdoutLogPath
            StdErrPath     = $stderrLogPath
            AcceptedAt     = $acceptedAt
            StartedAt      = $startedAt
            CompletedAt    = $completedAt
            ExitCode       = [int]$process.ExitCode
            ProcessId      = [int]$process.Id
            State          = $state
            Reason         = $reason
            CommandId      = $commandId
            Mode           = $mode
            ExecutionMode  = 'visible-worker'
        })
    Save-WorkerStatus -Path $WorkerStatusPath -TargetKey $TargetKey -State 'idle' -LastCommandId $commandId -LastCompletedAt $(if ($process.ExitCode -eq 0) { $completedAt } else { '' }) -LastFailedAt $(if ($process.ExitCode -ne 0) { $completedAt } else { '' })
    if ($null -ne $dispatchGate) {
        try {
            $dispatchGate.ReleaseMutex()
        }
        catch {
        }
        $dispatchGate.Dispose()
        $dispatchGate = $null
    }

    if ($process.ExitCode -ne 0) {
        throw "visible worker command failed target=$TargetKey commandId=$commandId exitCode=$($process.ExitCode)"
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
if (-not [bool]$pairTest.VisibleWorker.Enabled) {
    throw "visible worker is not enabled for config: $resolvedConfigPath"
}

$queueRoot = Join-Path ([string]$pairTest.VisibleWorker.QueueRoot) $TargetId
$queuedRoot = Join-Path $queueRoot 'queued'
$processingRoot = Join-Path $queueRoot 'processing'
$completedRoot = Join-Path $queueRoot 'completed'
$failedRoot = Join-Path $queueRoot 'failed'
foreach ($path in @($queuedRoot, $processingRoot, $completedRoot, $failedRoot)) {
    Ensure-Directory -Path $path
}

$workerStatusPath = Get-WorkerStatusPath -StatusRoot ([string]$pairTest.VisibleWorker.StatusRoot) -TargetKey $TargetId
Ensure-Directory -Path (Split-Path -Parent $workerStatusPath)

$effectiveIdleExitSeconds = if ($IdleExitSeconds -gt 0) { $IdleExitSeconds } else { [int]$pairTest.VisibleWorker.IdleExitSeconds }
$pollIntervalMs = [math]::Max(100, [int]$pairTest.VisibleWorker.PollIntervalMs)
$mutexName = Get-WorkerMutexName -QueueRoot $queueRoot -TargetKey $TargetId
$mutex = $null
$idleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $mutex = Acquire-WorkerMutex -Name $mutexName
    Save-WorkerStatus -Path $workerStatusPath -TargetKey $TargetId -State 'idle' -HeartbeatAt (Get-Date).ToString('o')
    Recover-StaleProcessingCommands -ProcessingRoot $processingRoot -QueuedRoot $queuedRoot -CompletedRoot $completedRoot -FailedRoot $failedRoot -PairTest $pairTest -TargetKey $TargetId -WorkerStatusPath $workerStatusPath

    while ($true) {
        $nextCommandFile = Get-NextQueuedCommandFile -QueuedRoot $queuedRoot
        if ($null -eq $nextCommandFile) {
            if ($ProcessOnce -or ($effectiveIdleExitSeconds -gt 0 -and $idleStopwatch.Elapsed.TotalSeconds -ge $effectiveIdleExitSeconds)) {
                break
            }

            Save-WorkerStatus -Path $workerStatusPath -TargetKey $TargetId -State 'idle' -HeartbeatAt (Get-Date).ToString('o')
            Start-Sleep -Milliseconds $pollIntervalMs
            continue
        }

        $queuedCommandPreview = $null
        try {
            $queuedCommandPreview = Read-JsonObject -Path $nextCommandFile.FullName
        }
        catch {
            $queuedCommandPreview = $null
        }
        if ($null -ne $queuedCommandPreview) {
            $queuedRunRoot = [string](Get-ConfigValue -Object $queuedCommandPreview -Name 'RunRoot' -DefaultValue '')
            $pauseSnapshot = Get-WatcherPauseSnapshot -RunRoot $queuedRunRoot
            if ([bool]$pauseSnapshot.Paused) {
                Save-WorkerStatus `
                    -Path $workerStatusPath `
                    -TargetKey $TargetId `
                    -State 'paused' `
                    -CurrentCommandId ([string](Get-ConfigValue -Object $queuedCommandPreview -Name 'CommandId' -DefaultValue '')) `
                    -CurrentRunRoot $queuedRunRoot `
                    -CurrentPromptFilePath ([string](Get-ConfigValue -Object $queuedCommandPreview -Name 'PromptFilePath' -DefaultValue '')) `
                    -Reason ([string]$pauseSnapshot.Reason)
                Start-Sleep -Milliseconds $pollIntervalMs
                continue
            }
        }

        $idleStopwatch.Restart()
        $claimedPath = $null
        try {
            $claimedPath = Claim-QueuedCommand -QueuedFile $nextCommandFile -ProcessingRoot $processingRoot
        }
        catch {
            Start-Sleep -Milliseconds 100
            continue
        }

        $command = $null
        try {
            $command = Read-JsonObject -Path $claimedPath
            if ([string]$command.TargetId -ne $TargetId) {
                throw "queued command target mismatch: expected=$TargetId actual=$([string]$command.TargetId)"
            }

            Invoke-VisibleWorkerCommand -Command $command -Root $root -ResolvedConfigPath $resolvedConfigPath -PairTest $pairTest -TargetKey $TargetId -WorkerStatusPath $workerStatusPath
            [void](Move-CommandToArchive -CommandPath $claimedPath -ArchiveRoot $completedRoot)
        }
        catch {
            if (Test-Path -LiteralPath $claimedPath -PathType Leaf) {
                [void](Move-CommandToArchive -CommandPath $claimedPath -ArchiveRoot $failedRoot)
            }
            Save-WorkerStatus `
                -Path $workerStatusPath `
                -TargetKey $TargetId `
                -State 'idle' `
                -Reason $_.Exception.Message `
                -LastCommandId $(if ($null -ne $command) { [string](Get-ConfigValue -Object $command -Name 'CommandId' -DefaultValue '') } else { '' }) `
                -LastFailedAt (Get-Date).ToString('o')
            [Console]::Error.WriteLine(($_ | Out-String).TrimEnd())
        }

        if ($ProcessOnce) {
            break
        }
    }
}
finally {
    Save-WorkerStatus -Path $workerStatusPath -TargetKey $TargetId -State 'stopped'
    if ($null -ne $mutex) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }
        $mutex.Dispose()
    }
}
