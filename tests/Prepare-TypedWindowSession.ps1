[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$PairId,
    [Parameter(Mandatory)][string]$TargetId,
    [switch]$AsJson
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

    if ($null -eq $Object) { return $DefaultValue }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $DefaultValue
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $DefaultValue
}

function Import-ConfigDataFile {
    param([Parameter(Mandatory)][string]$Path)
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $importCommand = Get-Command -Name Import-PowerShellDataFile -ErrorAction SilentlyContinue
    if ($null -ne $importCommand) {
        return Import-PowerShellDataFile -Path $resolvedPath
    }

    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
    return [scriptblock]::Create($raw).InvokeReturnAsIs()
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "json file is empty: $Path"
    }
    return ($raw | ConvertFrom-Json)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Get-TypedWindowSessionRoot {
    param([Parameter(Mandatory)]$Config)
    $runtimeRoot = [string](Get-ConfigValue -Object $Config -Name 'RuntimeRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $runtimeRoot)) {
        $runtimeRoot = Join-Path $script:root 'runtime\bottest-live-visible'
    }

    $sessionRoot = Join-Path $runtimeRoot 'typed-window-session'
    Ensure-Directory -Path $sessionRoot
    return $sessionRoot
}

function Get-TypedWindowSessionStatePath {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey
    )
    return (Join-Path (Get-TypedWindowSessionRoot -Config $Config) ($TargetKey + '.json'))
}

function New-TypedWindowSessionState {
    param(
        [Parameter(Mandatory)][string]$TargetKey,
        [string]$State = 'bootstrap-needed',
        [string]$RunRootValue = '',
        [string]$PairIdValue = '',
        [string]$ResetReason = ''
    )

    return [ordered]@{
        SchemaVersion                     = '1.0.0'
        TargetId                          = $TargetKey
        State                             = $State
        SessionRunRoot                    = $RunRootValue
        SessionPairId                     = $PairIdValue
        SessionTargetId                   = $TargetKey
        SessionEpoch                      = 0
        LastPrepareAt                     = ''
        LastSubmitAt                      = ''
        LastProgressAt                    = ''
        LastConfirmedArtifactAt           = ''
        LastResetReason                   = $ResetReason
        ConsecutiveSubmitUnconfirmedCount = 0
        UpdatedAt                         = (Get-Date).ToString('o')
    }
}

function Read-TypedWindowSessionState {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey
    )

    $path = Get-TypedWindowSessionStatePath -Config $Config -TargetKey $TargetKey
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject](New-TypedWindowSessionState -TargetKey $TargetKey)
    }

    try {
        $session = Read-JsonObject -Path $path
        return [pscustomobject]@{
            SchemaVersion                     = [string](Get-ConfigValue -Object $session -Name 'SchemaVersion' -DefaultValue '1.0.0')
            TargetId                          = [string](Get-ConfigValue -Object $session -Name 'TargetId' -DefaultValue $TargetKey)
            State                             = [string](Get-ConfigValue -Object $session -Name 'State' -DefaultValue 'bootstrap-needed')
            SessionRunRoot                    = [string](Get-ConfigValue -Object $session -Name 'SessionRunRoot' -DefaultValue '')
            SessionPairId                     = [string](Get-ConfigValue -Object $session -Name 'SessionPairId' -DefaultValue '')
            SessionTargetId                   = [string](Get-ConfigValue -Object $session -Name 'SessionTargetId' -DefaultValue $TargetKey)
            SessionEpoch                      = [int](Get-ConfigValue -Object $session -Name 'SessionEpoch' -DefaultValue 0)
            LastPrepareAt                     = [string](Get-ConfigValue -Object $session -Name 'LastPrepareAt' -DefaultValue '')
            LastSubmitAt                      = [string](Get-ConfigValue -Object $session -Name 'LastSubmitAt' -DefaultValue '')
            LastProgressAt                    = [string](Get-ConfigValue -Object $session -Name 'LastProgressAt' -DefaultValue '')
            LastConfirmedArtifactAt           = [string](Get-ConfigValue -Object $session -Name 'LastConfirmedArtifactAt' -DefaultValue '')
            LastResetReason                   = [string](Get-ConfigValue -Object $session -Name 'LastResetReason' -DefaultValue '')
            ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $session -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0)
            UpdatedAt                         = [string](Get-ConfigValue -Object $session -Name 'UpdatedAt' -DefaultValue '')
        }
    }
    catch {
        return [pscustomobject](New-TypedWindowSessionState -TargetKey $TargetKey -State 'dirty-session' -ResetReason 'session-parse-failed')
    }
}

function Save-TypedWindowSessionState {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)]$Session
    )

    $path = Get-TypedWindowSessionStatePath -Config $Config -TargetKey $TargetKey
    $payload = [ordered]@{
        SchemaVersion                     = '1.0.0'
        TargetId                          = $TargetKey
        State                             = [string](Get-ConfigValue -Object $Session -Name 'State' -DefaultValue 'bootstrap-needed')
        SessionRunRoot                    = [string](Get-ConfigValue -Object $Session -Name 'SessionRunRoot' -DefaultValue '')
        SessionPairId                     = [string](Get-ConfigValue -Object $Session -Name 'SessionPairId' -DefaultValue '')
        SessionTargetId                   = [string](Get-ConfigValue -Object $Session -Name 'SessionTargetId' -DefaultValue $TargetKey)
        SessionEpoch                      = [int](Get-ConfigValue -Object $Session -Name 'SessionEpoch' -DefaultValue 0)
        LastPrepareAt                     = [string](Get-ConfigValue -Object $Session -Name 'LastPrepareAt' -DefaultValue '')
        LastSubmitAt                      = [string](Get-ConfigValue -Object $Session -Name 'LastSubmitAt' -DefaultValue '')
        LastProgressAt                    = [string](Get-ConfigValue -Object $Session -Name 'LastProgressAt' -DefaultValue '')
        LastConfirmedArtifactAt           = [string](Get-ConfigValue -Object $Session -Name 'LastConfirmedArtifactAt' -DefaultValue '')
        LastResetReason                   = [string](Get-ConfigValue -Object $Session -Name 'LastResetReason' -DefaultValue '')
        ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $Session -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0)
        UpdatedAt                         = (Get-Date).ToString('o')
    }

    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
}

function New-TypedWindowDebugLogPath {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$Label
    )

    $logsRoot = [string](Get-ConfigValue -Object $Config -Name 'LogsRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $logsRoot)) {
        $logsRoot = Join-Path $script:root '_tmp'
    }

    $debugRoot = Join-Path $logsRoot ('typed-window-prepare\' + $TargetKey)
    Ensure-Directory -Path $debugRoot
    return (Join-Path $debugRoot ((Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '__' + $Label + '.log'))
}

function Invoke-TypedWindowAhkPayload {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$Payload,
        [Parameter(Mandatory)][bool]$ClearInput,
        [Parameter(Mandatory)][string[]]$SubmitModes,
        [Parameter(Mandatory)][string]$DebugLabel,
        [string]$VisibleLabel = ''
    )

    $ahkExePath = [string](Get-ConfigValue -Object $Config -Name 'AhkExePath' -DefaultValue '')
    $ahkScriptPath = [string](Get-ConfigValue -Object $Config -Name 'AhkScriptPath' -DefaultValue '')
    $runtimeMapPath = [string](Get-ConfigValue -Object $Config -Name 'RuntimeMapPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $ahkExePath) -or -not (Test-Path -LiteralPath $ahkExePath -PathType Leaf) -or -not (Test-NonEmptyString $ahkScriptPath) -or -not (Test-Path -LiteralPath $ahkScriptPath -PathType Leaf) -or -not (Test-NonEmptyString $runtimeMapPath) -or -not (Test-Path -LiteralPath $runtimeMapPath -PathType Leaf)) {
        return [pscustomobject]@{
            Executed = $false
            ExitCode = 0
            DebugLogPath = ''
            SkippedReason = 'typed-window-prepare-dependencies-missing'
        }
    }

    $payloadFile = Join-Path $script:stateRoot ('typed_window_payload_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($payloadFile, $Payload, (New-Utf8NoBomEncoding))
    $debugLogPath = New-TypedWindowDebugLogPath -Config $Config -TargetKey $TargetKey -Label $DebugLabel

    $activateSettleMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'ActivateSettleMs' -DefaultValue 250))
    $textSettleMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'TextSettleMs' -DefaultValue 2200))
    $terminalInputMode = [string](Get-ConfigValue -Object $Config -Name 'TerminalInputMode' -DefaultValue 'sendtext')
    if (-not (Test-NonEmptyString $terminalInputMode)) { $terminalInputMode = 'sendtext' }
    $submitGuardMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'SubmitGuardMs' -DefaultValue 0))
    $enterDelayMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'EnterDelayMs' -DefaultValue 900))
    $postSubmitDelayMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'PostSubmitDelayMs' -DefaultValue 900))
    $submitRetryIntervalMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'SubmitRetryIntervalMs' -DefaultValue 1800))
    $sendTimeoutMs = [math]::Max(1000, [int](Get-ConfigValue -Object $Config -Name 'SendTimeoutMs' -DefaultValue 5000))
    $requireActiveBeforeEnter = [bool](Get-ConfigValue -Object $Config -Name 'RequireActiveBeforeEnter' -DefaultValue $true)
    $resolverShellPath = [string](Get-ConfigValue -Object $Config -Name 'ResolverShellPath' -DefaultValue 'powershell.exe')
    $visibleBeaconEnabled = [bool](Get-ConfigValue -Object $Config -Name 'VisibleExecutionBeaconEnabled' -DefaultValue $false)
    $visiblePreHoldMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'VisibleExecutionPreHoldMs' -DefaultValue 0))
    $visiblePostHoldMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'VisibleExecutionPostHoldMs' -DefaultValue 0))
    $restorePreviousActive = [bool](Get-ConfigValue -Object $Config -Name 'VisibleExecutionRestorePreviousActive' -DefaultValue $true)
    $failOnFocusSteal = [bool](Get-ConfigValue -Object $Config -Name 'VisibleExecutionFailOnFocusSteal' -DefaultValue $false)
    $clearInputArg = if ($ClearInput) { '1' } else { '0' }
    $requireActiveBeforeEnterArg = if ($requireActiveBeforeEnter) { '1' } else { '0' }
    $visibleBeaconEnabledArg = if ($visibleBeaconEnabled) { '1' } else { '0' }
    $restorePreviousActiveArg = if ($restorePreviousActive) { '1' } else { '0' }
    $failOnFocusStealArg = if ($failOnFocusSteal) { '1' } else { '0' }
    if (-not (Test-NonEmptyString $VisibleLabel)) { $VisibleLabel = $TargetKey }

    try {
        $proc = Start-Process -FilePath $ahkExePath -ArgumentList @(
            $ahkScriptPath,
            '--runtime', $runtimeMapPath,
            '--targetId', $TargetKey,
            '--resolverShell', $resolverShellPath,
            '--file', $payloadFile,
            '--enter', '1',
            '--timeoutMs', [string]$sendTimeoutMs,
            '--activateSettleMs', [string]$activateSettleMs,
            '--textSettleMs', [string]$textSettleMs,
            '--inputMode', [string]$terminalInputMode,
            '--submitGuardMs', [string]$submitGuardMs,
            '--enterDelayMs', [string]$enterDelayMs,
            '--postSubmitDelayMs', [string]$postSubmitDelayMs,
            '--submitModes', ([string]::Join(',', @($SubmitModes))),
            '--submitRetryIntervalMs', [string]$submitRetryIntervalMs,
            '--requireActiveBeforeEnter', $requireActiveBeforeEnterArg,
            '--requireUserIdleBeforeSend', '0',
            '--minUserIdleBeforeSendMs', '0',
            '--visibleBeaconEnabled', $visibleBeaconEnabledArg,
            '--visibleLabel', $VisibleLabel,
            '--visiblePreHoldMs', [string]$visiblePreHoldMs,
            '--visiblePostHoldMs', [string]$visiblePostHoldMs,
            '--restorePreviousActive', $restorePreviousActiveArg,
            '--failOnFocusSteal', $failOnFocusStealArg,
            '--clearInput', $clearInputArg,
            '--debugLog', $debugLogPath
        ) -Wait -PassThru -WindowStyle Hidden

        return [pscustomobject]@{
            Executed = $true
            ExitCode = [int]$proc.ExitCode
            DebugLogPath = $debugLogPath
            SkippedReason = ''
        }
    }
    finally {
        if (Test-Path -LiteralPath $payloadFile -PathType Leaf) {
            Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-TypedWindowPrepareLogEvidence {
    param([string]$DebugLogPath)

    $evidence = [ordered]@{
        VisibleBeaconObserved   = $false
        FocusStealDetected      = $false
        VisibleFailureReason    = ''
        VisibleActiveWindowSnapshot = ''
        VisibleTargetWindowSnapshot = ''
    }

    if (-not (Test-NonEmptyString $DebugLogPath) -or -not (Test-Path -LiteralPath $DebugLogPath -PathType Leaf)) {
        return [pscustomobject]$evidence
    }

    foreach ($line in @(Get-Content -LiteralPath $DebugLogPath -Encoding UTF8)) {
        if (-not $evidence.VisibleBeaconObserved -and $line -like '*visible_beacon phase=*') {
            $evidence.VisibleBeaconObserved = $true
        }

        if (-not (Test-NonEmptyString $evidence.VisibleActiveWindowSnapshot)) {
            $activeMatch = [regex]::Match([string]$line, 'active=\{([^}]*)\}')
            if ($activeMatch.Success) {
                $evidence.VisibleActiveWindowSnapshot = [string]$activeMatch.Groups[1].Value
            }
        }

        if (-not (Test-NonEmptyString $evidence.VisibleTargetWindowSnapshot)) {
            $targetMatch = [regex]::Match([string]$line, 'target=\{([^}]*)\}')
            if ($targetMatch.Success) {
                $evidence.VisibleTargetWindowSnapshot = [string]$targetMatch.Groups[1].Value
            }
        }

        if (-not $evidence.FocusStealDetected -and $line -like '*focus_stolen_hard_fail*') {
            $evidence.FocusStealDetected = $true
            $evidence.VisibleFailureReason = 'visible-bootstrap-focus-steal'
        }
    }

    return [pscustomobject]$evidence
}

function Resolve-TypedWindowPrepareRequirement {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$RunRootValue,
        [Parameter(Mandatory)][string]$PairIdValue,
        [Parameter(Mandatory)][string]$TargetKey
    )

    if (-not (Test-NonEmptyString ([string](Get-ConfigValue -Object $Session -Name 'SessionRunRoot' -DefaultValue '')))) {
        return [pscustomobject]@{ Required = $true; Reason = 'bootstrap-needed' }
    }

    $sessionState = [string](Get-ConfigValue -Object $Session -Name 'State' -DefaultValue 'bootstrap-needed')
    if ($sessionState -in @('bootstrap-needed', 'recovery-needed', 'dirty-session')) {
        return [pscustomobject]@{ Required = $true; Reason = if (Test-NonEmptyString $sessionState) { $sessionState } else { 'bootstrap-needed' } }
    }

    if ([string](Get-ConfigValue -Object $Session -Name 'SessionRunRoot' -DefaultValue '') -ne $RunRootValue) {
        return [pscustomobject]@{ Required = $true; Reason = 'runroot-changed' }
    }
    if ([string](Get-ConfigValue -Object $Session -Name 'SessionPairId' -DefaultValue '') -ne $PairIdValue) {
        return [pscustomobject]@{ Required = $true; Reason = 'pair-changed' }
    }
    if ([string](Get-ConfigValue -Object $Session -Name 'SessionTargetId' -DefaultValue '') -ne $TargetKey) {
        return [pscustomobject]@{ Required = $true; Reason = 'target-changed' }
    }

    return [pscustomobject]@{ Required = $false; Reason = 'reuse-session' }
}

$script:root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $script:root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$resolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$script:stateRoot = Join-Path $resolvedRunRoot '.state'
Ensure-Directory -Path $script:stateRoot
$config = Import-ConfigDataFile -Path $resolvedConfigPath

$session = Read-TypedWindowSessionState -Config $config -TargetKey $TargetId
$requirement = Resolve-TypedWindowPrepareRequirement -Session $session -RunRootValue $resolvedRunRoot -PairIdValue $PairId -TargetKey $TargetId

$result = [ordered]@{
    RunRoot = $resolvedRunRoot
    ConfigPath = $resolvedConfigPath
    PairId = $PairId
    TargetId = $TargetId
    PrepareRequired = [bool]$requirement.Required
    PrepareReason = [string]$requirement.Reason
    FinalState = ''
    ManualAttentionRequired = $false
    VisibleLabel = ($TargetId + '-PREPARE')
    DebugLogPath = ''
    ExitCode = 0
    TypedWindowSessionState = [string](Get-ConfigValue -Object $session -Name 'State' -DefaultValue '')
    TypedWindowLastResetReason = [string](Get-ConfigValue -Object $session -Name 'LastResetReason' -DefaultValue '')
    VisibleBeaconObserved = $false
    FocusStealDetected = $false
    VisibleFailureReason = ''
    VisibleActiveWindowSnapshot = ''
    VisibleTargetWindowSnapshot = ''
    CompletedAt = ''
}

if (-not [bool]$requirement.Required) {
    $result.FinalState = 'reused'
    $result.CompletedAt = (Get-Date).ToString('o')
    if ($AsJson) {
        Write-Output (($result | ConvertTo-Json -Depth 6))
    }
    else {
        Write-Output ([pscustomobject]$result)
    }
    return
}

$prepareResult = Invoke-TypedWindowAhkPayload `
    -Config $config `
    -TargetKey $TargetId `
    -Payload '/new' `
    -ClearInput $true `
    -SubmitModes @('enter') `
    -DebugLabel ([string]$requirement.Reason) `
    -VisibleLabel ($TargetId + '-PREPARE')

$result.DebugLogPath = [string]$prepareResult.DebugLogPath
$result.ExitCode = [int](Get-ConfigValue -Object $prepareResult -Name 'ExitCode' -DefaultValue 0)
$prepareEvidence = Get-TypedWindowPrepareLogEvidence -DebugLogPath ([string]$prepareResult.DebugLogPath)
$result.VisibleBeaconObserved = [bool](Get-ConfigValue -Object $prepareEvidence -Name 'VisibleBeaconObserved' -DefaultValue $false)
$result.FocusStealDetected = [bool](Get-ConfigValue -Object $prepareEvidence -Name 'FocusStealDetected' -DefaultValue $false)
$result.VisibleFailureReason = [string](Get-ConfigValue -Object $prepareEvidence -Name 'VisibleFailureReason' -DefaultValue '')
$result.VisibleActiveWindowSnapshot = [string](Get-ConfigValue -Object $prepareEvidence -Name 'VisibleActiveWindowSnapshot' -DefaultValue '')
$result.VisibleTargetWindowSnapshot = [string](Get-ConfigValue -Object $prepareEvidence -Name 'VisibleTargetWindowSnapshot' -DefaultValue '')

if ([bool]$prepareResult.Executed -and [int]$prepareResult.ExitCode -ne 0) {
    $failOnFocusSteal = [bool](Get-ConfigValue -Object $config -Name 'VisibleExecutionFailOnFocusSteal' -DefaultValue $false)
    if ($failOnFocusSteal -and [int]$prepareResult.ExitCode -eq 42) {
        $result.FinalState = 'manual_attention_required'
        $result.ManualAttentionRequired = $true
        if (-not (Test-NonEmptyString ([string]$result.VisibleFailureReason))) {
            $result.VisibleFailureReason = 'visible-bootstrap-focus-steal'
        }
        $result.FocusStealDetected = $true
        $session.State = 'recovery-needed'
        $session.LastResetReason = 'focus-steal-before-submit'
        $session.ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $session -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0) + 1
    }
    else {
        $result.FinalState = 'failed'
        if (-not (Test-NonEmptyString ([string]$result.VisibleFailureReason))) {
            $result.VisibleFailureReason = 'visible-bootstrap-prepare-failed'
        }
        $session.State = 'dirty-session'
        $session.LastResetReason = [string]$requirement.Reason
    }
    Save-TypedWindowSessionState -Config $config -TargetKey $TargetId -Session $session
    $result.TypedWindowSessionState = [string](Get-ConfigValue -Object $session -Name 'State' -DefaultValue '')
    $result.TypedWindowLastResetReason = [string](Get-ConfigValue -Object $session -Name 'LastResetReason' -DefaultValue '')
}
else {
    $session.State = 'active-run'
    $session.SessionRunRoot = $resolvedRunRoot
    $session.SessionPairId = $PairId
    $session.SessionTargetId = $TargetId
    $session.SessionEpoch = [int](Get-ConfigValue -Object $session -Name 'SessionEpoch' -DefaultValue 0) + 1
    $session.LastPrepareAt = (Get-Date).ToString('o')
    $session.LastResetReason = [string]$requirement.Reason
    $session.ConsecutiveSubmitUnconfirmedCount = 0
    Save-TypedWindowSessionState -Config $config -TargetKey $TargetId -Session $session
    $result.FinalState = 'prepared'
    $result.TypedWindowSessionState = [string](Get-ConfigValue -Object $session -Name 'State' -DefaultValue '')
    $result.TypedWindowLastResetReason = [string](Get-ConfigValue -Object $session -Name 'LastResetReason' -DefaultValue '')
}

$result.CompletedAt = (Get-Date).ToString('o')

if ($AsJson) {
    Write-Output (($result | ConvertTo-Json -Depth 6))
}
else {
    Write-Output ([pscustomobject]$result)
}
