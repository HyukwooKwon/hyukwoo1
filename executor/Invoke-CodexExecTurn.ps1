[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [string]$PromptFilePath,
    [int]$TimeoutSec = 0,
    [switch]$DryRun,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
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

function Test-NormalizedPathMatch {
    param(
        [string]$Left,
        [string]$Right
    )

    if (-not (Test-NonEmptyString $Left) -or -not (Test-NonEmptyString $Right)) {
        return $false
    }

    return ((Get-NormalizedFullPath -Path $Left) -eq (Get-NormalizedFullPath -Path $Right))
}

function Test-RemovableStaleError {
    param(
        $ErrorDoc = $null,
        [string]$RequestPath = '',
        [string]$SummaryPath = '',
        [string]$SourceSummaryPath = '',
        [string]$SourceReviewZipPath = '',
        [string]$PublishReadyPath = ''
    )

    if ($null -eq $ErrorDoc) {
        return $false
    }

    $reason = [string](Get-ConfigValue -Object $ErrorDoc -Name 'Reason' -DefaultValue '')
    if ($reason -notin @('summary-missing-after-exec', 'summary-stale-after-exec', 'zip-missing-after-exec', 'zip-stale-after-exec', 'source-outbox-incomplete-after-exec')) {
        return $false
    }

    foreach ($pair in @(
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'RequestPath' -DefaultValue ''), $RequestPath),
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'SummaryPath' -DefaultValue ''), $SummaryPath),
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'SourceSummaryPath' -DefaultValue ''), $SourceSummaryPath),
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'SourceReviewZipPath' -DefaultValue ''), $SourceReviewZipPath),
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'PublishReadyPath' -DefaultValue ''), $PublishReadyPath)
        )) {
        if (Test-NormalizedPathMatch -Left ([string]$pair[0]) -Right ([string]$pair[1])) {
            return $true
        }
    }

    return $false
}

function Format-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return ('"' + $escaped + '"')
}

function Join-ProcessArguments {
    param([Parameter(Mandatory)][string[]]$Arguments)

    return (($Arguments | ForEach-Object { Format-ProcessArgument -Value $_ }) -join ' ')
}

function Get-PairExecMutexName {
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
    return ('Global\RelayPairExec_' + $hash)
}

function Acquire-Mutex {
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
            throw "pair exec mutex already held: $Name"
        }

        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Get-LatestZipFile {
    param([Parameter(Mandatory)][string]$ReviewFolderPath)

    if (-not (Test-Path -LiteralPath $ReviewFolderPath)) {
        return $null
    }

    return (Get-ChildItem -LiteralPath $ReviewFolderPath -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, Name -Descending |
        Select-Object -First 1)
}

function Get-FileState {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [pscustomobject]@{
        Path             = $item.FullName
        LastWriteTimeUtc = $item.LastWriteTimeUtc
        Length           = if ($item.PSIsContainer) { 0 } else { [int64]$item.Length }
    }
}

function Test-FileFresh {
    param(
        [string]$Path,
        $Baseline = $null,
        [DateTime]$StartedAtUtc = [DateTime]::MinValue
    )

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.LastWriteTimeUtc -ge $StartedAtUtc) {
        return $true
    }

    if ($null -eq $Baseline) {
        return $false
    }

    if (-not (Test-NormalizedPathMatch -Left ([string]$Baseline.Path) -Right $item.FullName)) {
        return $true
    }

    $itemLength = if ($item.PSIsContainer) { 0 } else { [int64]$item.Length }
    return (($item.LastWriteTimeUtc.Ticks -ne [int64]$Baseline.LastWriteTimeUtc.Ticks) -or
        ($itemLength -ne [int64]$Baseline.Length))
}

function Test-SummaryReadyForZip {
    param(
        [Parameter(Mandatory)][string]$SummaryPath,
        $ZipFile = $null,
        [double]$MaxSkewSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $SummaryPath)) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'summary-missing'
        }
    }

    if ($null -eq $ZipFile) {
        return [pscustomobject]@{
            IsReady = $true
            Reason  = ''
        }
    }

    $summaryItem = Get-Item -LiteralPath $SummaryPath -ErrorAction Stop
    $deltaSeconds = ($ZipFile.LastWriteTimeUtc - $summaryItem.LastWriteTimeUtc).TotalSeconds
    if ($deltaSeconds -gt $MaxSkewSeconds) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'summary-stale'
        }
    }

    return [pscustomobject]@{
        IsReady = $true
        Reason  = ''
    }
}

function Resolve-LaunchCommand {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $command = Get-Command -Name $Executable -ErrorAction Stop | Select-Object -First 1
    $resolvedPath = if (Test-NonEmptyString ([string]$command.Source)) { [string]$command.Source } elseif (Test-NonEmptyString ([string]$command.Path)) { [string]$command.Path } else { [string]$Executable }
    $extension = [System.IO.Path]::GetExtension($resolvedPath)

    if ($extension -ieq '.ps1') {
        $hostPath = ''
        foreach ($hostName in @('pwsh.exe', 'powershell.exe')) {
            $hostCommand = Get-Command -Name $hostName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $hostCommand) {
                continue
            }

            if (Test-NonEmptyString ([string]$hostCommand.Source)) {
                $hostPath = [string]$hostCommand.Source
                break
            }
            if (Test-NonEmptyString ([string]$hostCommand.Path)) {
                $hostPath = [string]$hostCommand.Path
                break
            }

            $hostPath = $hostName
            break
        }

        if (-not (Test-NonEmptyString $hostPath)) {
            throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
        }

        return [pscustomobject]@{
            FilePath  = $hostPath
            Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolvedPath) + $Arguments
            Resolved  = $resolvedPath
        }
    }

    return [pscustomobject]@{
        FilePath  = $resolvedPath
        Arguments = @($Arguments)
        Resolved  = $resolvedPath
    }
}

function Invoke-ProcessWithStdin {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$InputText,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()

        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                $process.Kill()
            }
            catch {
            }

            throw "codex exec timed out after $TimeoutMilliseconds ms"
        }

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StdOut   = ''
            StdErr   = ''
        }
    }
    finally {
        $process.Dispose()
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$resolvedRunRoot = Resolve-PairRunRootPath -Root $root -RunRoot $RunRoot -PairTest $pairTest
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "manifest not found: $manifestPath"
}

$manifest = Read-JsonObject -Path $manifestPath
$targetEntry = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq [string]$TargetId } | Select-Object -First 1)
if ($targetEntry.Count -eq 0) {
    throw "target not found in manifest: $TargetId"
}
$targetEntry = $targetEntry[0]

$targetFolder = [string]$targetEntry.TargetFolder
$contract = Get-TargetContractPaths -PairTest $pairTest -TargetEntry $targetEntry
$requestPath = [string]$contract.RequestPath
$request = if (Test-Path -LiteralPath $requestPath) { Read-JsonObject -Path $requestPath } else { $null }
if ($null -eq $request) {
    throw "request file not found or empty: $requestPath"
}
$contract = Get-TargetContractPaths -PairTest $pairTest -TargetEntry $targetEntry -Request $request

$effectivePromptSourcePath = ''
if (Test-NonEmptyString $PromptFilePath) {
    $effectivePromptSourcePath = (Resolve-Path -LiteralPath $PromptFilePath).Path
}
elseif (Test-NonEmptyString ([string]$request.MessagePath) -and (Test-Path -LiteralPath ([string]$request.MessagePath))) {
    $effectivePromptSourcePath = [string]$request.MessagePath
}
elseif (Test-NonEmptyString ([string]$request.InstructionPath) -and (Test-Path -LiteralPath ([string]$request.InstructionPath))) {
    $effectivePromptSourcePath = [string]$request.InstructionPath
}
else {
    throw "no prompt source found for target: $TargetId"
}

$promptText = Get-Content -LiteralPath $effectivePromptSourcePath -Raw -Encoding UTF8
$headlessPromptPath = if (Test-NonEmptyString ([string]$request.HeadlessPromptFilePath)) { [string]$request.HeadlessPromptFilePath } else { Join-Path $targetFolder ([string]$pairTest.HeadlessExec.PromptFileName) }
$outputLastMessagePath = if (Test-NonEmptyString ([string]$request.OutputLastMessagePath)) { [string]$request.OutputLastMessagePath } else { Join-Path $targetFolder ([string]$pairTest.HeadlessExec.OutputLastMessageFileName) }
$reviewFolderPath = [string]$contract.ReviewFolderPath
$donePath = [string]$contract.DonePath
$errorPath = [string]$contract.ErrorPath
$resultPath = [string]$contract.ResultPath
$summaryPath = [string]$contract.SummaryPath
$sourceOutboxPath = if (Test-NonEmptyString ([string]$request.SourceOutboxPath)) { [string]$request.SourceOutboxPath } else { Join-Path $targetFolder ([string]$pairTest.SourceOutboxFolderName) }
$sourceSummaryPath = if (Test-NonEmptyString ([string]$request.SourceSummaryPath)) { [string]$request.SourceSummaryPath } else { Join-Path $sourceOutboxPath ([string]$pairTest.SourceSummaryFileName) }
$sourceReviewZipPath = if (Test-NonEmptyString ([string]$request.SourceReviewZipPath)) { [string]$request.SourceReviewZipPath } else { Join-Path $sourceOutboxPath ([string]$pairTest.SourceReviewZipFileName) }
$publishReadyPath = if (Test-NonEmptyString ([string]$request.PublishReadyPath)) { [string]$request.PublishReadyPath } else { Join-Path $sourceOutboxPath ([string]$pairTest.PublishReadyFileName) }

$timeoutSeconds = if ($TimeoutSec -gt 0) { $TimeoutSec } else { [int]$pairTest.HeadlessExec.MaxRunSeconds }
$timeoutMilliseconds = [Math]::Max(1, ($timeoutSeconds * 1000))
$argumentList = @([string[]]$pairTest.HeadlessExec.Arguments)
$argumentList += @('-C', $targetFolder, '-o', $outputLastMessagePath, '--color', 'never')
$launchResolveError = ''
$launchCommand = $null
if ($DryRun) {
    try {
        $launchCommand = Resolve-LaunchCommand -Executable ([string]$pairTest.HeadlessExec.CodexExecutable) -Arguments $argumentList
    }
    catch {
        $launchResolveError = $_.Exception.Message
        $launchCommand = [pscustomobject]@{
            FilePath  = ''
            Arguments = @($argumentList)
            Resolved  = ''
        }
    }
}
else {
    if (-not [bool]$pairTest.HeadlessExec.Enabled) {
        throw "headless exec is disabled in config: $resolvedConfigPath"
    }
    $launchCommand = Resolve-LaunchCommand -Executable ([string]$pairTest.HeadlessExec.CodexExecutable) -Arguments $argumentList
}
$mutexScope = [string]$pairTest.HeadlessExec.MutexScope
$pairId = [string]$targetEntry.PairId
$mutexName = Get-PairExecMutexName -RunRootPath $resolvedRunRoot -PairId $pairId -TargetKey ([string]$targetEntry.TargetId) -Scope $mutexScope

$status = [ordered]@{
    ConfigPath            = $resolvedConfigPath
    RunRoot               = $resolvedRunRoot
    PairId                = $pairId
    TargetId              = [string]$targetEntry.TargetId
    PartnerTargetId       = [string]$targetEntry.PartnerTargetId
    TargetFolder          = $targetFolder
    RequestPath           = $requestPath
    SummaryPath           = $summaryPath
    ReviewFolderPath      = $reviewFolderPath
    PromptSourcePath      = $effectivePromptSourcePath
    HeadlessPromptPath    = $headlessPromptPath
    OutputLastMessagePath = $outputLastMessagePath
    ResultPath            = $resultPath
    DonePath              = $donePath
    ErrorPath             = $errorPath
    MutexName             = $mutexName
    CodexExecutable       = [string]$pairTest.HeadlessExec.CodexExecutable
    CodexResolvedPath     = [string]$launchCommand.Resolved
    LaunchFilePath        = [string]$launchCommand.FilePath
    ArgumentList          = @($launchCommand.Arguments)
    LaunchResolveError    = $launchResolveError
    HeadlessExecEnabled   = [bool]$pairTest.HeadlessExec.Enabled
    TimeoutSec            = $timeoutSeconds
    DryRun                = [bool]$DryRun
    ExitCode              = $null
    CompletedAt           = ''
    LatestZipPath         = ''
    SummaryPresent        = $false
    SummaryFresh          = $false
    LatestZipFresh        = $false
    ContractArtifactsReady = $false
    ContractArtifactsReadyReason = ''
    SourceOutboxReady     = $false
    Error                 = ''
}

if ($DryRun) {
    $status.CompletedAt = (Get-Date).ToString('o')
    if ($AsJson) {
        [pscustomobject]$status | ConvertTo-Json -Depth 8
    }
    else {
        [pscustomobject]$status
    }
    return
}

$mutex = $null
try {
    $preExecSummaryState = Get-FileState -Path $summaryPath
    $preExecLatestZip = Get-LatestZipFile -ReviewFolderPath $reviewFolderPath
    $preExecLatestZipState = if ($null -ne $preExecLatestZip) { Get-FileState -Path $preExecLatestZip.FullName } else { $null }
    Ensure-Directory -Path $targetFolder
    [System.IO.File]::WriteAllText($headlessPromptPath, $promptText, (New-Utf8NoBomEncoding))
    $mutex = Acquire-Mutex -Name $mutexName
    $executionStartedAtUtc = (Get-Date).ToUniversalTime()
    $invocationResult = Invoke-ProcessWithStdin -FilePath ([string]$launchCommand.FilePath) -Arguments @($launchCommand.Arguments) -WorkingDirectory $targetFolder -InputText $promptText -TimeoutMilliseconds $timeoutMilliseconds
    $status.ExitCode = [int]$invocationResult.ExitCode
    $status.CompletedAt = (Get-Date).ToString('o')

    $latestZip = Get-LatestZipFile -ReviewFolderPath $reviewFolderPath
    $status.LatestZipPath = if ($null -ne $latestZip) { $latestZip.FullName } else { '' }
    $status.SummaryPresent = [bool](Test-Path -LiteralPath $summaryPath)
    $summaryReadiness = Test-SummaryReadyForZip -SummaryPath $summaryPath -ZipFile $latestZip -MaxSkewSeconds ([double]$pairTest.SummaryZipMaxSkewSeconds)
    $status.SummaryFresh = [bool](Test-FileFresh -Path $summaryPath -Baseline $preExecSummaryState -StartedAtUtc $executionStartedAtUtc)
    $status.LatestZipFresh = if ($null -ne $latestZip) {
        [bool](Test-FileFresh -Path $latestZip.FullName -Baseline $preExecLatestZipState -StartedAtUtc $executionStartedAtUtc)
    }
    else {
        $false
    }
    $sourceSummaryPresent = [bool](Test-Path -LiteralPath $sourceSummaryPath)
    $sourceReviewZipPresent = [bool](Test-Path -LiteralPath $sourceReviewZipPath)
    $publishReadyPresent = [bool](Test-Path -LiteralPath $publishReadyPath)
    $status.SourceOutboxReady = $sourceSummaryPresent -and $sourceReviewZipPresent -and $publishReadyPresent
    $status.ContractArtifactsReadyReason = if ($status.ExitCode -ne 0) {
        'nonzero-exit'
    }
    elseif (-not $status.SummaryPresent) {
        'summary-missing'
    }
    elseif (-not (Test-NonEmptyString $status.LatestZipPath)) {
        'zip-missing'
    }
    elseif (-not $status.SummaryFresh) {
        'summary-not-fresh'
    }
    elseif (-not $status.LatestZipFresh) {
        'zip-not-fresh'
    }
    elseif (-not [bool]$summaryReadiness.IsReady) {
        [string]$summaryReadiness.Reason
    }
    else {
        'ready'
    }
    $contractArtifactsReady = ([string]$status.ContractArtifactsReadyReason -eq 'ready')
    $status.ContractArtifactsReady = [bool]$contractArtifactsReady

    $resultPayload = [ordered]@{
        CompletedAt           = $status.CompletedAt
        PairId                = $pairId
        TargetId              = [string]$targetEntry.TargetId
        PartnerTargetId       = [string]$targetEntry.PartnerTargetId
        ExitCode              = [int]$invocationResult.ExitCode
        PromptSourcePath      = $effectivePromptSourcePath
        HeadlessPromptPath    = $headlessPromptPath
        OutputLastMessagePath = $outputLastMessagePath
        SummaryPath           = $summaryPath
        LatestZipPath         = $status.LatestZipPath
        SourceSummaryPath     = $sourceSummaryPath
        SourceReviewZipPath   = $sourceReviewZipPath
        PublishReadyPath      = $publishReadyPath
        SummaryPresent        = [bool]$status.SummaryPresent
        SummaryFresh          = [bool]$status.SummaryFresh
        LatestZipFresh        = [bool]$status.LatestZipFresh
        SourceSummaryPresent  = [bool]$sourceSummaryPresent
        SourceReviewZipPresent = [bool]$sourceReviewZipPresent
        PublishReadyPresent   = [bool]$publishReadyPresent
        ContractArtifactsReady = [bool]$contractArtifactsReady
        ContractArtifactsReadyReason = [string]$status.ContractArtifactsReadyReason
        SourceOutboxReady     = [bool]$status.SourceOutboxReady
        StdOutChars           = if (Test-NonEmptyString $invocationResult.StdOut) { $invocationResult.StdOut.Length } else { 0 }
        StdErrChars           = if (Test-NonEmptyString $invocationResult.StdErr) { $invocationResult.StdErr.Length } else { 0 }
    }
    $resultPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    if ($contractArtifactsReady) {
        $donePayload = [ordered]@{
            CompletedAt           = $status.CompletedAt
            PairId                = $pairId
            TargetId              = [string]$targetEntry.TargetId
            PartnerTargetId       = [string]$targetEntry.PartnerTargetId
            RequestPath           = $requestPath
            PromptSourcePath      = $effectivePromptSourcePath
            HeadlessPromptPath    = $headlessPromptPath
            OutputLastMessagePath = $outputLastMessagePath
            SummaryPath           = $summaryPath
            LatestZipPath         = $status.LatestZipPath
            ResultPath            = $resultPath
        }
        $donePayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $donePath -Encoding UTF8
        if (Test-Path -LiteralPath $errorPath) {
            $existingError = $null
            try {
                $existingError = Read-JsonObject -Path $errorPath
            }
            catch {
                $existingError = $null
            }
            if (Test-RemovableStaleError -ErrorDoc $existingError -RequestPath $requestPath -SummaryPath $summaryPath -SourceSummaryPath $sourceSummaryPath -SourceReviewZipPath $sourceReviewZipPath -PublishReadyPath $publishReadyPath) {
                Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    elseif (($status.ExitCode -eq 0) -and $status.SourceOutboxReady) {
        # source-outbox mode publishes asynchronously after this exec returns,
        # so root contract summary/reviewfile are not expected yet.
        $donePayload = [ordered]@{
            CompletedAt            = $status.CompletedAt
            Mode                   = 'source-outbox-publish'
            PairId                 = $pairId
            TargetId               = [string]$targetEntry.TargetId
            PartnerTargetId        = [string]$targetEntry.PartnerTargetId
            RequestPath            = $requestPath
            PromptSourcePath       = $effectivePromptSourcePath
            HeadlessPromptPath     = $headlessPromptPath
            OutputLastMessagePath  = $outputLastMessagePath
            SummarySourcePath      = $sourceSummaryPath
            ReviewZipSourcePath    = $sourceReviewZipPath
            PublishReadyPath       = $publishReadyPath
            SummaryPath            = $summaryPath
            LatestZipPath          = $status.LatestZipPath
            ResultPath             = $resultPath
            ContractArtifactsReady = [bool]$contractArtifactsReady
            ContractArtifactsReadyReason = [string]$status.ContractArtifactsReadyReason
        }
        $donePayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $donePath -Encoding UTF8
        if (Test-Path -LiteralPath $errorPath) {
            $existingError = $null
            try {
                $existingError = Read-JsonObject -Path $errorPath
            }
            catch {
                $existingError = $null
            }
            if (Test-RemovableStaleError -ErrorDoc $existingError -RequestPath $requestPath -SummaryPath $summaryPath -SourceSummaryPath $sourceSummaryPath -SourceReviewZipPath $sourceReviewZipPath -PublishReadyPath $publishReadyPath) {
                Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        $status.Error = if ($status.ExitCode -ne 0) {
            'codex-exec-nonzero-exit'
        }
        elseif ($sourceSummaryPresent -or $sourceReviewZipPresent -or $publishReadyPresent) {
            'source-outbox-incomplete-after-exec'
        }
        elseif (-not $status.SummaryPresent) {
            'summary-missing-after-exec'
        }
        elseif (-not $status.SummaryFresh -or [string]$status.ContractArtifactsReadyReason -eq 'summary-stale') {
            'summary-stale-after-exec'
        }
        elseif (-not (Test-NonEmptyString $status.LatestZipPath)) {
            'zip-missing-after-exec'
        }
        elseif (-not $status.LatestZipFresh) {
            'zip-stale-after-exec'
        }
        else {
            'zip-missing-after-exec'
        }
        $errorPayload = [ordered]@{
            FailedAt         = $status.CompletedAt
            PairId           = $pairId
            TargetId         = [string]$targetEntry.TargetId
            PartnerTargetId  = [string]$targetEntry.PartnerTargetId
            Reason           = $status.Error
            ExitCode         = $status.ExitCode
            RequestPath      = $requestPath
            PromptSourcePath = $effectivePromptSourcePath
            SummaryPath      = $summaryPath
            LatestZipPath    = $status.LatestZipPath
            SummaryFresh     = [bool]$status.SummaryFresh
            LatestZipFresh   = [bool]$status.LatestZipFresh
            ContractArtifactsReadyReason = [string]$status.ContractArtifactsReadyReason
            SourceSummaryPath = $sourceSummaryPath
            SourceReviewZipPath = $sourceReviewZipPath
            PublishReadyPath = $publishReadyPath
            ResultPath       = $resultPath
        }
        $errorPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $errorPath -Encoding UTF8
        if (Test-Path -LiteralPath $donePath) {
            Remove-Item -LiteralPath $donePath -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    $status.CompletedAt = (Get-Date).ToString('o')
    $status.Error = $_.Exception.Message
    $errorPayload = [ordered]@{
        FailedAt         = $status.CompletedAt
        PairId           = $pairId
        TargetId         = [string]$targetEntry.TargetId
        PartnerTargetId  = [string]$targetEntry.PartnerTargetId
        Reason           = $status.Error
        RequestPath      = $requestPath
        PromptSourcePath = $effectivePromptSourcePath
        SummaryPath      = $summaryPath
        ResultPath       = $resultPath
    }
    $errorPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $errorPath -Encoding UTF8
    if (Test-Path -LiteralPath $donePath) {
        Remove-Item -LiteralPath $donePath -Force -ErrorAction SilentlyContinue
    }
    throw
}
finally {
    if ($null -ne $mutex) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }

        $mutex.Dispose()
    }
}

if ($AsJson) {
    [pscustomobject]$status | ConvertTo-Json -Depth 8
}
else {
    [pscustomobject]$status
}
