[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$PairId = 'pair01',
    [string]$SeedTargetId,
    [string]$SeedWorkRepoRoot,
    [string]$SeedReviewInputPath,
    [string]$SeedTaskText,
    [int]$WatcherPollIntervalMs = 1500,
    [int]$WatcherRunDurationSec = 900,
    [int]$WatcherMaxForwardCount = 0,
    [int]$WaitForRouterSeconds = 20,
    [int]$WaitForWatcherSeconds = 20,
    [int]$WaitForFirstHandoffSeconds = 180,
    [int]$WaitForRoundtripSeconds = 180,
    [int]$SeedWaitForPublishSeconds = 180,
    [switch]$ReuseExistingRunRoot,
    [switch]$ForceFreshRouter,
    [switch]$KeepWatcherRunning,
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

function Resolve-FullPath {
    param(
        [Parameter(Mandatory)][string]$PathValue,
        [Parameter(Mandatory)][string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Get-PairDefinition {
    param([Parameter(Mandatory)][string]$PairId)

    $pairs = @{
        pair01 = [pscustomobject]@{ PairId = 'pair01'; TopTargetId = 'target01'; BottomTargetId = 'target05' }
        pair02 = [pscustomobject]@{ PairId = 'pair02'; TopTargetId = 'target02'; BottomTargetId = 'target06' }
        pair03 = [pscustomobject]@{ PairId = 'pair03'; TopTargetId = 'target03'; BottomTargetId = 'target07' }
        pair04 = [pscustomobject]@{ PairId = 'pair04'; TopTargetId = 'target04'; BottomTargetId = 'target08' }
    }

    if (-not $pairs.ContainsKey($PairId)) {
        throw "알 수 없는 pair id입니다: $PairId"
    }

    return $pairs[$PairId]
}

function ConvertTo-CommandArgumentList {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath
    )

    foreach ($entry in $Parameters.GetEnumerator()) {
        $parameterName = '-' + [string]$entry.Key
        $value = $entry.Value

        if ($value -is [switch]) {
            if ($value.IsPresent) {
                $argumentList += $parameterName
            }
            continue
        }

        if ($value -is [bool]) {
            if ($value) {
                $argumentList += $parameterName
            }
            continue
        }

        if ($value -is [System.Array]) {
            $argumentList += $parameterName
            foreach ($item in $value) {
                $argumentList += [string]$item
            }
            continue
        }

        $argumentList += $parameterName
        $argumentList += [string]$value
    }

    return @($argumentList)
}

function Invoke-ScriptAndCaptureOutput {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $powershellPath = Resolve-PowerShellExecutable
    $argumentList = ConvertTo-CommandArgumentList -ScriptPath $ScriptPath -Parameters $Parameters
    $scriptOutput = @()
    foreach ($line in @(& $powershellPath @argumentList 2>&1)) {
        $scriptOutput += [string]$line
    }

    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = ($scriptOutput -join [Environment]::NewLine)
        throw "스크립트 실행 실패 exitCode=$exitCode file=$ScriptPath output=$detail"
    }

    return @($scriptOutput)
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return (ConvertFrom-RelayJsonText -Json $raw)
}

function Test-MutexHeld {
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

        if ($acquired) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
            }

            return $false
        }

        return $true
    }
    finally {
        $mutex.Dispose()
    }
}

function Get-TargetReadyFileCount {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetId
    )

    $target = @($Config.Targets | Where-Object { [string]$_.Id -eq $TargetId } | Select-Object -First 1)
    if (@($target).Length -eq 0) {
        throw "target relay config not found: $TargetId"
    }

    $folder = [string]$target[0].Folder
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        return 0
    }

    return @(
        Get-ChildItem -LiteralPath $folder -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue
    ).Length
}

function Get-TargetRow {
    param(
        $Status,
        [Parameter(Mandatory)][string]$TargetId
    )

    return @($Status.Targets | Where-Object { [string]$_.TargetId -eq $TargetId } | Select-Object -First 1)
}

function New-AcceptanceTargetDiagnostics {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$TargetId
    )

    return [pscustomobject]@{
        TargetId                = $TargetId
        LatestState             = [string]$Row.LatestState
        SourceOutboxState       = [string]$Row.SourceOutboxState
        SourceOutboxReason      = [string]$Row.SourceOutboxReason
        SourceOutboxContractLatestState = [string]$Row.SourceOutboxContractLatestState
        SourceOutboxNextAction  = [string]$Row.SourceOutboxNextAction
        SourceOutboxUpdatedAt   = [string]$Row.SourceOutboxUpdatedAt
        SourceOutboxLastActivityAt = [string]$Row.SourceOutboxLastActivityAt
        DispatchState           = [string]$Row.DispatchState
        DispatchUpdatedAt       = [string]$Row.DispatchUpdatedAt
        SeedSendState           = [string]$Row.SeedSendState
        SubmitState             = [string]$Row.SubmitState
        SubmitReason            = [string]$Row.SubmitReason
        SeedProcessedAt         = [string]$Row.SeedProcessedAt
        SeedFirstAttemptedAt    = [string]$Row.SeedFirstAttemptedAt
        SeedLastAttemptedAt     = [string]$Row.SeedLastAttemptedAt
        SeedAttemptCount        = [int]$Row.SeedAttemptCount
        SeedMaxAttempts         = [int]$Row.SeedMaxAttempts
        SeedNextRetryAt         = [string]$Row.SeedNextRetryAt
        SeedBackoffMs           = [int]$Row.SeedBackoffMs
        SeedRetryReason         = [string]$Row.SeedRetryReason
        ManualAttentionRequired = [bool]$Row.ManualAttentionRequired
    }
}

function Invoke-ShowPairedStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot
    )

    $powershellPath = Resolve-PowerShellExecutable
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'tests\Show-PairedExchangeStatus.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $RunRoot,
        '-AsJson'
    )
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("show-paired-exchange-status failed: " + (($result | Out-String).Trim()))
    }
    return (ConvertFrom-RelayJsonText -Json (($result | Out-String).Trim()))
}

function Invoke-ShowRelayStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath
    )

    $powershellPath = Resolve-PowerShellExecutable
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'show-relay-status.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-AsJson'
    )
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("show-relay-status failed: " + (($result | Out-String).Trim()))
    }
    return (ConvertFrom-RelayJsonText -Json (($result | Out-String).Trim()))
}

function Resolve-PreparedRunRootFromOutput {
    param([Parameter(Mandatory)][string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -match '^prepared pair test root:\s*(.+)$') {
            return [string]$Matches[1].Trim()
        }
    }

    return ''
}

function Wait-ForRouterReady {
    param(
        [Parameter(Mandatory)][string]$RouterMutexName,
        [Parameter(Mandatory)][string]$RouterStatePath,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Read-JsonObject -Path $RouterStatePath
        $mutexHeld = Test-MutexHeld -Name $RouterMutexName
        if ($mutexHeld) {
            $effectiveStatus = 'running-existing'
            $lastError = ''
            if ($null -ne $state) {
                if (Test-NonEmptyString ([string]$state.Status) -and [string]$state.Status -ne 'failed') {
                    $effectiveStatus = [string]$state.Status
                }
                elseif (Test-NonEmptyString ([string]$state.LastError)) {
                    $lastError = [string]$state.LastError
                }
            }

            return [pscustomobject]@{
                Status = $effectiveStatus
                StateFileStatus = if ($null -ne $state) { [string]$state.Status } else { '' }
                LastError = $lastError
            }
        }

        if ($null -ne $state -and [string]$state.Status -eq 'failed' -and -not $mutexHeld) {
            throw ("router start failed: " + [string]$state.LastError)
        }

        Start-Sleep -Milliseconds 300
    }

    throw "router ready timeout: statePath=$RouterStatePath mutex=$RouterMutexName"
}

function Wait-ForWatcherRunning {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastStatus = $null
    while ((Get-Date) -lt $deadline) {
        $lastStatus = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        if ([string]$lastStatus.Watcher.Status -eq 'running') {
            return $lastStatus
        }
        Start-Sleep -Milliseconds 400
    }

    throw ('watcher running timeout: ' + (($lastStatus | ConvertTo-Json -Depth 6) | Out-String))
}

function Write-WatcherStopRequest {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RequestedBy
    )

    $stateRoot = Join-Path $RunRoot '.state'
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }

    $requestId = [guid]::NewGuid().ToString()
    $controlPath = Join-Path $stateRoot 'watcher-control.json'
    [ordered]@{
        SchemaVersion = '1.0.0'
        RequestedAt   = (Get-Date).ToString('o')
        RequestedBy   = $RequestedBy
        Action        = 'stop'
        RunRoot       = $RunRoot
        RequestId     = $requestId
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $controlPath -Encoding UTF8

    return $requestId
}

function Wait-ForWatcherStopped {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $status = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        if (
            [string]$status.Watcher.Status -eq 'stopped' -and
            [string]$status.Watcher.LastHandledRequestId -eq $RequestId -and
            [string]$status.Watcher.LastHandledResult -eq 'stopped'
        ) {
            return $status
        }
        Start-Sleep -Milliseconds 400
    }

    throw "watcher stop timeout: requestId=$RequestId"
}

function Write-AcceptanceReceipt {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)]$Result
    )

    $stateRoot = Join-Path $RunRoot '.state'
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }

    $Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8
}

function Wait-ForLiveAcceptanceOutcome {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$SeedTargetId,
        [Parameter(Mandatory)][string]$PartnerTargetId,
        [Parameter(Mandatory)][int]$InitialSeedInboxCount,
        [Parameter(Mandatory)][int]$InitialPartnerInboxCount,
        [Parameter(Mandatory)][int]$WaitForFirstHandoffSeconds,
        [Parameter(Mandatory)][int]$WaitForRoundtripSeconds
    )

    $firstHandoffDeadline = (Get-Date).AddSeconds([math]::Max(1, $WaitForFirstHandoffSeconds))
    $firstHandoffConfirmed = $false
    $roundtripConfirmed = $false
    $roundtripBaselineSeedInboxCount = 0
    $lastStatus = $null
    $firstHandoffAt = ''
    $roundtripAt = ''
    $acceptanceState = 'waiting'
    $acceptanceReason = ''

    while ($true) {
        $lastStatus = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        $seedRow = @(Get-TargetRow -Status $lastStatus -TargetId $SeedTargetId)
        $partnerRow = @(Get-TargetRow -Status $lastStatus -TargetId $PartnerTargetId)
        if (@($seedRow).Length -eq 0 -or @($partnerRow).Length -eq 0) {
            throw "paired status target rows missing: seed=$SeedTargetId partner=$PartnerTargetId"
        }

        $seedReadyCount = Get-TargetReadyFileCount -Config $Config -TargetId $SeedTargetId
        $partnerReadyCount = Get-TargetReadyFileCount -Config $Config -TargetId $PartnerTargetId

        $seedOutboxState = [string]$seedRow[0].SourceOutboxState
        $partnerOutboxState = [string]$partnerRow[0].SourceOutboxState
        $seedLatestState = [string]$seedRow[0].LatestState

        if (-not $firstHandoffConfirmed) {
            if ($seedOutboxState -eq 'manual-attention-required' -or [bool]$seedRow[0].ManualAttentionRequired) {
                $acceptanceState = 'manual_attention_required'
                $acceptanceReason = if (Test-NonEmptyString ([string]$seedRow[0].SeedRetryReason)) { [string]$seedRow[0].SeedRetryReason } else { 'manual-attention-required' }
                break
            }

            if ($seedOutboxState -in @('submit-unconfirmed', 'target-unresponsive-after-send', 'seed-send-failed', 'seed-send-timeout')) {
                $acceptanceState = $seedOutboxState
                $acceptanceReason = if (Test-NonEmptyString ([string]$seedRow[0].SourceOutboxReason)) { [string]$seedRow[0].SourceOutboxReason } else { $seedOutboxState }
                break
            }

            if ($seedLatestState -eq 'forwarded' -or $partnerReadyCount -gt $InitialPartnerInboxCount) {
                $firstHandoffConfirmed = $true
                $firstHandoffAt = (Get-Date).ToString('o')
                $roundtripBaselineSeedInboxCount = $seedReadyCount
                if ($WaitForRoundtripSeconds -le 0) {
                    $acceptanceState = 'first-handoff-confirmed'
                    $acceptanceReason = 'partner-ready-file-detected'
                    break
                }
                $firstHandoffDeadline = (Get-Date).AddSeconds([math]::Max(1, $WaitForRoundtripSeconds))
            }
        }
        else {
            if ($partnerOutboxState -eq 'manual-attention-required' -or [bool]$partnerRow[0].ManualAttentionRequired) {
                $acceptanceState = 'manual_attention_required'
                $acceptanceReason = if (Test-NonEmptyString ([string]$partnerRow[0].SeedRetryReason)) { [string]$partnerRow[0].SeedRetryReason } else { 'manual-attention-required' }
                break
            }

            if ($partnerOutboxState -in @('submit-unconfirmed', 'target-unresponsive-after-send', 'seed-send-failed', 'seed-send-timeout')) {
                $acceptanceState = $partnerOutboxState
                $acceptanceReason = if (Test-NonEmptyString ([string]$partnerRow[0].SourceOutboxReason)) { [string]$partnerRow[0].SourceOutboxReason } else { $partnerOutboxState }
                break
            }

            if ($seedReadyCount -gt $roundtripBaselineSeedInboxCount) {
                $roundtripConfirmed = $true
                $roundtripAt = (Get-Date).ToString('o')
                $acceptanceState = 'roundtrip-confirmed'
                $acceptanceReason = 'seed-target-received-followup-ready-file'
                break
            }
        }

        if ((Get-Date) -ge $firstHandoffDeadline) {
            if ($firstHandoffConfirmed) {
                $acceptanceState = 'roundtrip-timeout'
                $acceptanceReason = 'seed-target-followup-ready-file-not-detected'
            }
            else {
                $acceptanceState = 'first-handoff-timeout'
                $acceptanceReason = 'partner-ready-file-not-detected'
            }
            break
        }

        Start-Sleep -Milliseconds 1000
    }

    $seedRowFinal = if ($null -ne $lastStatus) { @(Get-TargetRow -Status $lastStatus -TargetId $SeedTargetId) } else { @() }
    $partnerRowFinal = if ($null -ne $lastStatus) { @(Get-TargetRow -Status $lastStatus -TargetId $PartnerTargetId) } else { @() }

    return [pscustomobject]@{
        AcceptanceState = $acceptanceState
        AcceptanceReason = $acceptanceReason
        FirstHandoffConfirmed = $firstHandoffConfirmed
        FirstHandoffAt = $firstHandoffAt
        RoundtripConfirmed = $roundtripConfirmed
        RoundtripAt = $roundtripAt
        InitialSeedInboxCount = $InitialSeedInboxCount
        InitialPartnerInboxCount = $InitialPartnerInboxCount
        FinalSeedInboxCount = (Get-TargetReadyFileCount -Config $Config -TargetId $SeedTargetId)
        FinalPartnerInboxCount = (Get-TargetReadyFileCount -Config $Config -TargetId $PartnerTargetId)
        Diagnostics = [pscustomobject]@{
            Seed = if (@($seedRowFinal).Length -gt 0) { New-AcceptanceTargetDiagnostics -Row $seedRowFinal[0] -TargetId $SeedTargetId } else { $null }
            Partner = if (@($partnerRowFinal).Length -gt 0) { New-AcceptanceTargetDiagnostics -Row $partnerRowFinal[0] -TargetId $PartnerTargetId } else { $null }
        }
        FinalStatus = $lastStatus
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'router\RelayMessageMetadata.ps1')
if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairDefinition = Get-PairDefinition -PairId $PairId
if (-not (Test-NonEmptyString $SeedTargetId)) {
    $SeedTargetId = [string]$pairDefinition.TopTargetId
}

$partnerTargetId = if ([string]$SeedTargetId -eq [string]$pairDefinition.TopTargetId) {
    [string]$pairDefinition.BottomTargetId
}
elseif ([string]$SeedTargetId -eq [string]$pairDefinition.BottomTargetId) {
    [string]$pairDefinition.TopTargetId
}
else {
    throw "seed target does not belong to pair: seed=$SeedTargetId pair=$PairId"
}

$resolvedRunRoot = ''
$startedWatcher = $false
$routerLaunchMode = 'existing'
$watcherLaunchMode = 'existing'
$watcherStopRequestId = ''
$watcherStopError = ''
$routerRestartResult = $null
$result = $null

if (Test-NonEmptyString $RunRoot) {
    $resolvedRunRoot = Resolve-FullPath -PathValue $RunRoot -BasePath $root
}

if ($ReuseExistingRunRoot) {
    if (-not (Test-NonEmptyString $resolvedRunRoot) -or -not (Test-Path -LiteralPath (Join-Path $resolvedRunRoot 'manifest.json') -PathType Leaf)) {
        throw 'ReuseExistingRunRoot를 사용할 때는 manifest.json이 있는 기존 RunRoot가 필요합니다.'
    }
}
else {
    $preparedRunRootExists = $false
    if (Test-NonEmptyString $resolvedRunRoot) {
        $preparedRunRootExists = (Test-Path -LiteralPath (Join-Path $resolvedRunRoot 'manifest.json') -PathType Leaf)
    }

    if ($preparedRunRootExists) {
        throw "RunRoot already exists. Reuse하려면 -ReuseExistingRunRoot를 사용하세요: $resolvedRunRoot"
    }

    $startScriptPath = Join-Path $root 'tests\Start-PairedExchangeTest.ps1'
    $startParams = @{
        ConfigPath    = $resolvedConfigPath
        IncludePairId = @($PairId)
        InitialTargetId = @($SeedTargetId)
    }
    if (Test-NonEmptyString $SeedWorkRepoRoot) {
        $startParams.SeedWorkRepoRoot = $SeedWorkRepoRoot
    }
    if (Test-NonEmptyString $SeedReviewInputPath) {
        $startParams.SeedReviewInputPath = $SeedReviewInputPath
    }
    if (Test-NonEmptyString $SeedTaskText) {
        $startParams.SeedTaskText = $SeedTaskText
    }
    if (Test-NonEmptyString $resolvedRunRoot) {
        $startParams.RunRoot = $resolvedRunRoot
    }
    $startOutput = Invoke-ScriptAndCaptureOutput -ScriptPath $startScriptPath -Parameters $startParams
    $preparedRunRoot = Resolve-PreparedRunRootFromOutput -Lines $startOutput
    if (Test-NonEmptyString $preparedRunRoot) {
        $resolvedRunRoot = $preparedRunRoot
    }
    elseif (-not (Test-NonEmptyString $resolvedRunRoot)) {
        throw 'Start-PairedExchangeTest 출력에서 prepared pair test root를 찾지 못했습니다.'
    }
}

$result = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    ConfigPath = $resolvedConfigPath
    PairId = $PairId
    RunRoot = $resolvedRunRoot
    ReceiptPath = (Join-Path $resolvedRunRoot '.state\live-acceptance-result.json')
    SeedTargetId = $SeedTargetId
    PartnerTargetId = $partnerTargetId
    Stage = 'prepared'
    Router = $null
    Watcher = $null
    Seed = $null
    Outcome = $null
}

Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

try {
    $tmpRoot = Join-Path $root '_tmp'
    if (-not (Test-Path -LiteralPath $tmpRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $routerStdoutLog = Join-Path $tmpRoot ('live-router-' + $timestamp + '.stdout.log')
    $routerStderrLog = ($routerStdoutLog + '.stderr')
    $watcherStdoutLog = Join-Path $tmpRoot ('live-watcher-' + $timestamp + '.stdout.log')
    $watcherStderrLog = ($watcherStdoutLog + '.stderr')

    $routerMutexName = [string]$config.RouterMutexName
    $routerStatePath = [string]$config.RouterStatePath
    $routerLogPath = [string]$config.RouterLogPath

    if ($ForceFreshRouter) {
        $routerLaunchMode = 'restarted'
        $routerRestartRaw = & (Resolve-PowerShellExecutable) `
            '-NoProfile' `
            '-ExecutionPolicy' 'Bypass' `
            '-File' (Join-Path $root 'router\Restart-RouterForConfig.ps1') `
            '-ConfigPath' $resolvedConfigPath `
            '-AsJson'
        if ($LASTEXITCODE -ne 0) {
            throw ("Restart-RouterForConfig failed: " + (($routerRestartRaw | Out-String).Trim()))
        }
        $routerRestartResult = ConvertFrom-RelayJsonText -Json (($routerRestartRaw | Out-String).Trim())
    }
    elseif (-not (Test-MutexHeld -Name $routerMutexName)) {
        $routerLaunchMode = 'started'
        $powershellPath = Resolve-PowerShellExecutable
        $routerArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $root 'router\Start-Router.ps1'),
            '-ConfigPath', $resolvedConfigPath
        )
        Start-Process -FilePath $powershellPath -ArgumentList $routerArguments -PassThru -RedirectStandardOutput $routerStdoutLog -RedirectStandardError $routerStderrLog | Out-Null
    }

    $routerState = Wait-ForRouterReady -RouterMutexName $routerMutexName -RouterStatePath $routerStatePath -TimeoutSeconds $WaitForRouterSeconds
    $relayStatus = Invoke-ShowRelayStatus -Root $root -ResolvedConfigPath $resolvedConfigPath

    $result.Stage = 'router-ready'
    $result.Router = [pscustomobject]@{
        LaunchMode = $routerLaunchMode
        MutexName = $routerMutexName
        Status = [string]$relayStatus.Router.Status
        StateFileStatus = if (Test-NonEmptyString ([string]$routerState.StateFileStatus)) { [string]$routerState.StateFileStatus } else { [string]$relayStatus.Router.Status }
        LastError = [string]$relayStatus.Router.LastError
        MutexHeld = [bool]$relayStatus.Router.MutexHeld
        StatePath = $routerStatePath
        LogPath = $routerLogPath
        StdoutLogPath = if ($null -ne $routerRestartResult -and (Test-NonEmptyString ([string]$routerRestartResult.StdoutLogPath))) { [string]$routerRestartResult.StdoutLogPath } else { $routerStdoutLog }
        StderrLogPath = if ($null -ne $routerRestartResult -and (Test-NonEmptyString ([string]$routerRestartResult.StderrLogPath))) { [string]$routerRestartResult.StderrLogPath } else { $routerStderrLog }
        Restart = $routerRestartResult
    }
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

    $watcherStatusSnapshot = ConvertFrom-RelayJsonText -Json ((& (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -AsJson | Out-String).Trim())
    $watcherMutexName = [string]$watcherStatusSnapshot.Watcher.MutexName
    if (-not (Test-MutexHeld -Name ([string]$watcherMutexName))) {
        $watcherLaunchMode = 'started'
        $startedWatcher = $true
        $powershellPath = Resolve-PowerShellExecutable
        $watchArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
            '-ConfigPath', $resolvedConfigPath,
            '-RunRoot', $resolvedRunRoot,
            '-PollIntervalMs', [string]$WatcherPollIntervalMs,
            '-RunDurationSec', [string]$WatcherRunDurationSec
        )
        if ($WatcherMaxForwardCount -gt 0) {
            $watchArguments += @('-MaxForwardCount', [string]$WatcherMaxForwardCount)
        }
        Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $watcherStdoutLog -RedirectStandardError $watcherStderrLog | Out-Null
    }

    $watcherStatus = Wait-ForWatcherRunning -Root $root -ResolvedConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -TimeoutSeconds $WaitForWatcherSeconds

    $result.Stage = 'watcher-ready'
    $result.Watcher = [pscustomobject]@{
        LaunchMode = $watcherLaunchMode
        StopRequestId = $watcherStopRequestId
        StopError = $watcherStopError
        StdoutLogPath = $watcherStdoutLog
        StderrLogPath = $watcherStderrLog
        Status = $watcherStatus.Watcher
    }
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

    $initialSeedInboxCount = Get-TargetReadyFileCount -Config $config -TargetId $SeedTargetId
    $initialPartnerInboxCount = Get-TargetReadyFileCount -Config $config -TargetId $partnerTargetId

    $seedResultJson = & (Resolve-PowerShellExecutable) `
        '-NoProfile' `
        '-ExecutionPolicy' 'Bypass' `
        '-File' (Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1') `
        '-ConfigPath' $resolvedConfigPath `
        '-RunRoot' $resolvedRunRoot `
        '-TargetId' $SeedTargetId `
        '-WaitForPublishSeconds' ([string]$SeedWaitForPublishSeconds) `
        '-AsJson'
    if ($LASTEXITCODE -ne 0) {
        throw ("Send-InitialPairSeedWithRetry failed: " + (($seedResultJson | Out-String).Trim()))
    }
    $seedResult = ConvertFrom-RelayJsonText -Json (($seedResultJson | Out-String).Trim())

    $result.Stage = 'seed-finished'
    $result.Seed = $seedResult
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

    if (-not [bool]$seedResult.OutboxPublished) {
        $seedFailureReason = "seed publish not detected: finalState=$([string]$seedResult.FinalState) submitState=$([string]$seedResult.SubmitState) reason=$([string]$seedResult.SubmitReason)"
        $result.Stage = 'seed-publish-missing'
        $result.Outcome = [pscustomobject]@{
            AcceptanceState = 'error'
            AcceptanceReason = $seedFailureReason
        }
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        throw $seedFailureReason
    }

    $outcome = Wait-ForLiveAcceptanceOutcome `
        -Root $root `
        -Config $config `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $resolvedRunRoot `
        -SeedTargetId $SeedTargetId `
        -PartnerTargetId $partnerTargetId `
        -InitialSeedInboxCount $initialSeedInboxCount `
        -InitialPartnerInboxCount $initialPartnerInboxCount `
        -WaitForFirstHandoffSeconds $WaitForFirstHandoffSeconds `
        -WaitForRoundtripSeconds $WaitForRoundtripSeconds

    $expectedAcceptanceState = if ($WaitForRoundtripSeconds -gt 0) { 'roundtrip-confirmed' } else { 'first-handoff-confirmed' }
    if ([string]$outcome.AcceptanceState -ne $expectedAcceptanceState) {
        $acceptanceFailureReason = "acceptance outcome mismatch: expected=$expectedAcceptanceState actual=$([string]$outcome.AcceptanceState) reason=$([string]$outcome.AcceptanceReason)"
        $result.Stage = 'acceptance-failed'
        $result.Outcome = $outcome
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        throw $acceptanceFailureReason
    }

    $result.Stage = 'completed'
    $result.Router = [pscustomobject]@{
        LaunchMode = $routerLaunchMode
        MutexName = $routerMutexName
        Status = [string]$relayStatus.Router.Status
        StateFileStatus = if (Test-NonEmptyString ([string]$routerState.StateFileStatus)) { [string]$routerState.StateFileStatus } else { [string]$relayStatus.Router.Status }
        LastError = [string]$relayStatus.Router.LastError
        MutexHeld = [bool]$relayStatus.Router.MutexHeld
        StatePath = $routerStatePath
        LogPath = $routerLogPath
        StdoutLogPath = if ($null -ne $routerRestartResult -and (Test-NonEmptyString ([string]$routerRestartResult.StdoutLogPath))) { [string]$routerRestartResult.StdoutLogPath } else { $routerStdoutLog }
        StderrLogPath = if ($null -ne $routerRestartResult -and (Test-NonEmptyString ([string]$routerRestartResult.StderrLogPath))) { [string]$routerRestartResult.StderrLogPath } else { $routerStderrLog }
        Restart = $routerRestartResult
    }
    $result.Watcher = [pscustomobject]@{
        LaunchMode = $watcherLaunchMode
        StopRequestId = $watcherStopRequestId
        StopError = $watcherStopError
        StdoutLogPath = $watcherStdoutLog
        StderrLogPath = $watcherStderrLog
        Status = $watcherStatus.Watcher
    }
    $result.Seed = $seedResult
    $result.Outcome = $outcome
}
catch {
    if ($null -ne $result) {
        if ([string]$result.Stage -notin @('seed-publish-missing', 'acceptance-failed')) {
            $result.Stage = 'failed'
        }
        $previousOutcome = $result.Outcome
        $result.Outcome = [pscustomobject]@{
            AcceptanceState = 'error'
            AcceptanceReason = $_.Exception.Message
            PreviousOutcome = $previousOutcome
        }
        try {
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        }
        catch {
        }
    }
    throw
}
finally {
    if ($startedWatcher -and -not $KeepWatcherRunning) {
        if (-not (Test-NonEmptyString $watcherStopRequestId)) {
            try {
                $watcherStopRequestId = Write-WatcherStopRequest -RunRoot $resolvedRunRoot -RequestedBy 'tests\Run-LiveVisiblePairAcceptance.ps1'
            }
            catch {
                if (-not (Test-NonEmptyString $watcherStopError)) {
                    $watcherStopError = $_.Exception.Message
                }
            }
        }
        if (Test-NonEmptyString $watcherStopRequestId) {
            try {
                [void](Wait-ForWatcherStopped -Root $root -ResolvedConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -RequestId $watcherStopRequestId -TimeoutSeconds 30)
            }
            catch {
                if (-not (Test-NonEmptyString $watcherStopError)) {
                    $watcherStopError = $_.Exception.Message
                }
            }
        }
    }

    if ($null -ne $result -and $null -ne $result.Watcher) {
        $result.Watcher.StopRequestId = $watcherStopRequestId
        $result.Watcher.StopError = $watcherStopError
        try {
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        }
        catch {
        }
    }
}

Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
}
else {
    $result
}
