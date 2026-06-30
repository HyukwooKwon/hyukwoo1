Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')

$script:TargetAutoloopSchemaVersion = '1.0.0'
$script:TargetAutoloopRunModes = @('target-inbox-submit', 'target-autoloop')
$script:TargetAutoloopTriggerKinds = @('input-file', 'publish-ready')
$script:TargetAutoloopExternalPathPolicies = @('permissive', 'strict')
$script:TargetAutoloopPhases = @(
    'disabled',
    'idle',
    'dispatch-delay',
    'input-detected',
    'claimed',
    'queued',
    'waiting-output',
    'output-ready',
    'cooldown',
    'paused',
    'failed',
    'stopped',
    'limit-reached'
)
$script:TargetAutoloopNextActions = @(
    'wait-for-input',
    'wait-dispatch-delay',
    'claim-input',
    'queue-command',
    'dispatch-command',
    'wait-for-output',
    'cooldown',
    'resume',
    'stopped',
    'open-receipt',
    'limit-reached',
    'no-op'
)

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

function Read-JsonObjectIfPresent {
    param([AllowEmptyString()][string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return (Read-JsonObject -Path $Path)
}

function Get-TargetAutoloopRuntimeMapLauncherSessionIds {
    param([AllowEmptyString()][string]$RuntimeMapPath)

    $runtimeMap = Read-JsonObjectIfPresent -Path $RuntimeMapPath
    if ($null -eq $runtimeMap) {
        return @()
    }

    $items = if ($runtimeMap -is [System.Array]) {
        @($runtimeMap)
    }
    elseif ($null -ne $runtimeMap) {
        @($runtimeMap)
    }
    else {
        @()
    }

    return @(
        $items |
            ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'LauncherSessionId' -DefaultValue '') } |
            Where-Object { Test-NonEmptyString $_ } |
            Sort-Object -Unique
    )
}

function Test-TargetAutoloopProcessAlive {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $false
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        return ($null -ne $process)
    }
    catch {
        return $false
    }
}

function Test-TargetAutoloopRouterMutexHeld {
    param([AllowEmptyString()][string]$Name)

    if (-not (Test-NonEmptyString $Name)) {
        return $false
    }

    $createdNew = $false
    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::new($false, $Name, [ref]$createdNew)
        try {
            if ($mutex.WaitOne(0)) {
                $mutex.ReleaseMutex()
                return $false
            }
            return $true
        }
        catch [System.Threading.AbandonedMutexException] {
            return $true
        }
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Get-TargetAutoloopFileAgeSeconds {
    param([AllowEmptyString()][string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return -1
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return [int][math]::Max(0, [math]::Floor(((Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds))
    }
    catch {
        return -1
    }
}

function Test-TargetAutoloopObjectProperty {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

function Get-TargetAutoloopRouterConfigDriftSummary {
    param(
        [Parameter(Mandatory)]$Config,
        $RouterState = $null,
        [string]$RouterStatus = ''
    )

    $sourceConfig = $Config
    $configPath = [string](Get-ConfigValue -Object $Config -Name 'ConfigPath' -DefaultValue '')
    if ((Test-NonEmptyString $configPath) -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        try {
            $sourceConfig = Import-PowerShellDataFile -LiteralPath $configPath
        }
        catch {
            $sourceConfig = $Config
        }
    }

    $configured = [ordered]@{
        RequireUserIdleBeforeSend = [bool](Get-ConfigValue -Object $sourceConfig -Name 'RequireUserIdleBeforeSend' -DefaultValue $false)
        MinUserIdleBeforeSendMs = [int](Get-ConfigValue -Object $sourceConfig -Name 'MinUserIdleBeforeSendMs' -DefaultValue 0)
        UserIdleWaitTimeoutMs = [int](Get-ConfigValue -Object $sourceConfig -Name 'UserIdleWaitTimeoutMs' -DefaultValue 0)
        UserIdleWaitPollMs = [int](Get-ConfigValue -Object $sourceConfig -Name 'UserIdleWaitPollMs' -DefaultValue 250)
        SubmitGuardMs = [int](Get-ConfigValue -Object $sourceConfig -Name 'SubmitGuardMs' -DefaultValue 0)
        VisibleExecutionFailOnFocusSteal = [bool](Get-ConfigValue -Object $sourceConfig -Name 'VisibleExecutionFailOnFocusSteal' -DefaultValue $false)
        VisibleExecutionRestorePreviousActive = [bool](Get-ConfigValue -Object $sourceConfig -Name 'VisibleExecutionRestorePreviousActive' -DefaultValue $true)
    }
    $observed = [ordered]@{}
    $driftReasons = @()
    $hasAnyObservedSetting = $false
    foreach ($name in @($configured.Keys)) {
        if (Test-TargetAutoloopObjectProperty -Object $RouterState -Name $name) {
            $hasAnyObservedSetting = $true
            $observed[$name] = Get-ConfigValue -Object $RouterState -Name $name -DefaultValue $null
        }
        else {
            $observed[$name] = $null
        }
    }

    $configNeedsState = (
        [bool]$configured.RequireUserIdleBeforeSend -or
        [int]$configured.MinUserIdleBeforeSendMs -gt 0 -or
        [int]$configured.UserIdleWaitTimeoutMs -gt 0 -or
        [int]$configured.SubmitGuardMs -gt 0 -or
        [bool]$configured.VisibleExecutionFailOnFocusSteal -or
        -not [bool]$configured.VisibleExecutionRestorePreviousActive
    )

    if ($RouterStatus -eq 'running' -and $configNeedsState -and -not $hasAnyObservedSetting) {
        $driftReasons += 'router-state-missing-effective-send-settings'
    }
    elseif ($RouterStatus -eq 'running' -and $hasAnyObservedSetting) {
        foreach ($name in @($configured.Keys)) {
            $configuredValue = $configured[$name]
            $observedValue = $observed[$name]
            if ($null -eq $observedValue) {
                $driftReasons += ('missing:{0}' -f $name)
                continue
            }
            if ($configuredValue -is [bool]) {
                if ([bool]$observedValue -ne [bool]$configuredValue) {
                    $driftReasons += ('mismatch:{0}:config={1}:router={2}' -f $name, [bool]$configuredValue, [bool]$observedValue)
                }
                continue
            }
            if ([int]$observedValue -ne [int]$configuredValue) {
                $driftReasons += ('mismatch:{0}:config={1}:router={2}' -f $name, [int]$configuredValue, [int]$observedValue)
            }
        }
    }

    return [pscustomobject][ordered]@{
        Drift = (@($driftReasons).Count -gt 0)
        Reasons = @($driftReasons)
        Configured = [pscustomobject]$configured
        Router = [pscustomobject]$observed
    }
}

function Get-TargetAutoloopRouterSessionState {
    param([Parameter(Mandatory)]$Config)

    $runtimeMapPath = [string](Get-ConfigValue -Object $Config -Name 'RuntimeMapPath' -DefaultValue '')
    $routerStatePath = [string](Get-ConfigValue -Object $Config -Name 'RouterStatePath' -DefaultValue '')
    $runtimeSessionIds = @(Get-TargetAutoloopRuntimeMapLauncherSessionIds -RuntimeMapPath $runtimeMapPath)
    $routerState = Read-JsonObjectIfPresent -Path $routerStatePath
    $routerStatus = if ($null -ne $routerState) { [string](Get-ConfigValue -Object $routerState -Name 'Status' -DefaultValue '') } else { '' }
    $routerLauncherSessionId = if ($null -ne $routerState) { [string](Get-ConfigValue -Object $routerState -Name 'LauncherSessionId' -DefaultValue '') } else { '' }
    $runtimeLauncherSessionId = if (@($runtimeSessionIds).Count -eq 1) { [string]$runtimeSessionIds[0] } else { '' }
    $routerPid = if ($null -ne $routerState) { [int](Get-ConfigValue -Object $routerState -Name 'RouterPid' -DefaultValue 0) } else { 0 }
    $routerPidExists = Test-TargetAutoloopProcessAlive -ProcessId $routerPid
    $routerMutexName = [string](Get-ConfigValue -Object $Config -Name 'RouterMutexName' -DefaultValue '')
    if (-not (Test-NonEmptyString $routerMutexName) -and $null -ne $routerState) {
        $routerMutexName = [string](Get-ConfigValue -Object $routerState -Name 'RouterMutexName' -DefaultValue '')
    }
    $routerMutexHeld = if (Test-NonEmptyString $routerMutexName) {
        Test-TargetAutoloopRouterMutexHeld -Name $routerMutexName
    }
    else {
        $false
    }
    $routerStateAgeSeconds = Get-TargetAutoloopFileAgeSeconds -Path $routerStatePath
    $routerConfigDrift = Get-TargetAutoloopRouterConfigDriftSummary -Config $Config -RouterState $routerState -RouterStatus $routerStatus
    $state = 'not-configured'
    if (Test-NonEmptyString $runtimeMapPath -or Test-NonEmptyString $routerStatePath) {
        $state = 'insufficient-data'
    }
    if (@($runtimeSessionIds).Count -gt 1) {
        $state = 'runtime-session-ambiguous'
    }
    elseif ((Test-NonEmptyString $routerStatus) -and $routerStatus -ne 'running') {
        $state = 'router-not-running'
    }
    elseif (
        $routerStatus -eq 'running' -and
        (Test-NonEmptyString $runtimeLauncherSessionId) -and
        (Test-NonEmptyString $routerLauncherSessionId) -and
        $runtimeLauncherSessionId -ne $routerLauncherSessionId
    ) {
        $state = 'mismatch'
    }
    elseif ($routerStatus -eq 'running' -and $routerPid -le 0) {
        $state = 'router-pid-missing'
    }
    elseif ($routerStatus -eq 'running' -and -not $routerPidExists) {
        $state = 'router-pid-not-running'
    }
    elseif ($routerStatus -eq 'running' -and (Test-NonEmptyString $routerMutexName) -and -not $routerMutexHeld) {
        $state = 'router-mutex-not-held'
    }
    elseif ((Test-NonEmptyString $runtimeLauncherSessionId) -and (Test-NonEmptyString $routerLauncherSessionId)) {
        $state = 'ok'
    }

    return [pscustomobject][ordered]@{
        State = $state
        Mismatch = ($state -eq 'mismatch')
        RuntimeMapPath = $runtimeMapPath
        RuntimeMapExists = ((Test-NonEmptyString $runtimeMapPath) -and (Test-Path -LiteralPath $runtimeMapPath -PathType Leaf))
        RuntimeLauncherSessionIds = @($runtimeSessionIds)
        RuntimeLauncherSessionId = $runtimeLauncherSessionId
        RouterStatePath = $routerStatePath
        RouterStateExists = ((Test-NonEmptyString $routerStatePath) -and (Test-Path -LiteralPath $routerStatePath -PathType Leaf))
        RouterStateAgeSeconds = $routerStateAgeSeconds
        RouterStateUpdatedAt = if ($null -ne $routerState) { [string](Get-ConfigValue -Object $routerState -Name 'UpdatedAt' -DefaultValue '') } else { '' }
        RouterStatus = $routerStatus
        RouterLauncherSessionId = $routerLauncherSessionId
        RouterPid = $routerPid
        RouterPidExists = $routerPidExists
        RouterMutexName = $routerMutexName
        RouterMutexHeld = $routerMutexHeld
        RouterConfigDrift = [bool]$routerConfigDrift.Drift
        RouterConfigDriftReasons = @($routerConfigDrift.Reasons)
        ConfiguredRequireUserIdleBeforeSend = [bool]$routerConfigDrift.Configured.RequireUserIdleBeforeSend
        ConfiguredMinUserIdleBeforeSendMs = [int]$routerConfigDrift.Configured.MinUserIdleBeforeSendMs
        ConfiguredUserIdleWaitTimeoutMs = [int]$routerConfigDrift.Configured.UserIdleWaitTimeoutMs
        ConfiguredUserIdleWaitPollMs = [int]$routerConfigDrift.Configured.UserIdleWaitPollMs
        ConfiguredSubmitGuardMs = [int]$routerConfigDrift.Configured.SubmitGuardMs
        ConfiguredVisibleExecutionFailOnFocusSteal = [bool]$routerConfigDrift.Configured.VisibleExecutionFailOnFocusSteal
        RouterRequireUserIdleBeforeSend = $routerConfigDrift.Router.RequireUserIdleBeforeSend
        RouterMinUserIdleBeforeSendMs = $routerConfigDrift.Router.MinUserIdleBeforeSendMs
        RouterUserIdleWaitTimeoutMs = $routerConfigDrift.Router.UserIdleWaitTimeoutMs
        RouterUserIdleWaitPollMs = $routerConfigDrift.Router.UserIdleWaitPollMs
        RouterSubmitGuardMs = $routerConfigDrift.Router.SubmitGuardMs
        RouterVisibleExecutionFailOnFocusSteal = $routerConfigDrift.Router.VisibleExecutionFailOnFocusSteal
    }
}

function New-TargetAutoloopRouterSessionMismatchMessage {
    param([Parameter(Mandatory)]$RouterSessionState)

    return (
        'router/runtime LauncherSessionId가 달라 target-autoloop ready 파일이 router에서 ignored 됩니다. ' +
        '공식 8창 재사용/attach 후 router를 현재 세션으로 다시 시작한 뒤 감지를 재시작하세요. ' +
        'router={0} runtime={1} routerState={2} runtimeMap={3}' -f `
            [string](Get-ConfigValue -Object $RouterSessionState -Name 'RouterLauncherSessionId' -DefaultValue ''), `
            [string](Get-ConfigValue -Object $RouterSessionState -Name 'RuntimeLauncherSessionId' -DefaultValue ''), `
            [string](Get-ConfigValue -Object $RouterSessionState -Name 'RouterStatePath' -DefaultValue ''), `
            [string](Get-ConfigValue -Object $RouterSessionState -Name 'RuntimeMapPath' -DefaultValue '')
    )
}

function New-TargetAutoloopRouterSessionNotReadyMessage {
    param([Parameter(Mandatory)]$RouterSessionState)

    $state = [string](Get-ConfigValue -Object $RouterSessionState -Name 'State' -DefaultValue '')
    if ([bool](Get-ConfigValue -Object $RouterSessionState -Name 'Mismatch' -DefaultValue $false)) {
        return (New-TargetAutoloopRouterSessionMismatchMessage -RouterSessionState $RouterSessionState)
    }

    return (
        'router/runtime 세션이 target-autoloop ready 파일 소비 조건을 만족하지 않습니다. ' +
        '공식 8창 재사용/attach 후 router를 현재 세션으로 다시 시작한 뒤 감지를 재시작하세요. ' +
        'state={0} routerPid={1} pidExists={2} mutex={3} mutexHeld={4} router={5} runtime={6} routerState={7} runtimeMap={8}' -f `
            $(if (Test-NonEmptyString $state) { $state } else { '-' }), `
            [int](Get-ConfigValue -Object $RouterSessionState -Name 'RouterPid' -DefaultValue 0), `
            [bool](Get-ConfigValue -Object $RouterSessionState -Name 'RouterPidExists' -DefaultValue $false), `
            $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $RouterSessionState -Name 'RouterMutexName' -DefaultValue ''))) { [string](Get-ConfigValue -Object $RouterSessionState -Name 'RouterMutexName' -DefaultValue '') } else { '-' }), `
            [bool](Get-ConfigValue -Object $RouterSessionState -Name 'RouterMutexHeld' -DefaultValue $false), `
            [string](Get-ConfigValue -Object $RouterSessionState -Name 'RouterLauncherSessionId' -DefaultValue ''), `
            [string](Get-ConfigValue -Object $RouterSessionState -Name 'RuntimeLauncherSessionId' -DefaultValue ''), `
            [string](Get-ConfigValue -Object $RouterSessionState -Name 'RouterStatePath' -DefaultValue ''), `
            [string](Get-ConfigValue -Object $RouterSessionState -Name 'RuntimeMapPath' -DefaultValue '')
    )
}

function Write-JsonFileAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $tempPath = ('{0}.{1}.{2}.tmp' -f $Path, $PID, ([guid]::NewGuid().ToString('N')))
    try {
        $Payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Append-LineUtf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Line
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $encoding = New-Utf8NoBomEncoding
    [System.IO.File]::AppendAllText($Path, ($Line + [Environment]::NewLine), $encoding)
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

function Get-FileHashHex {
    param([Parameter(Mandatory)][string]$Path)

    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Get-TextHashHex {
    param([Parameter(Mandatory)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $sha256) {
            $sha256.Dispose()
        }
    }
}

function Test-ValidTargetAutoloopValue {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string[]]$AllowedValues
    )

    return ($AllowedValues -contains [string]$Value)
}

function Assert-TargetAutoloopEnum {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string[]]$AllowedValues,
        [Parameter(Mandatory)][string]$FieldName
    )

    if (-not (Test-ValidTargetAutoloopValue -Value $Value -AllowedValues $AllowedValues)) {
        throw ("{0} must be one of: {1}" -f $FieldName, ($AllowedValues -join ', '))
    }
}

function Resolve-TargetAutoloopDispatchDelayPolicy {
    param(
        $Source,
        [Parameter(Mandatory)][string]$FixedFieldName,
        [Parameter(Mandatory)][string]$MinFieldName,
        [Parameter(Mandatory)][string]$MaxFieldName,
        [int]$InheritedMinDelaySeconds = 0,
        [int]$InheritedMaxDelaySeconds = 0,
        [string]$ContextLabel = 'TargetAutoloop'
    )

    $hasFixedDelay = Test-ConfigMemberExists -Object $Source -Name $FixedFieldName
    $hasMinDelay = Test-ConfigMemberExists -Object $Source -Name $MinFieldName
    $hasMaxDelay = Test-ConfigMemberExists -Object $Source -Name $MaxFieldName

    $fixedDelaySeconds = if ($hasFixedDelay) {
        [int](Get-ConfigValue -Object $Source -Name $FixedFieldName -DefaultValue 0)
    }
    else {
        0
    }

    if ($hasMinDelay) {
        $minDelaySeconds = [int](Get-ConfigValue -Object $Source -Name $MinFieldName -DefaultValue $InheritedMinDelaySeconds)
    }
    elseif ($hasFixedDelay) {
        $minDelaySeconds = $fixedDelaySeconds
    }
    else {
        $minDelaySeconds = [int]$InheritedMinDelaySeconds
    }

    if ($hasMaxDelay) {
        $maxDelaySeconds = [int](Get-ConfigValue -Object $Source -Name $MaxFieldName -DefaultValue $InheritedMaxDelaySeconds)
    }
    elseif ($hasMinDelay) {
        $maxDelaySeconds = $minDelaySeconds
    }
    elseif ($hasFixedDelay) {
        $maxDelaySeconds = $fixedDelaySeconds
    }
    else {
        $maxDelaySeconds = [int]$InheritedMaxDelaySeconds
    }

    foreach ($delayField in @(
            @{ Name = $FixedFieldName; Present = $hasFixedDelay; Value = $fixedDelaySeconds },
            @{ Name = $MinFieldName; Present = $hasMinDelay; Value = $minDelaySeconds },
            @{ Name = $MaxFieldName; Present = $hasMaxDelay; Value = $maxDelaySeconds }
        )) {
        if ([bool]$delayField.Present -and [int]$delayField.Value -lt 0) {
            throw ('{0}.{1} must be a non-negative integer.' -f $ContextLabel, $delayField.Name)
        }
    }

    if ($minDelaySeconds -lt 0 -or $maxDelaySeconds -lt 0) {
        throw ('{0} publish-ready dispatch delay values must be non-negative integers.' -f $ContextLabel)
    }
    if ($maxDelaySeconds -lt $minDelaySeconds) {
        throw ('{0}.{1} must be greater than or equal to {2}.' -f $ContextLabel, $MaxFieldName, $MinFieldName)
    }

    $delayMode = if ($maxDelaySeconds -gt $minDelaySeconds) { 'range' } else { 'fixed' }
    return [pscustomobject]@{
        DelayMode = $delayMode
        FixedDelaySeconds = if ($hasFixedDelay) { $fixedDelaySeconds } else { $minDelaySeconds }
        MinDelaySeconds = $minDelaySeconds
        MaxDelaySeconds = $maxDelaySeconds
    }
}

function Test-TargetAutoloopDispatchDelayRow {
    param($TargetRow)

    $phase = [string](Get-ConfigValue -Object $TargetRow -Name 'Phase' -DefaultValue '')
    $nextAction = [string](Get-ConfigValue -Object $TargetRow -Name 'NextAction' -DefaultValue '')
    $dispatchState = [string](Get-ConfigValue -Object $TargetRow -Name 'LastDispatchState' -DefaultValue '')

    return (
        $phase -eq 'dispatch-delay' -or
        $nextAction -eq 'wait-dispatch-delay' -or
        $dispatchState -eq 'dispatch-delay-waiting'
    )
}

function Get-TargetAutoloopDelayRangeLabel {
    param($TargetRow)

    $delayMode = [string](Get-ConfigValue -Object $TargetRow -Name 'PublishReadyDispatchDelayMode' -DefaultValue 'fixed')
    $delaySeconds = [int](Get-ConfigValue -Object $TargetRow -Name 'PublishReadyDispatchDelaySeconds' -DefaultValue 0)
    $delayMinSeconds = [int](Get-ConfigValue -Object $TargetRow -Name 'PublishReadyDispatchMinDelaySeconds' -DefaultValue $delaySeconds)
    $delayMaxSeconds = [int](Get-ConfigValue -Object $TargetRow -Name 'PublishReadyDispatchMaxDelaySeconds' -DefaultValue $delayMinSeconds)

    if (($delayMaxSeconds -gt $delayMinSeconds -or $delayMode -eq 'range') -and ($delayMaxSeconds -gt 0 -or $delayMinSeconds -gt 0)) {
        return ('{0}-{1}s' -f $delayMinSeconds, $delayMaxSeconds)
    }
    if ($delayMinSeconds -gt 0) {
        return ('{0}s' -f $delayMinSeconds)
    }
    return ''
}

function Convert-TargetAutoloopTimestampText {
    param($Value)

    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [datetimeoffset]) {
        return $Value.ToString("yyyy-MM-dd'T'HH:mm:ssK", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetime]) {
        return $Value.ToString("yyyy-MM-dd'T'HH:mm:ssK", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Get-TargetAutoloopTimestampFieldText {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    return (Convert-TargetAutoloopTimestampText -Value (Get-ConfigValue -Object $Object -Name $Name -DefaultValue $null))
}

function Get-TargetAutoloopDelaySummary {
    param($TargetRows)

    $waitingRemainingSeconds = $null
    $waitingTargetId = ''
    $waitingDelayRange = ''
    $waitingDueAt = ''

    $dueEligibleAtValue = $null
    $dueTargetId = ''
    $dueDelayRange = ''
    $dueDueAt = ''

    $invalidTargetId = ''
    $invalidDelayRange = ''
    $invalidDueAt = ''
    $invalidDueAtCount = 0
    $overdueCount = 0

    foreach ($targetRow in @($TargetRows)) {
        if (-not (Test-TargetAutoloopDispatchDelayRow -TargetRow $targetRow)) {
            continue
        }

        $targetId = [string](Get-ConfigValue -Object $targetRow -Name 'TargetId' -DefaultValue '')
        $delayRangeLabel = Get-TargetAutoloopDelayRangeLabel -TargetRow $targetRow
        $eligibleAtText = Convert-TargetAutoloopTimestampText -Value (Get-ConfigValue -Object $targetRow -Name 'PendingDispatchEligibleAt' -DefaultValue '')

        if (-not (Test-NonEmptyString $eligibleAtText)) {
            $invalidDueAtCount += 1
            if (-not (Test-NonEmptyString $invalidTargetId) -or ((Test-NonEmptyString $targetId) -and $targetId -lt $invalidTargetId)) {
                $invalidTargetId = $targetId
                $invalidDelayRange = $delayRangeLabel
                $invalidDueAt = $eligibleAtText
            }
            continue
        }

        $eligibleAtValue = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($eligibleAtText, [ref]$eligibleAtValue)) {
            $invalidDueAtCount += 1
            if (-not (Test-NonEmptyString $invalidTargetId) -or ((Test-NonEmptyString $targetId) -and $targetId -lt $invalidTargetId)) {
                $invalidTargetId = $targetId
                $invalidDelayRange = $delayRangeLabel
                $invalidDueAt = $eligibleAtText
            }
            continue
        }

        $remainingSeconds = [int][math]::Ceiling(($eligibleAtValue - [datetimeoffset]::Now).TotalSeconds)
        if ($remainingSeconds -gt 0) {
            if (
                $null -eq $waitingRemainingSeconds -or
                $remainingSeconds -lt $waitingRemainingSeconds -or
                (
                    $remainingSeconds -eq $waitingRemainingSeconds -and
                    (Test-NonEmptyString $targetId) -and
                    (-not (Test-NonEmptyString $waitingTargetId) -or $targetId -lt $waitingTargetId)
                )
            ) {
                $waitingRemainingSeconds = $remainingSeconds
                $waitingTargetId = $targetId
                $waitingDelayRange = $delayRangeLabel
                $waitingDueAt = $eligibleAtText
            }
            continue
        }

        $overdueCount += 1
        if (
            $null -eq $dueEligibleAtValue -or
            $eligibleAtValue -lt $dueEligibleAtValue -or
            (
                $eligibleAtValue -eq $dueEligibleAtValue -and
                (Test-NonEmptyString $targetId) -and
                (-not (Test-NonEmptyString $dueTargetId) -or $targetId -lt $dueTargetId)
            )
        ) {
            $dueEligibleAtValue = $eligibleAtValue
            $dueTargetId = $targetId
            $dueDelayRange = $delayRangeLabel
            $dueDueAt = $eligibleAtText
        }
    }

    if ($null -ne $waitingRemainingSeconds) {
        return [pscustomobject]([ordered]@{
                State = 'dispatch-delay-waiting'
                TargetId = $waitingTargetId
                MinRemainingSeconds = $waitingRemainingSeconds
                DelayRange = $waitingDelayRange
                DueAt = $waitingDueAt
                InvalidDueAtCount = $invalidDueAtCount
                OverdueCount = $overdueCount
            })
    }

    if (Test-NonEmptyString $dueTargetId) {
        return [pscustomobject]([ordered]@{
                State = 'dispatch-delay-due'
                TargetId = $dueTargetId
                MinRemainingSeconds = $null
                DelayRange = $dueDelayRange
                DueAt = $dueDueAt
                InvalidDueAtCount = $invalidDueAtCount
                OverdueCount = $overdueCount
            })
    }

    if (Test-NonEmptyString $invalidTargetId) {
        return [pscustomobject]([ordered]@{
                State = 'dispatch-delay-invalid'
                TargetId = $invalidTargetId
                MinRemainingSeconds = $null
                DelayRange = $invalidDelayRange
                DueAt = $invalidDueAt
                InvalidDueAtCount = $invalidDueAtCount
                OverdueCount = $overdueCount
            })
    }

    return [pscustomobject]([ordered]@{
            State = 'none'
            TargetId = ''
            MinRemainingSeconds = $null
            DelayRange = ''
            DueAt = ''
            InvalidDueAtCount = $invalidDueAtCount
            OverdueCount = $overdueCount
        })
}

function ConvertTo-TargetAutoloopSmokeReceiptDocument {
    param($Payload)

    $receipt = if ($null -ne $Payload) { $Payload } else { [ordered]@{} }
    $resultText = [string](Get-ConfigValue -Object $receipt -Name 'Result' -DefaultValue '')
    if (-not (Test-NonEmptyString $resultText)) {
        $resultText = [string](Get-ConfigValue -Object $receipt -Name 'State' -DefaultValue '')
    }
    if (-not (Test-NonEmptyString $resultText)) {
        $resultText = 'unknown'
    }

    $proofLevel = [string](Get-ConfigValue -Object $receipt -Name 'ProofLevel' -DefaultValue '')
    if (-not (Test-NonEmptyString $proofLevel)) {
        $proofLevel = [string](Get-ConfigValue -Object $receipt -Name 'Proof' -DefaultValue '')
    }

    $targetId = [string](Get-ConfigValue -Object $receipt -Name 'TargetId' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetId)) {
        $targetId = [string](Get-ConfigValue -Object $receipt -Name 'SeedTargetId' -DefaultValue '')
    }

    $finalPhase = [string](Get-ConfigValue -Object $receipt -Name 'FinalPhase' -DefaultValue '')
    if (-not (Test-NonEmptyString $finalPhase)) {
        $finalPhase = [string](Get-ConfigValue -Object $receipt -Name 'Phase' -DefaultValue '')
    }
    if (-not (Test-NonEmptyString $finalPhase)) {
        $finalPhase = [string](Get-ConfigValue -Object $receipt -Name 'Stage' -DefaultValue '')
    }

    $watcherStopReason = [string](Get-ConfigValue -Object $receipt -Name 'WatcherStopReason' -DefaultValue '')
    if (-not (Test-NonEmptyString $watcherStopReason)) {
        $watcherStopReason = [string](Get-ConfigValue -Object $receipt -Name 'StopReason' -DefaultValue '')
    }

    $completedAt = Get-TargetAutoloopTimestampFieldText -Object $receipt -Name 'CompletedAt'
    if (-not (Test-NonEmptyString $completedAt)) {
        $completedAt = Get-TargetAutoloopTimestampFieldText -Object $receipt -Name 'LastUpdatedAt'
    }
    if (-not (Test-NonEmptyString $completedAt)) {
        $completedAt = Get-TargetAutoloopTimestampFieldText -Object $receipt -Name 'GeneratedAt'
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = [string](Get-ConfigValue -Object $receipt -Name 'SchemaVersion' -DefaultValue $script:TargetAutoloopSchemaVersion)
        ReceiptKind = [string](Get-ConfigValue -Object $receipt -Name 'ReceiptKind' -DefaultValue 'target-autoloop-smoke')
        Scenario = [string](Get-ConfigValue -Object $receipt -Name 'Scenario' -DefaultValue '')
        Result = $resultText
        Source = [string](Get-ConfigValue -Object $receipt -Name 'Source' -DefaultValue '')
        ProofLevel = $proofLevel
        RunRoot = [string](Get-ConfigValue -Object $receipt -Name 'RunRoot' -DefaultValue '')
        TargetId = $targetId
        AcceptanceState = [string](Get-ConfigValue -Object $receipt -Name 'AcceptanceState' -DefaultValue '')
        AcceptanceReason = [string](Get-ConfigValue -Object $receipt -Name 'AcceptanceReason' -DefaultValue '')
        CycleCount = [int](Get-ConfigValue -Object $receipt -Name 'CycleCount' -DefaultValue 0)
        MaxCycleCount = [int](Get-ConfigValue -Object $receipt -Name 'MaxCycleCount' -DefaultValue 0)
        FinalPhase = $finalPhase
        WatcherStopReason = $watcherStopReason
        CompletedAt = $completedAt
    }
}

function New-TargetAutoloopSmokeReceiptDocument {
    param(
        [string]$Scenario = '',
        [string]$Result = 'unknown',
        [string]$Source = '',
        [string]$ProofLevel = '',
        [string]$RunRoot = '',
        [string]$TargetId = '',
        [string]$AcceptanceState = '',
        [string]$AcceptanceReason = '',
        [int]$CycleCount = 0,
        [int]$MaxCycleCount = 0,
        [string]$FinalPhase = '',
        [string]$WatcherStopReason = '',
        [string]$CompletedAt = ''
    )

    if (-not (Test-NonEmptyString $CompletedAt)) {
        $CompletedAt = (Get-Date).ToString('o')
    }

    return ConvertTo-TargetAutoloopSmokeReceiptDocument -Payload ([ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        ReceiptKind = 'target-autoloop-smoke'
        Scenario = $Scenario
        Result = $Result
        Source = $Source
        ProofLevel = $ProofLevel
        RunRoot = $RunRoot
        TargetId = $TargetId
        AcceptanceState = $AcceptanceState
        AcceptanceReason = $AcceptanceReason
        CycleCount = $CycleCount
        MaxCycleCount = $MaxCycleCount
        FinalPhase = $FinalPhase
        WatcherStopReason = $WatcherStopReason
        CompletedAt = $CompletedAt
    })
}

function Write-TargetAutoloopSmokeReceipt {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Scenario = '',
        [string]$Result = 'unknown',
        [string]$Source = '',
        [string]$ProofLevel = '',
        [string]$RunRoot = '',
        [string]$TargetId = '',
        [string]$AcceptanceState = '',
        [string]$AcceptanceReason = '',
        [int]$CycleCount = 0,
        [int]$MaxCycleCount = 0,
        [string]$FinalPhase = '',
        [string]$WatcherStopReason = '',
        [string]$CompletedAt = ''
    )

    $payload = New-TargetAutoloopSmokeReceiptDocument `
        -Scenario $Scenario `
        -Result $Result `
        -Source $Source `
        -ProofLevel $ProofLevel `
        -RunRoot $RunRoot `
        -TargetId $TargetId `
        -AcceptanceState $AcceptanceState `
        -AcceptanceReason $AcceptanceReason `
        -CycleCount $CycleCount `
        -MaxCycleCount $MaxCycleCount `
        -FinalPhase $FinalPhase `
        -WatcherStopReason $WatcherStopReason `
        -CompletedAt $CompletedAt

    Write-JsonFileAtomically -Path $Path -Payload $payload
    return $payload
}

function Get-TargetAutoloopSmokeReceiptSummary {
    param([Parameter(Mandatory)][string]$Path)

    $result = [ordered]@{
        Path = [string]$Path
        Exists = $false
        Error = ''
        Result = 'none'
        Scenario = ''
        Source = ''
        ProofLevel = ''
        TargetId = ''
        AcceptanceState = ''
        AcceptanceReason = ''
        CycleCount = 0
        MaxCycleCount = 0
        FinalPhase = ''
        WatcherStopReason = ''
        CompletedAt = ''
        Summary = 'smoke: (없음)'
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $result.Exists = $true
    try {
        $payload = Read-JsonObject -Path $Path
    }
    catch {
        $result.Error = $_.Exception.Message
        $result.Result = 'invalid'
        $result.Summary = ('smoke: invalid / read-error={0}' -f $result.Error)
        return [pscustomobject]$result
    }

    $canonicalPayload = ConvertTo-TargetAutoloopSmokeReceiptDocument -Payload $payload
    $resultText = [string](Get-ConfigValue -Object $canonicalPayload -Name 'Result' -DefaultValue 'unknown')
    $scenario = [string](Get-ConfigValue -Object $canonicalPayload -Name 'Scenario' -DefaultValue '')
    $source = [string](Get-ConfigValue -Object $canonicalPayload -Name 'Source' -DefaultValue '')
    $proofLevel = [string](Get-ConfigValue -Object $canonicalPayload -Name 'ProofLevel' -DefaultValue '')
    $targetId = [string](Get-ConfigValue -Object $canonicalPayload -Name 'TargetId' -DefaultValue '')
    $acceptanceState = [string](Get-ConfigValue -Object $canonicalPayload -Name 'AcceptanceState' -DefaultValue '')
    $acceptanceReason = [string](Get-ConfigValue -Object $canonicalPayload -Name 'AcceptanceReason' -DefaultValue '')
    $cycleCount = [int](Get-ConfigValue -Object $canonicalPayload -Name 'CycleCount' -DefaultValue 0)
    $maxCycleCount = [int](Get-ConfigValue -Object $canonicalPayload -Name 'MaxCycleCount' -DefaultValue 0)
    $finalPhase = [string](Get-ConfigValue -Object $canonicalPayload -Name 'FinalPhase' -DefaultValue '')
    $watcherStopReason = [string](Get-ConfigValue -Object $canonicalPayload -Name 'WatcherStopReason' -DefaultValue '')
    $completedAt = [string](Get-ConfigValue -Object $canonicalPayload -Name 'CompletedAt' -DefaultValue '')

    $summary = ('smoke: {0}' -f $resultText)
    if (Test-NonEmptyString $proofLevel) {
        $summary += (' / proof={0}' -f $proofLevel)
    }
    if (Test-NonEmptyString $source) {
        $summary += (' / source={0}' -f $source)
    }
    if (Test-NonEmptyString $targetId) {
        $summary += (' / target={0}' -f $targetId)
    }
    if (Test-NonEmptyString $acceptanceState) {
        $summary += (' / acceptance={0}' -f $acceptanceState)
    }
    if (Test-NonEmptyString $acceptanceReason) {
        $summary += (' / reason={0}' -f $acceptanceReason)
    }
    if ($maxCycleCount -gt 0) {
        $summary += (' / cycle={0}/{1}' -f $cycleCount, $maxCycleCount)
    }
    elseif ($cycleCount -gt 0) {
        $summary += (' / cycle={0}' -f $cycleCount)
    }
    if (Test-NonEmptyString $finalPhase) {
        $summary += (' / phase={0}' -f $finalPhase)
    }
    if (Test-NonEmptyString $watcherStopReason) {
        $summary += (' / stop={0}' -f $watcherStopReason)
    }

    $result.Result = $resultText
    $result.Scenario = $scenario
    $result.Source = $source
    $result.ProofLevel = $proofLevel
    $result.TargetId = $targetId
    $result.AcceptanceState = $acceptanceState
    $result.AcceptanceReason = $acceptanceReason
    $result.CycleCount = $cycleCount
    $result.MaxCycleCount = $maxCycleCount
    $result.FinalPhase = $finalPhase
    $result.WatcherStopReason = $watcherStopReason
    $result.CompletedAt = $completedAt
    $result.Summary = $summary
    return [pscustomobject]$result
}

function Test-TargetAutoloopVisibleAcceptanceSuccessState {
    param([string]$AcceptanceState)

    return ($AcceptanceState -in @('roundtrip-confirmed', 'first-handoff-confirmed'))
}

function Get-TargetAutoloopVisibleAcceptanceProofSummary {
    param(
        [Parameter(Mandatory)][string]$Path,
        $TargetRows = @()
    )

    $result = [ordered]@{
        Path = [string]$Path
        Exists = $false
        Error = ''
        Result = 'none'
        Scenario = 'shared-visible-acceptance'
        Source = 'shared-visible-acceptance'
        ProofLevel = 'visible-live'
        TargetId = ''
        AcceptanceState = ''
        AcceptanceReason = ''
        CycleCount = 0
        MaxCycleCount = 0
        FinalPhase = ''
        WatcherStopReason = ''
        CompletedAt = ''
        Summary = 'smoke: (없음)'
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $result.Exists = $true
    try {
        $payload = Read-JsonObject -Path $Path
    }
    catch {
        $result.Error = $_.Exception.Message
        $result.Result = 'invalid'
        $result.Summary = ('smoke: invalid / proof=visible-live / source=shared-visible-acceptance / read-error={0}' -f $result.Error)
        return [pscustomobject]$result
    }

    $outcome = Get-ConfigValue -Object $payload -Name 'Outcome' -DefaultValue $null
    $phaseHistory = @(Get-ConfigValue -Object $payload -Name 'PhaseHistory' -DefaultValue @())
    $currentAcceptanceState = [string](Get-ConfigValue -Object $outcome -Name 'AcceptanceState' -DefaultValue '')
    $acceptanceReason = [string](Get-ConfigValue -Object $outcome -Name 'AcceptanceReason' -DefaultValue '')
    $lastSuccessAcceptanceState = ''
    foreach ($entry in @($phaseHistory)) {
        $entryAcceptanceState = [string](Get-ConfigValue -Object $entry -Name 'AcceptanceState' -DefaultValue '')
        if (Test-TargetAutoloopVisibleAcceptanceSuccessState -AcceptanceState $entryAcceptanceState) {
            $lastSuccessAcceptanceState = $entryAcceptanceState
        }
    }

    $effectiveAcceptanceState = if (Test-TargetAutoloopVisibleAcceptanceSuccessState -AcceptanceState $currentAcceptanceState) {
        $currentAcceptanceState
    }
    elseif (Test-NonEmptyString $lastSuccessAcceptanceState) {
        $lastSuccessAcceptanceState
    }
    else {
        $currentAcceptanceState
    }

    $resultText = 'unknown'
    if (Test-TargetAutoloopVisibleAcceptanceSuccessState -AcceptanceState $effectiveAcceptanceState) {
        $resultText = 'passed'
    }
    elseif ($currentAcceptanceState -eq 'preflight-passed') {
        $resultText = 'preflight-only'
    }
    elseif ($currentAcceptanceState -eq 'manual_attention_required') {
        $resultText = 'manual-attention'
    }
    elseif ($currentAcceptanceState -eq 'pending') {
        $resultText = 'active'
    }
    elseif ($currentAcceptanceState -eq 'error') {
        $resultText = 'error'
    }
    elseif (Test-NonEmptyString $currentAcceptanceState) {
        $resultText = $currentAcceptanceState
    }

    $targetId = [string](Get-ConfigValue -Object $payload -Name 'SeedTargetId' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetId)) {
        $targetId = [string](Get-ConfigValue -Object $payload -Name 'BlockedTargetId' -DefaultValue '')
    }
    if (-not (Test-NonEmptyString $targetId)) {
        $diagnostics = Get-ConfigValue -Object $outcome -Name 'Diagnostics' -DefaultValue $null
        $seedDiagnostics = Get-ConfigValue -Object $diagnostics -Name 'Seed' -DefaultValue $null
        $targetId = [string](Get-ConfigValue -Object $seedDiagnostics -Name 'TargetId' -DefaultValue '')
    }

    $cycleCount = 0
    $maxCycleCount = 0
    if (Test-NonEmptyString $targetId) {
        foreach ($targetRow in @($TargetRows)) {
            if ([string](Get-ConfigValue -Object $targetRow -Name 'TargetId' -DefaultValue '') -ne $targetId) {
                continue
            }
            $cycleCount = [int](Get-ConfigValue -Object $targetRow -Name 'CycleCount' -DefaultValue 0)
            $maxCycleCount = [int](Get-ConfigValue -Object $targetRow -Name 'MaxCycleCount' -DefaultValue 0)
            break
        }
    }

    $finalPhase = [string](Get-ConfigValue -Object $payload -Name 'Stage' -DefaultValue '')
    $completedAt = Get-TargetAutoloopTimestampFieldText -Object $payload -Name 'LastUpdatedAt'
    if (-not (Test-NonEmptyString $completedAt)) {
        $completedAt = Get-TargetAutoloopTimestampFieldText -Object $payload -Name 'GeneratedAt'
    }

    $summary = ('smoke: {0} / proof=visible-live / source=shared-visible-acceptance' -f $resultText)
    if (Test-NonEmptyString $targetId) {
        $summary += (' / target={0}' -f $targetId)
    }
    if (Test-NonEmptyString $effectiveAcceptanceState) {
        $summary += (' / acceptance={0}' -f $effectiveAcceptanceState)
    }
    if (Test-NonEmptyString $acceptanceReason) {
        $summary += (' / reason={0}' -f $acceptanceReason)
    }
    if ($maxCycleCount -gt 0) {
        $summary += (' / cycle={0}/{1}' -f $cycleCount, $maxCycleCount)
    }
    elseif ($cycleCount -gt 0) {
        $summary += (' / cycle={0}' -f $cycleCount)
    }
    if (Test-NonEmptyString $finalPhase) {
        $summary += (' / stage={0}' -f $finalPhase)
    }

    $result.Result = $resultText
    $result.TargetId = $targetId
    $result.AcceptanceState = $effectiveAcceptanceState
    $result.AcceptanceReason = $acceptanceReason
    $result.CycleCount = $cycleCount
    $result.MaxCycleCount = $maxCycleCount
    $result.FinalPhase = $finalPhase
    $result.CompletedAt = $completedAt
    $result.Summary = $summary
    return [pscustomobject]$result
}

function Get-TargetAutoloopProofReceiptSummary {
    param(
        [Parameter(Mandatory)][string]$SmokeReceiptPath,
        [Parameter(Mandatory)][string]$AcceptanceReceiptPath,
        $TargetRows = @()
    )

    $smokeReceipt = Get-TargetAutoloopSmokeReceiptSummary -Path $SmokeReceiptPath
    if ([bool](Get-ConfigValue -Object $smokeReceipt -Name 'Exists' -DefaultValue $false)) {
        return $smokeReceipt
    }

    $visibleAcceptanceProof = Get-TargetAutoloopVisibleAcceptanceProofSummary -Path $AcceptanceReceiptPath -TargetRows @($TargetRows)
    if ([bool](Get-ConfigValue -Object $visibleAcceptanceProof -Name 'Exists' -DefaultValue $false)) {
        return $visibleAcceptanceProof
    }

    return $smokeReceipt
}

function Get-TargetAutoloopProofCloseoutSummary {
    param($ProofReceipt)

    $result = [ordered]@{
        State = 'pending-proof'
        Mode = 'not-ready'
        Reason = 'no-proof'
        RecommendedNextStep = 'script smoke 또는 shared visible acceptance evidence가 필요합니다.'
        Summary = 'closeout: pending-proof / mode=not-ready / reason=no-proof'
    }

    $proof = if ($null -ne $ProofReceipt) { $ProofReceipt } else { [ordered]@{} }
    $proofResult = [string](Get-ConfigValue -Object $proof -Name 'Result' -DefaultValue 'none')
    $proofLevel = [string](Get-ConfigValue -Object $proof -Name 'ProofLevel' -DefaultValue '')
    $proofSource = [string](Get-ConfigValue -Object $proof -Name 'Source' -DefaultValue '')

    if ($proofResult -eq 'passed' -and $proofLevel -eq 'visible-live') {
        $result.State = 'final-pass'
        $result.Mode = 'final'
        $result.Reason = 'visible-live-passed'
        $result.RecommendedNextStep = '추가 closeout 조치가 없습니다.'
    }
    elseif ($proofResult -eq 'passed') {
        $result.State = 'pending-visible-proof'
        $result.Mode = 'operational'
        $result.Reason = if (Test-NonEmptyString $proofLevel) { ('proof-passed-{0}' -f $proofLevel) } else { 'proof-passed' }
        $result.RecommendedNextStep = 'shared visible 1셀 acceptance evidence를 추가하세요.'
    }
    elseif ($proofResult -eq 'preflight-only') {
        $result.State = 'preflight-only'
        $result.Mode = 'not-ready'
        $result.Reason = 'visible-preflight-only'
        $result.RecommendedNextStep = 'shared visible active acceptance를 완료하세요.'
    }
    elseif ($proofResult -in @('manual-attention', 'error', 'invalid')) {
        $result.State = 'attention-required'
        $result.Mode = 'attention'
        $result.Reason = if ($proofResult -eq 'manual-attention') { 'manual-attention' } else { ('proof-{0}' -f $proofResult) }
        $result.RecommendedNextStep = 'proof receipt와 visible acceptance evidence를 확인하세요.'
    }
    elseif ($proofResult -eq 'active') {
        $result.State = 'proof-active'
        $result.Mode = 'in-progress'
        $result.Reason = 'visible-acceptance-active'
        $result.RecommendedNextStep = '현재 visible acceptance closeout이 진행 중입니다.'
    }

    $summary = ('closeout: {0} / mode={1} / reason={2}' -f $result.State, $result.Mode, $result.Reason)
    if (Test-NonEmptyString $proofLevel) {
        $summary += (' / proof={0}' -f $proofLevel)
    }
    if (Test-NonEmptyString $proofSource) {
        $summary += (' / source={0}' -f $proofSource)
    }
    $result.Summary = $summary
    return [pscustomobject]$result
}

function Get-TargetAutoloopDefaultSection {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config = $null
    )

    $laneName = [string](Get-ConfigValue -Object $Config -Name 'LaneName' -DefaultValue 'bottest-live-visible')
    $runtimeRoot = [string](Get-ConfigValue -Object $Config -Name 'RuntimeRoot' -DefaultValue (Join-Path $Root ('runtime\' + $laneName)))
    $defaultRoot = [ordered]@{
        Enabled                    = $false
        RunMode                    = 'target-inbox-submit'
        MutexScope                 = 'target'
        MaxConcurrentTargets       = 8
        MaxConcurrentSubmits       = 1
        DispatchQueuedCommandsInline = $true
        DefaultCooldownSeconds     = 5
        DefaultPublishReadyDispatchDelaySeconds = 0
        DefaultPublishReadyDispatchMinDelaySeconds = 0
        DefaultPublishReadyDispatchMaxDelaySeconds = 0
        DefaultMaxCycleCount       = 10
        RequireExplicitContractPath = $true
        RequireTargetMetadata      = $true
        AllowRecursiveWatch        = $false
        PollIntervalMs             = 1000
        ExternalPathPolicy         = 'permissive'
        RunRootBase                = (Join-Path $Root ('pair-test\' + $laneName + '\target-autoloop'))
        StatusRoot                 = (Join-Path $runtimeRoot 'target-autoloop\status')
        QueueRoot                  = (Join-Path $runtimeRoot 'target-autoloop\queue')
        Targets                    = @()
    }

    return [pscustomobject]$defaultRoot
}

function Test-TargetAutoloopStrictExternalPathPolicy {
    param($Config = $null)

    return ([string](Get-ConfigValue -Object $Config -Name 'ExternalPathPolicy' -DefaultValue '') -eq 'strict')
}

function Assert-TargetAutoloopExternalPath {
    param(
        [AllowEmptyString()][string]$PathValue,
        [Parameter(Mandatory)][string]$AutomationRoot,
        [Parameter(Mandatory)][string]$FieldName
    )

    if (-not (Test-NonEmptyString $PathValue)) {
        throw ('{0} must be an explicit external path when TargetAutoloop.ExternalPathPolicy=strict.' -f $FieldName)
    }

    $resolvedPath = [System.IO.Path]::GetFullPath($PathValue)
    if (Test-PathEqualsOrIsDescendant -Path $resolvedPath -BasePath $AutomationRoot) {
        throw ('{0} must be outside automation repo. automationRoot={1} path={2}' -f $FieldName, [System.IO.Path]::GetFullPath($AutomationRoot), $resolvedPath)
    }

    return $resolvedPath
}

function Resolve-TargetAutoloopConfig {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $config = Import-PowerShellDataFile -LiteralPath $resolvedConfigPath
    $defaults = Get-TargetAutoloopDefaultSection -Root $Root -Config $config
    $section = Get-ConfigValue -Object $config -Name 'TargetAutoloop' -DefaultValue @{}
    $globalTargets = @(Get-ConfigValue -Object $config -Name 'Targets' -DefaultValue @())
    $globalTargetMap = @{}
    foreach ($target in @($globalTargets)) {
        $targetId = [string](Get-ConfigValue -Object $target -Name 'Id' -DefaultValue '')
        if (-not (Test-NonEmptyString $targetId)) {
            continue
        }
        $globalTargetMap[$targetId] = $target
    }

    $runMode = [string](Get-ConfigValue -Object $section -Name 'RunMode' -DefaultValue ([string]$defaults.RunMode))
    Assert-TargetAutoloopEnum -Value $runMode -AllowedValues $script:TargetAutoloopRunModes -FieldName 'TargetAutoloop.RunMode'
    $externalPathPolicy = [string](Get-ConfigValue -Object $section -Name 'ExternalPathPolicy' -DefaultValue ([string]$defaults.ExternalPathPolicy))
    Assert-TargetAutoloopEnum -Value $externalPathPolicy -AllowedValues $script:TargetAutoloopExternalPathPolicies -FieldName 'TargetAutoloop.ExternalPathPolicy'
    $strictExternalPathPolicy = ($externalPathPolicy -eq 'strict')

    $mutexScope = [string](Get-ConfigValue -Object $section -Name 'MutexScope' -DefaultValue ([string]$defaults.MutexScope))
    if ($mutexScope -ne 'target') {
        throw 'TargetAutoloop.MutexScope must be target.'
    }

    $maxConcurrentTargets = [int](Get-ConfigValue -Object $section -Name 'MaxConcurrentTargets' -DefaultValue ([int]$defaults.MaxConcurrentTargets))
    $maxConcurrentSubmits = [int](Get-ConfigValue -Object $section -Name 'MaxConcurrentSubmits' -DefaultValue ([int]$defaults.MaxConcurrentSubmits))
    $dispatchQueuedCommandsInline = [bool](Get-ConfigValue -Object $section -Name 'DispatchQueuedCommandsInline' -DefaultValue ([bool]$defaults.DispatchQueuedCommandsInline))
    $defaultCooldownSeconds = [int](Get-ConfigValue -Object $section -Name 'DefaultCooldownSeconds' -DefaultValue ([int]$defaults.DefaultCooldownSeconds))
    $defaultDelayPolicy = Resolve-TargetAutoloopDispatchDelayPolicy `
        -Source $section `
        -FixedFieldName 'DefaultPublishReadyDispatchDelaySeconds' `
        -MinFieldName 'DefaultPublishReadyDispatchMinDelaySeconds' `
        -MaxFieldName 'DefaultPublishReadyDispatchMaxDelaySeconds' `
        -InheritedMinDelaySeconds ([int]$defaults.DefaultPublishReadyDispatchMinDelaySeconds) `
        -InheritedMaxDelaySeconds ([int]$defaults.DefaultPublishReadyDispatchMaxDelaySeconds) `
        -ContextLabel 'TargetAutoloop'
    $defaultPublishReadyDispatchDelaySeconds = [int]$defaultDelayPolicy.MinDelaySeconds
    $defaultPublishReadyDispatchMinDelaySeconds = [int]$defaultDelayPolicy.MinDelaySeconds
    $defaultPublishReadyDispatchMaxDelaySeconds = [int]$defaultDelayPolicy.MaxDelaySeconds
    $defaultPublishReadyDispatchDelayMode = [string]$defaultDelayPolicy.DelayMode
    $defaultMaxCycleCount = [int](Get-ConfigValue -Object $section -Name 'DefaultMaxCycleCount' -DefaultValue ([int]$defaults.DefaultMaxCycleCount))
    $pollIntervalMs = [int](Get-ConfigValue -Object $section -Name 'PollIntervalMs' -DefaultValue ([int]$defaults.PollIntervalMs))
    foreach ($numericField in @(
            @{ Name = 'TargetAutoloop.MaxConcurrentTargets'; Value = $maxConcurrentTargets },
            @{ Name = 'TargetAutoloop.MaxConcurrentSubmits'; Value = $maxConcurrentSubmits },
            @{ Name = 'TargetAutoloop.DefaultCooldownSeconds'; Value = $defaultCooldownSeconds },
            @{ Name = 'TargetAutoloop.DefaultPublishReadyDispatchDelaySeconds'; Value = $defaultPublishReadyDispatchDelaySeconds },
            @{ Name = 'TargetAutoloop.DefaultPublishReadyDispatchMinDelaySeconds'; Value = $defaultPublishReadyDispatchMinDelaySeconds },
            @{ Name = 'TargetAutoloop.DefaultPublishReadyDispatchMaxDelaySeconds'; Value = $defaultPublishReadyDispatchMaxDelaySeconds },
            @{ Name = 'TargetAutoloop.DefaultMaxCycleCount'; Value = $defaultMaxCycleCount },
            @{ Name = 'TargetAutoloop.PollIntervalMs'; Value = $pollIntervalMs }
        )) {
        if ([int]$numericField.Value -lt 0) {
            throw ($numericField.Name + ' must be a non-negative integer.')
        }
    }

    $enabledDefault = [bool](Get-ConfigValue -Object $section -Name 'Enabled' -DefaultValue ([bool]$defaults.Enabled))
    $requireExplicitContractPath = [bool](Get-ConfigValue -Object $section -Name 'RequireExplicitContractPath' -DefaultValue ([bool]$defaults.RequireExplicitContractPath))
    $requireTargetMetadata = [bool](Get-ConfigValue -Object $section -Name 'RequireTargetMetadata' -DefaultValue ([bool]$defaults.RequireTargetMetadata))
    $allowRecursiveWatch = [bool](Get-ConfigValue -Object $section -Name 'AllowRecursiveWatch' -DefaultValue ([bool]$defaults.AllowRecursiveWatch))
    if ($allowRecursiveWatch) {
        throw 'TargetAutoloop.AllowRecursiveWatch must remain false for strict explicit contract watching.'
    }

    $runRootBase = Resolve-FullPathFromBase -PathValue ([string](Get-ConfigValue -Object $section -Name 'RunRootBase' -DefaultValue ([string]$defaults.RunRootBase))) -BasePath $Root
    $statusRoot = Resolve-FullPathFromBase -PathValue ([string](Get-ConfigValue -Object $section -Name 'StatusRoot' -DefaultValue ([string]$defaults.StatusRoot))) -BasePath $Root
    $queueRoot = Resolve-FullPathFromBase -PathValue ([string](Get-ConfigValue -Object $section -Name 'QueueRoot' -DefaultValue ([string]$defaults.QueueRoot))) -BasePath $Root
    if ($strictExternalPathPolicy) {
        $runRootBase = Assert-TargetAutoloopExternalPath -PathValue $runRootBase -AutomationRoot $Root -FieldName 'TargetAutoloop.RunRootBase'
        $statusRoot = Assert-TargetAutoloopExternalPath -PathValue $statusRoot -AutomationRoot $Root -FieldName 'TargetAutoloop.StatusRoot'
        $queueRoot = Assert-TargetAutoloopExternalPath -PathValue $queueRoot -AutomationRoot $Root -FieldName 'TargetAutoloop.QueueRoot'
    }

    $rawTargets = @(Get-ConfigValue -Object $section -Name 'Targets' -DefaultValue @())
    if (@($rawTargets).Count -eq 0 -and @($globalTargets).Count -gt 0) {
        $rawTargets = @(
            foreach ($globalTarget in @($globalTargets)) {
                [pscustomobject]@{
                    TargetId = [string](Get-ConfigValue -Object $globalTarget -Name 'Id' -DefaultValue '')
                    Enabled = $enabledDefault
                }
            }
        )
    }

    $resolvedTargets = New-Object System.Collections.Generic.List[object]
    $resolvedTargetIds = @{}
    $defaultTriggerKinds = if ($runMode -eq 'target-autoloop') { @('input-file', 'publish-ready') } else { @('input-file') }
    foreach ($targetRow in @($rawTargets)) {
        $targetId = [string](Get-ConfigValue -Object $targetRow -Name 'TargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $targetId)) {
            throw 'TargetAutoloop.Targets entry is missing TargetId.'
        }
        if ($resolvedTargetIds.ContainsKey($targetId)) {
            throw ('TargetAutoloop.Targets contains a duplicate TargetId: {0}' -f $targetId)
        }
        $resolvedTargetIds[$targetId] = $true

        $globalTarget = Get-ConfigValue -Object $globalTargetMap -Name $targetId -DefaultValue $null
        if ($requireTargetMetadata -and $null -eq $globalTarget) {
            throw ('TargetAutoloop.Targets.{0} must match an existing Targets entry.' -f $targetId)
        }

        $triggerKinds = @(
            Get-StringArray (Get-ConfigValue -Object $targetRow -Name 'TriggerKinds' -DefaultValue $defaultTriggerKinds)
        )
        if (@($triggerKinds).Count -eq 0) {
            throw ('TargetAutoloop.Targets.{0}.TriggerKinds must not be empty.' -f $targetId)
        }
        foreach ($triggerKind in @($triggerKinds)) {
            Assert-TargetAutoloopEnum -Value ([string]$triggerKind) -AllowedValues $script:TargetAutoloopTriggerKinds -FieldName ("TargetAutoloop.Targets.{0}.TriggerKinds" -f $targetId)
            if ($runMode -eq 'target-inbox-submit' -and [string]$triggerKind -eq 'publish-ready') {
                throw ('TargetAutoloop.Targets.{0}.TriggerKinds cannot include publish-ready when RunMode is target-inbox-submit.' -f $targetId)
            }
        }

        $targetEnabled = [bool](Get-ConfigValue -Object $targetRow -Name 'Enabled' -DefaultValue $enabledDefault)
        $workRepoRootRaw = [string](Get-ConfigValue -Object $targetRow -Name 'WorkRepoRoot' -DefaultValue '')
        $workRepoRoot = ''
        if (Test-NonEmptyString $workRepoRootRaw) {
            $workRepoRoot = Resolve-FullPathFromBase -PathValue $workRepoRootRaw -BasePath $Root
            if ($strictExternalPathPolicy) {
                $workRepoRoot = Assert-TargetAutoloopExternalPath -PathValue $workRepoRoot -AutomationRoot $Root -FieldName ('TargetAutoloop.Targets.{0}.WorkRepoRoot' -f $targetId)
            }
            elseif (Test-PathEqualsOrIsDescendant -Path $workRepoRoot -BasePath $Root) {
                throw ('TargetAutoloop.Targets.{0}.WorkRepoRoot must be outside automation repo. automationRoot={1} workRepoRoot={2}' -f $targetId, $Root, $workRepoRoot)
            }
        }
        elseif ($strictExternalPathPolicy -and $targetEnabled) {
            throw ('TargetAutoloop.Targets.{0}.WorkRepoRoot must be an explicit external path when TargetAutoloop.ExternalPathPolicy=strict.' -f $targetId)
        }
        $fixedSuffix = [string](Get-ConfigValue -Object $targetRow -Name 'FixedSuffix' -DefaultValue ([string](Get-ConfigValue -Object $globalTarget -Name 'FixedSuffix' -DefaultValue ([string](Get-ConfigValue -Object $config -Name 'DefaultFixedSuffix' -DefaultValue '')))))
        $targetDelayPolicy = Resolve-TargetAutoloopDispatchDelayPolicy `
            -Source $targetRow `
            -FixedFieldName 'PublishReadyDispatchDelaySeconds' `
            -MinFieldName 'PublishReadyDispatchMinDelaySeconds' `
            -MaxFieldName 'PublishReadyDispatchMaxDelaySeconds' `
            -InheritedMinDelaySeconds $defaultPublishReadyDispatchMinDelaySeconds `
            -InheritedMaxDelaySeconds $defaultPublishReadyDispatchMaxDelaySeconds `
            -ContextLabel ('TargetAutoloop.Targets.{0}' -f $targetId)
        $resolvedTargets.Add([pscustomobject]@{
                TargetId = $targetId
                Enabled = $targetEnabled
                FixedSuffix = $fixedSuffix
                WorkRepoRoot = $workRepoRoot
                InboxPath = [string](Get-ConfigValue -Object $targetRow -Name 'InboxPath' -DefaultValue '')
                ContractPath = [string](Get-ConfigValue -Object $targetRow -Name 'ContractPath' -DefaultValue '')
                CooldownSeconds = [int](Get-ConfigValue -Object $targetRow -Name 'CooldownSeconds' -DefaultValue $defaultCooldownSeconds)
                PublishReadyDispatchDelayMode = [string]$targetDelayPolicy.DelayMode
                PublishReadyDispatchDelaySeconds = [int]$targetDelayPolicy.MinDelaySeconds
                PublishReadyDispatchMinDelaySeconds = [int]$targetDelayPolicy.MinDelaySeconds
                PublishReadyDispatchMaxDelaySeconds = [int]$targetDelayPolicy.MaxDelaySeconds
                MaxCycleCount = [int](Get-ConfigValue -Object $targetRow -Name 'MaxCycleCount' -DefaultValue $defaultMaxCycleCount)
                TriggerKinds = @($triggerKinds)
                GlobalFolder = [string](Get-ConfigValue -Object $globalTarget -Name 'Folder' -DefaultValue '')
                WindowTitle = [string](Get-ConfigValue -Object $globalTarget -Name 'WindowTitle' -DefaultValue '')
            }) | Out-Null
    }

    $resolvedTargetsArray = $resolvedTargets.ToArray()
    $supportedTargetIds = @($globalTargetMap.Keys | Sort-Object)

    return [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Root = $Root
        ConfigPath = $resolvedConfigPath
        LaneName = [string](Get-ConfigValue -Object $config -Name 'LaneName' -DefaultValue 'bottest-live-visible')
        InboxRoot = [string](Get-ConfigValue -Object $config -Name 'InboxRoot' -DefaultValue '')
        RetryPendingRoot = [string](Get-ConfigValue -Object $config -Name 'RetryPendingRoot' -DefaultValue '')
        RuntimeMapPath = [string](Get-ConfigValue -Object $config -Name 'RuntimeMapPath' -DefaultValue '')
        RouterStatePath = [string](Get-ConfigValue -Object $config -Name 'RouterStatePath' -DefaultValue '')
        RouterMutexName = [string](Get-ConfigValue -Object $config -Name 'RouterMutexName' -DefaultValue '')
        Enabled = $enabledDefault
        RunMode = $runMode
        ExternalPathPolicy = $externalPathPolicy
        MutexScope = $mutexScope
        MaxConcurrentTargets = $maxConcurrentTargets
        MaxConcurrentSubmits = $maxConcurrentSubmits
        DispatchQueuedCommandsInline = $dispatchQueuedCommandsInline
        DefaultCooldownSeconds = $defaultCooldownSeconds
        DefaultPublishReadyDispatchDelayMode = $defaultPublishReadyDispatchDelayMode
        DefaultPublishReadyDispatchDelaySeconds = $defaultPublishReadyDispatchDelaySeconds
        DefaultPublishReadyDispatchMinDelaySeconds = $defaultPublishReadyDispatchMinDelaySeconds
        DefaultPublishReadyDispatchMaxDelaySeconds = $defaultPublishReadyDispatchMaxDelaySeconds
        DefaultMaxCycleCount = $defaultMaxCycleCount
        RequireExplicitContractPath = $requireExplicitContractPath
        RequireTargetMetadata = $requireTargetMetadata
        AllowRecursiveWatch = $allowRecursiveWatch
        PollIntervalMs = $pollIntervalMs
        RunRootBase = $runRootBase
        StatusRoot = $statusRoot
        QueueRoot = $queueRoot
        StateFileName = 'target-state.json'
        StatusFileName = 'target-autoloop-status.json'
        ControlFileName = 'target-autoloop-control.json'
        EventsFileName = 'target-events.jsonl'
        Targets = $resolvedTargetsArray
        SupportedTargetIds = $supportedTargetIds
    }
}

function Resolve-TargetAutoloopRunRoot {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$RequestedRunRoot = ''
    )

    if (Test-NonEmptyString $RequestedRunRoot) {
        if ([System.IO.Path]::IsPathRooted($RequestedRunRoot)) {
            return [System.IO.Path]::GetFullPath($RequestedRunRoot)
        }

        return [System.IO.Path]::GetFullPath((Join-Path ([string]$Config.Root) $RequestedRunRoot))
    }

    $runRootBase = [string]$Config.RunRootBase
    if (-not (Test-Path -LiteralPath $runRootBase -PathType Container)) {
        throw "target autoloop run root base not found: $runRootBase"
    }

    $latest = Get-ChildItem -LiteralPath $runRootBase -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        throw "no target autoloop run root found under: $runRootBase"
    }

    return $latest.FullName
}

function Get-TargetAutoloopManifestRouteSummary {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RunRoot,
        [ValidateSet('Status', 'RouteMatrix', 'ProofDoctor')]
        [string]$Mode = 'Status'
    )

    $manifestPath = Join-Path $RunRoot 'manifest.json'
    $manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $manifestDocument = if ($manifestExists) { Read-JsonObject -Path $manifestPath } else { [pscustomobject]@{} }
    $manifestRunMode = [string](Get-ConfigValue -Object $manifestDocument -Name 'RunMode' -DefaultValue '')
    $manifestTargetRows = @(Get-ConfigValue -Object $manifestDocument -Name 'Targets' -DefaultValue @())
    $manifestTargetMap = @{}
    $manifestTargetIds = @()
    $manifestEnabledTargetIds = @()
    $manifestPublishReadyTargetIds = @()
    $manifestPublishReadyMissingTargetIds = @()
    foreach ($manifestTarget in @($manifestTargetRows)) {
        $manifestTargetId = [string](Get-ConfigValue -Object $manifestTarget -Name 'TargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $manifestTargetId)) {
            continue
        }

        $manifestTargetMap[$manifestTargetId] = $manifestTarget
        $manifestTargetIds += $manifestTargetId
        if (-not [bool](Get-ConfigValue -Object $manifestTarget -Name 'Enabled' -DefaultValue $false)) {
            continue
        }

        $manifestEnabledTargetIds += $manifestTargetId
        $triggerKinds = @(Get-StringArray (Get-ConfigValue -Object $manifestTarget -Name 'TriggerKinds' -DefaultValue @()))
        if ($triggerKinds -contains 'publish-ready') {
            $manifestPublishReadyTargetIds += $manifestTargetId
        }
        else {
            $manifestPublishReadyMissingTargetIds += $manifestTargetId
        }
    }

    $configTargetIds = @(
        $Config.Targets |
            ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') } |
            Where-Object { Test-NonEmptyString $_ } |
            Sort-Object
    )
    $configEnabledTargetIds = @(
        $Config.Targets |
            Where-Object { [bool](Get-ConfigValue -Object $_ -Name 'Enabled' -DefaultValue $false) } |
            ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') } |
            Where-Object { Test-NonEmptyString $_ } |
            Sort-Object
    )
    $sortedManifestTargetIds = @($manifestTargetIds | Sort-Object)
    $sortedManifestEnabledTargetIds = @($manifestEnabledTargetIds | Sort-Object)
    $sortedManifestPublishReadyTargetIds = @($manifestPublishReadyTargetIds | Sort-Object)
    $sortedManifestPublishReadyMissingTargetIds = @($manifestPublishReadyMissingTargetIds | Sort-Object)

    $configTargetSet = @{}
    foreach ($targetId in @($configTargetIds)) {
        if (Test-NonEmptyString $targetId) {
            $configTargetSet[$targetId] = $true
        }
    }
    $configEnabledTargetSet = @{}
    foreach ($targetId in @($configEnabledTargetIds)) {
        if (Test-NonEmptyString $targetId) {
            $configEnabledTargetSet[$targetId] = $true
        }
    }

    $unknownManifestTargetIds = @($sortedManifestTargetIds | Where-Object { -not $configTargetSet.ContainsKey([string]$_) })
    $configEnabledTargetIdsInManifestScope = @(
        $sortedManifestTargetIds |
            Where-Object { $configEnabledTargetSet.ContainsKey([string]$_) } |
            Sort-Object
    )

    $manifestScope = 'none'
    if (@($sortedManifestTargetIds).Count -gt 0) {
        if (@($unknownManifestTargetIds).Count -gt 0) {
            $manifestScope = 'unknown-targets'
        }
        elseif (@($sortedManifestTargetIds).Count -lt @($configTargetIds).Count) {
            $manifestScope = 'selected-targets'
        }
        elseif ((@($sortedManifestTargetIds) -join ',') -eq (@($configTargetIds) -join ',')) {
            $manifestScope = 'all-config-targets'
        }
        else {
            $manifestScope = 'custom-targets'
        }
    }

    $routeMatrixMismatchReasons = @()
    $routeMatrixReasonCodes = @()
    if (-not $manifestExists) {
        $routeMatrixMismatchReasons += 'manifest-missing'
        $routeMatrixReasonCodes += 'manifest-missing'
    }
    else {
        if ((Test-NonEmptyString $manifestRunMode) -and $manifestRunMode -ne 'target-autoloop') {
            $routeMatrixMismatchReasons += ('run-mode={0}' -f $manifestRunMode)
            $routeMatrixReasonCodes += 'run-mode-mismatch'
        }
        if ((@($configTargetIds) -join ',') -ne (@($sortedManifestTargetIds) -join ',')) {
            $routeMatrixMismatchReasons += ('target-set-differ config={0} manifest={1}' -f
                $(if (@($configTargetIds).Count -gt 0) { @($configTargetIds) -join ',' } else { '(none)' }),
                $(if (@($sortedManifestTargetIds).Count -gt 0) { @($sortedManifestTargetIds) -join ',' } else { '(none)' }))
            $routeMatrixReasonCodes += 'target-set-differ'
        }
        if ((@($configEnabledTargetIds) -join ',') -ne (@($sortedManifestEnabledTargetIds) -join ',')) {
            $routeMatrixMismatchReasons += ('enabled-targets-differ config={0} manifest={1}' -f
                $(if (@($configEnabledTargetIds).Count -gt 0) { @($configEnabledTargetIds) -join ',' } else { '(none)' }),
                $(if (@($sortedManifestEnabledTargetIds).Count -gt 0) { @($sortedManifestEnabledTargetIds) -join ',' } else { '(none)' }))
            $routeMatrixReasonCodes += 'enabled-targets-differ'
        }
        if (@($sortedManifestPublishReadyMissingTargetIds).Count -gt 0) {
            $routeMatrixMismatchReasons += ('publish-ready-missing={0}' -f (@($sortedManifestPublishReadyMissingTargetIds) -join ','))
            $routeMatrixReasonCodes += 'publish-ready-missing'
        }
    }

    $proofDoctorMismatchReasons = @()
    $proofDoctorReasonCodes = @()
    if (-not $manifestExists) {
        $proofDoctorMismatchReasons += 'manifest-missing'
        $proofDoctorReasonCodes += 'manifest-missing'
    }
    else {
        if ((Test-NonEmptyString $manifestRunMode) -and $manifestRunMode -ne 'target-autoloop') {
            $proofDoctorMismatchReasons += ('run-mode={0}' -f $manifestRunMode)
            $proofDoctorReasonCodes += 'run-mode-mismatch'
        }
        if (@($sortedManifestTargetIds).Count -eq 0 -and @($configEnabledTargetIds).Count -gt 0) {
            $proofDoctorMismatchReasons += 'manifest-targets-empty'
            $proofDoctorReasonCodes += 'manifest-targets-empty'
        }
        if (@($unknownManifestTargetIds).Count -gt 0) {
            $proofDoctorMismatchReasons += ('unknown-manifest-targets={0}' -f (@($unknownManifestTargetIds) -join ','))
            $proofDoctorReasonCodes += 'unknown-manifest-targets'
        }
        if ((@($configEnabledTargetIdsInManifestScope) -join ',') -ne (@($sortedManifestEnabledTargetIds) -join ',')) {
            $proofDoctorMismatchReasons += ('enabled-targets-differ config-scope={0} manifest={1}' -f
                $(if (@($configEnabledTargetIdsInManifestScope).Count -gt 0) { @($configEnabledTargetIdsInManifestScope) -join ',' } else { '(none)' }),
                $(if (@($sortedManifestEnabledTargetIds).Count -gt 0) { @($sortedManifestEnabledTargetIds) -join ',' } else { '(none)' }))
            $proofDoctorReasonCodes += 'enabled-targets-differ'
        }
        if (@($sortedManifestPublishReadyMissingTargetIds).Count -gt 0) {
            $proofDoctorMismatchReasons += ('publish-ready-missing={0}' -f (@($sortedManifestPublishReadyMissingTargetIds) -join ','))
            $proofDoctorReasonCodes += 'publish-ready-missing'
        }
    }

    $selectedReasons = if ($Mode -eq 'ProofDoctor') { @($proofDoctorMismatchReasons) } elseif ($Mode -eq 'RouteMatrix') { @($routeMatrixMismatchReasons) } else { @() }
    $selectedReasonCodes = if ($Mode -eq 'ProofDoctor') { @($proofDoctorReasonCodes) } elseif ($Mode -eq 'RouteMatrix') { @($routeMatrixReasonCodes) } else { @() }
    $manifestMismatch = @($selectedReasons).Count -gt 0
    $operationalRecommendation = if ($Mode -eq 'ProofDoctor' -and $manifestMismatch -and @($sortedManifestEnabledTargetIds).Count -eq 0 -and @($configEnabledTargetIds).Count -gt 0) {
        '새 RunRoot 준비 후 감지 시작'
    }
    elseif ($Mode -eq 'ProofDoctor' -and $manifestMismatch -and @($sortedManifestPublishReadyMissingTargetIds).Count -gt 0) {
        'publish-ready 켜고 새 RunRoot 준비'
    }
    elseif ($Mode -eq 'ProofDoctor' -and $manifestMismatch) {
        '현재 RunRoot manifest와 config가 다릅니다. 새 RunRoot 준비 후 감지 시작을 권장합니다.'
    }
    else {
        ''
    }

    return [pscustomobject][ordered]@{
        Mode = [string]$Mode
        RunRoot = [string]$RunRoot
        ManifestPath = [string]$manifestPath
        ManifestExists = [bool]$manifestExists
        ManifestDocument = $manifestDocument
        ManifestRunMode = [string]$manifestRunMode
        ManifestTargetRows = @($manifestTargetRows)
        ManifestTargetMap = $manifestTargetMap
        ManifestTargetIds = @($manifestTargetIds)
        ManifestEnabledTargetIds = @($manifestEnabledTargetIds)
        ManifestPublishReadyTargetIds = @($manifestPublishReadyTargetIds)
        ManifestPublishReadyMissingTargetIds = @($manifestPublishReadyMissingTargetIds)
        SortedManifestTargetIds = @($sortedManifestTargetIds)
        SortedManifestEnabledTargetIds = @($sortedManifestEnabledTargetIds)
        SortedManifestPublishReadyTargetIds = @($sortedManifestPublishReadyTargetIds)
        SortedManifestPublishReadyMissingTargetIds = @($sortedManifestPublishReadyMissingTargetIds)
        ConfigTargetIds = @($configTargetIds)
        ConfigEnabledTargetIds = @($configEnabledTargetIds)
        ConfigEnabledTargetIdsInManifestScope = @($configEnabledTargetIdsInManifestScope)
        UnknownManifestTargetIds = @($unknownManifestTargetIds)
        ManifestScope = [string]$manifestScope
        RouteMatrixMismatch = @($routeMatrixMismatchReasons).Count -gt 0
        RouteMatrixMismatchReasons = @($routeMatrixMismatchReasons)
        RouteMatrixMismatchReason = $(if (@($routeMatrixMismatchReasons).Count -gt 0) { @($routeMatrixMismatchReasons) -join '; ' } else { '' })
        RouteMatrixReasonCodes = @($routeMatrixReasonCodes)
        ProofDoctorMismatch = @($proofDoctorMismatchReasons).Count -gt 0
        ProofDoctorMismatchReasons = @($proofDoctorMismatchReasons)
        ProofDoctorMismatchReason = $(if (@($proofDoctorMismatchReasons).Count -gt 0) { @($proofDoctorMismatchReasons) -join '; ' } else { '' })
        ProofDoctorReasonCodes = @($proofDoctorReasonCodes)
        ManifestMismatch = [bool]$manifestMismatch
        ManifestMismatchReasons = @($selectedReasons)
        ManifestMismatchReason = $(if ($manifestMismatch) { @($selectedReasons) -join '; ' } else { '' })
        ReasonCodes = @($selectedReasonCodes)
        BlockingReasonCodes = @($selectedReasonCodes)
        OperationalRecommendation = [string]$operationalRecommendation
    }
}

function Get-TargetAutoloopManifestRouteTextLines {
    param(
        [Parameter(Mandatory)]$Payload,
        [switch]$IncludeScope,
        [switch]$IncludeOperationalRecommendation
    )

    $manifestTargetIds = @(Get-ConfigValue -Object $Payload -Name 'ManifestTargetIds' -DefaultValue @())
    $manifestEnabledTargetIds = @(Get-ConfigValue -Object $Payload -Name 'ManifestEnabledTargetIds' -DefaultValue @())
    $manifestRunMode = [string](Get-ConfigValue -Object $Payload -Name 'ManifestRunMode' -DefaultValue '')
    $manifestMismatchReason = [string](Get-ConfigValue -Object $Payload -Name 'ManifestMismatchReason' -DefaultValue '')
    $lines = @(
        ('Manifest: exists={0} runMode={1} targets={2} enabled={3} mismatch={4} reason={5}' -f
            [bool](Get-ConfigValue -Object $Payload -Name 'ManifestExists' -DefaultValue $false),
            $(if (Test-NonEmptyString $manifestRunMode) { $manifestRunMode } else { '(none)' }),
            $(if (@($manifestTargetIds).Count -gt 0) { @($manifestTargetIds) -join ',' } else { '(none)' }),
            $(if (@($manifestEnabledTargetIds).Count -gt 0) { @($manifestEnabledTargetIds) -join ',' } else { '(none)' }),
            [bool](Get-ConfigValue -Object $Payload -Name 'ManifestMismatch' -DefaultValue $false),
            $(if (Test-NonEmptyString $manifestMismatchReason) { $manifestMismatchReason } else { '(none)' }))
    )

    if ([bool]$IncludeScope) {
        $manifestScope = [string](Get-ConfigValue -Object $Payload -Name 'ManifestScope' -DefaultValue '')
        $lines += ('ManifestScope: ' + $(if (Test-NonEmptyString $manifestScope) { $manifestScope } else { '(none)' }))
    }

    if ([bool]$IncludeOperationalRecommendation) {
        $operationalRecommendation = [string](Get-ConfigValue -Object $Payload -Name 'OperationalRecommendation' -DefaultValue '')
        $lines += ('OperationalRecommendation: ' + $(if (Test-NonEmptyString $operationalRecommendation) { $operationalRecommendation } else { '(none)' }))
    }

    return @($lines)
}

function Get-TargetAutoloopRouteRowManifestTextLine {
    param(
        [Parameter(Mandatory)]$Row,
        [string]$Indent = '  '
    )

    $line = ('{0}manifest: inManifest={1} manifestEnabled={2}' -f
        $Indent,
        [bool](Get-ConfigValue -Object $Row -Name 'InManifest' -DefaultValue $false),
        [bool](Get-ConfigValue -Object $Row -Name 'ManifestEnabled' -DefaultValue $false))
    $routeScope = [string](Get-ConfigValue -Object $Row -Name 'RouteScope' -DefaultValue '')
    $routeScopeReason = [string](Get-ConfigValue -Object $Row -Name 'RouteScopeReason' -DefaultValue '')
    if (Test-NonEmptyString $routeScope) {
        $line += (' routeScope={0}' -f $routeScope)
    }
    if (Test-NonEmptyString $routeScopeReason) {
        $line += (' reason={0}' -f $routeScopeReason)
    }
    return $line
}

function Get-TargetAutoloopRouteScopeState {
    param(
        [bool]$ManifestExists = $false,
        [AllowEmptyString()][string]$ManifestRunMode = '',
        [bool]$InManifest = $false
    )

    if (-not $ManifestExists) {
        return [pscustomobject][ordered]@{
            Scope = 'manifest-missing'
            Active = $false
            Reason = 'runroot-manifest-missing'
        }
    }

    if ($ManifestExists -and $ManifestRunMode -eq 'target-autoloop' -and -not $InManifest) {
        return [pscustomobject][ordered]@{
            Scope = 'outside-current-manifest'
            Active = $false
            Reason = 'target-not-in-current-run-manifest'
        }
    }

    return [pscustomobject][ordered]@{
        Scope = 'current-run'
        Active = $true
        Reason = ''
    }
}

function Get-TargetAutoloopRouteBadgeForScope {
    param(
        [bool]$Enabled = $false,
        [AllowEmptyString()][string]$ContractState = '',
        [bool]$RouteScopeActive = $true,
        [AllowEmptyString()][string]$RouteScope = ''
    )

    if (-not $Enabled) {
        return 'DISABLED'
    }
    if (-not $RouteScopeActive) {
        if ($RouteScope -eq 'manifest-missing' -and $ContractState -eq 'missing') {
            return 'ROUTE EMPTY'
        }
        return 'ROUTE OUT'
    }
    if ($ContractState -eq 'ready') {
        return 'ROUTE READY'
    }
    if ($ContractState -in @('partial', 'invalid')) {
        return 'ROUTE CHECK'
    }
    return 'ROUTE EMPTY'
}

function Get-TargetAutoloopDeliveryTextLines {
    param(
        [Parameter(Mandatory)]$Row,
        [string]$Indent = '  '
    )

    $lines = @()
    $deliverySummary = [string](Get-ConfigValue -Object $Row -Name 'DeliverySummary' -DefaultValue '')
    if (Test-NonEmptyString $deliverySummary) {
        $lines += ('{0}delivery: {1}' -f $Indent, $deliverySummary)
    }

    $deliveryNextAction = [string](Get-ConfigValue -Object $Row -Name 'DeliveryNextAction' -DefaultValue '')
    if (Test-NonEmptyString $deliveryNextAction) {
        $deliveryNextActionLabel = [string](Get-ConfigValue -Object $Row -Name 'DeliveryNextActionLabel' -DefaultValue '')
        $deliveryNextText = if (Test-NonEmptyString $deliveryNextActionLabel) {
            $deliveryNextActionLabel + ' - ' + $deliveryNextAction
        }
        else {
            $deliveryNextAction
        }
        $lines += ('{0}deliveryNext: {1}' -f $Indent, $deliveryNextText)
    }

    return @($lines)
}

function Get-TargetAutoloopStatePaths {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$Config
    )

    $stateRoot = Join-Path $RunRoot '.state'
    return [pscustomobject]@{
        StateRoot = $stateRoot
        StatePath = Join-Path $stateRoot ([string]$Config.StateFileName)
        StatusPath = Join-Path $stateRoot ([string]$Config.StatusFileName)
        ControlPath = Join-Path $stateRoot ([string]$Config.ControlFileName)
        EventsPath = Join-Path $stateRoot ([string]$Config.EventsFileName)
        SmokeReceiptPath = Join-Path $stateRoot 'target-autoloop-live-smoke-result.json'
        AcceptanceReceiptPath = Join-Path $stateRoot 'live-acceptance-result.json'
    }
}

function Get-TargetAutoloopTargetWatcherMutexName {
    param(
        [Parameter(Mandatory)][string]$TargetRunRoot,
        [Parameter(Mandatory)][string]$TargetId
    )

    $scopeKey = '{0}|{1}' -f (Get-NormalizedFullPath -Path $TargetRunRoot), ([string]$TargetId).Trim()
    $hashHex = (Get-TextHashHex -Text $scopeKey)
    $token = if ($hashHex.Length -ge 24) { $hashHex.Substring(0, 24) } else { $hashHex }
    return ('Global\RelayTargetAutoloopTarget_{0}' -f $token)
}

function Get-TargetAutoloopTargetWorkRepoRoot {
    param($Target = $null)

    if ($null -eq $Target) {
        return ''
    }

    return [string](Get-ConfigValue -Object $Target -Name 'WorkRepoRoot' -DefaultValue '')
}

function Resolve-TargetAutoloopTargetRunRoot {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        $Target = $null,
        $Config = $null
    )

    $workRepoRoot = Get-TargetAutoloopTargetWorkRepoRoot -Target $Target
    if (-not (Test-NonEmptyString $workRepoRoot)) {
        return [System.IO.Path]::GetFullPath($RunRoot)
    }

    $laneName = 'bottest-live-visible'
    if ($null -ne $Config) {
        $configuredLaneName = [string](Get-ConfigValue -Object $Config -Name 'LaneName' -DefaultValue '')
        if (Test-NonEmptyString $configuredLaneName) {
            $laneName = $configuredLaneName
        }
    }

    $resolvedRunRoot = [System.IO.Path]::GetFullPath($RunRoot)
    $runLeaf = Split-Path -Leaf $resolvedRunRoot
    if (-not (Test-NonEmptyString $runLeaf)) {
        $runLeaf = 'run'
    }

    $baseRoot = Join-Path (Join-Path (Join-Path ([System.IO.Path]::GetFullPath($workRepoRoot)) '.relay-runs') $laneName) 'target-autoloop'
    return [System.IO.Path]::GetFullPath((Join-Path $baseRoot $runLeaf))
}

function Get-TargetAutoloopQueuePaths {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId,
        $Target = $null,
        $Config = $null
    )

    $targetRunRoot = Resolve-TargetAutoloopTargetRunRoot -RunRoot $RunRoot -Target $Target -Config $Config
    $workRepoRoot = Get-TargetAutoloopTargetWorkRepoRoot -Target $Target
    $queueRoot = Join-Path $targetRunRoot (Join-Path '.queue\target-autoloop' $TargetId)
    return [pscustomobject]@{
        CoordinatorRunRoot = [System.IO.Path]::GetFullPath($RunRoot)
        TargetRunRoot = $targetRunRoot
        WorkRepoRoot = $workRepoRoot
        UsesWorkRepoRoot = (Test-NonEmptyString $workRepoRoot)
        QueueRoot = $queueRoot
        QueuedRoot = Join-Path $queueRoot 'queued'
        ProcessingRoot = Join-Path $queueRoot 'processing'
        CompletedRoot = Join-Path $queueRoot 'completed'
        FailedRoot = Join-Path $queueRoot 'failed'
        PayloadRoot = Join-Path $queueRoot 'payloads'
    }
}

function Set-TargetAutoloopPathValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = [string]$Value
        return
    }

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue ([string]$Value)
}

function Test-TargetAutoloopObjectPropertyExists {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [hashtable]) {
        return $Object.ContainsKey($Name)
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }

    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Use-TargetAutoloopManifestTargetPaths {
    param(
        [Parameter(Mandatory)]$Paths,
        $ManifestTarget = $null
    )

    if ($null -eq $ManifestTarget) {
        return $Paths
    }

    foreach ($mapping in @(
            @{ Property = 'CoordinatorRunRoot'; Field = 'CoordinatorRunRoot' },
            @{ Property = 'TargetRunRoot'; Field = 'TargetRunRoot' },
            @{ Property = 'WorkRepoRoot'; Field = 'WorkRepoRoot' },
            @{ Property = 'TargetRoot'; Field = 'TargetRoot' },
            @{ Property = 'InboxRoot'; Field = 'InboxRoot' },
            @{ Property = 'InboxPendingRoot'; Field = 'InboxPendingRoot' },
            @{ Property = 'InboxClaimedRoot'; Field = 'InboxClaimedRoot' },
            @{ Property = 'InboxProcessedRoot'; Field = 'InboxProcessedRoot' },
            @{ Property = 'InboxFailedRoot'; Field = 'InboxFailedRoot' },
            @{ Property = 'WorkRoot'; Field = 'WorkRoot' },
            @{ Property = 'CurrentRequestPath'; Field = 'CurrentRequestPath' },
            @{ Property = 'LastPromptPath'; Field = 'LastPromptPath' },
            @{ Property = 'SourceOutboxRoot'; Field = 'SourceOutboxPath' },
            @{ Property = 'SourceSummaryPath'; Field = 'SourceSummaryPath' },
            @{ Property = 'SourceReviewZipPath'; Field = 'SourceReviewZipPath' },
            @{ Property = 'PublishReadyPath'; Field = 'PublishReadyPath' },
            @{ Property = 'ReceiptsRoot'; Field = 'ReceiptsRoot' },
            @{ Property = 'TargetStateRoot'; Field = 'TargetStateRoot' },
            @{ Property = 'TargetStatePath'; Field = 'TargetStatePath' },
            @{ Property = 'TargetStatusPath'; Field = 'TargetStatusPath' },
            @{ Property = 'TargetControlPath'; Field = 'TargetControlPath' },
            @{ Property = 'TargetEventsPath'; Field = 'TargetEventsPath' },
            @{ Property = 'TargetWatcherMutexName'; Field = 'TargetWatcherMutexName' }
        )) {
        if (-not (Test-TargetAutoloopObjectPropertyExists -Object $ManifestTarget -Name ([string]$mapping.Field))) {
            continue
        }

        Set-TargetAutoloopPathValue `
            -Object $Paths `
            -Name ([string]$mapping.Property) `
            -Value ([string](Get-ConfigValue -Object $ManifestTarget -Name ([string]$mapping.Field) -DefaultValue ''))
    }

    if (
        (-not (Test-TargetAutoloopObjectPropertyExists -Object $ManifestTarget -Name 'TargetRoot')) -and
        (Test-TargetAutoloopObjectPropertyExists -Object $ManifestTarget -Name 'TargetRunRoot')
    ) {
        $manifestTargetRunRoot = [string](Get-ConfigValue -Object $ManifestTarget -Name 'TargetRunRoot' -DefaultValue '')
        $manifestTargetId = [string](Get-ConfigValue -Object $ManifestTarget -Name 'TargetId' -DefaultValue '')
        if ((Test-NonEmptyString $manifestTargetRunRoot) -and (Test-NonEmptyString $manifestTargetId)) {
            Set-TargetAutoloopPathValue `
                -Object $Paths `
                -Name 'TargetRoot' `
                -Value (Join-Path (Join-Path $manifestTargetRunRoot 'targets') $manifestTargetId)
        }
    }

    if ($null -ne $Paths.PSObject.Properties['UsesWorkRepoRoot']) {
        $Paths.UsesWorkRepoRoot = Test-NonEmptyString ([string](Get-ConfigValue -Object $Paths -Name 'WorkRepoRoot' -DefaultValue ''))
    }

    return $Paths
}

function Use-TargetAutoloopManifestQueuePaths {
    param(
        [Parameter(Mandatory)]$Paths,
        $ManifestTarget = $null
    )

    if ($null -eq $ManifestTarget) {
        return $Paths
    }

    foreach ($mapping in @(
            @{ Property = 'CoordinatorRunRoot'; Field = 'CoordinatorRunRoot' },
            @{ Property = 'TargetRunRoot'; Field = 'TargetRunRoot' },
            @{ Property = 'WorkRepoRoot'; Field = 'WorkRepoRoot' },
            @{ Property = 'QueueRoot'; Field = 'QueueRoot' },
            @{ Property = 'QueuedRoot'; Field = 'QueueQueuedRoot' },
            @{ Property = 'ProcessingRoot'; Field = 'QueueProcessingRoot' },
            @{ Property = 'CompletedRoot'; Field = 'QueueCompletedRoot' },
            @{ Property = 'FailedRoot'; Field = 'QueueFailedRoot' },
            @{ Property = 'PayloadRoot'; Field = 'QueuePayloadRoot' }
        )) {
        if (-not (Test-TargetAutoloopObjectPropertyExists -Object $ManifestTarget -Name ([string]$mapping.Field))) {
            continue
        }

        Set-TargetAutoloopPathValue `
            -Object $Paths `
            -Name ([string]$mapping.Property) `
            -Value ([string](Get-ConfigValue -Object $ManifestTarget -Name ([string]$mapping.Field) -DefaultValue ''))
    }

    if ($null -ne $Paths.PSObject.Properties['UsesWorkRepoRoot']) {
        $Paths.UsesWorkRepoRoot = Test-NonEmptyString ([string](Get-ConfigValue -Object $Paths -Name 'WorkRepoRoot' -DefaultValue ''))
    }

    return $Paths
}

function Get-TargetAutoloopTargetPaths {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId,
        $Target = $null,
        $Config = $null
    )

    $targetRunRoot = Resolve-TargetAutoloopTargetRunRoot -RunRoot $RunRoot -Target $Target -Config $Config
    $workRepoRoot = Get-TargetAutoloopTargetWorkRepoRoot -Target $Target
    $targetRoot = Join-Path (Join-Path $targetRunRoot 'targets') $TargetId
    $inboxRoot = Join-Path $targetRoot 'inbox'
    $workRoot = Join-Path $targetRoot 'work'
    $sourceOutboxRoot = Join-Path $targetRoot 'source-outbox'
    $receiptsRoot = Join-Path $targetRoot 'receipts'
    $targetStateRoot = Join-Path $targetRoot '.state'
    $stateFileName = if ($null -ne $Config) { [string](Get-ConfigValue -Object $Config -Name 'StateFileName' -DefaultValue 'target-state.json') } else { 'target-state.json' }
    $statusFileName = if ($null -ne $Config) { [string](Get-ConfigValue -Object $Config -Name 'StatusFileName' -DefaultValue 'target-autoloop-status.json') } else { 'target-autoloop-status.json' }
    $controlFileName = if ($null -ne $Config) { [string](Get-ConfigValue -Object $Config -Name 'ControlFileName' -DefaultValue 'target-autoloop-control.json') } else { 'target-autoloop-control.json' }
    $eventsFileName = if ($null -ne $Config) { [string](Get-ConfigValue -Object $Config -Name 'EventsFileName' -DefaultValue 'target-events.jsonl') } else { 'target-events.jsonl' }
    return [pscustomobject]@{
        CoordinatorRunRoot = [System.IO.Path]::GetFullPath($RunRoot)
        TargetRunRoot = $targetRunRoot
        WorkRepoRoot = $workRepoRoot
        UsesWorkRepoRoot = (Test-NonEmptyString $workRepoRoot)
        TargetRoot = $targetRoot
        InboxRoot = $inboxRoot
        InboxPendingRoot = Join-Path $inboxRoot 'pending'
        InboxClaimedRoot = Join-Path $inboxRoot 'claimed'
        InboxProcessedRoot = Join-Path $inboxRoot 'processed'
        InboxFailedRoot = Join-Path $inboxRoot 'failed'
        WorkRoot = $workRoot
        CurrentRequestPath = Join-Path $workRoot 'current-request.json'
        LastPromptPath = Join-Path $workRoot 'last-prompt.txt'
        SourceOutboxRoot = $sourceOutboxRoot
        SourceSummaryPath = Join-Path $sourceOutboxRoot 'summary.txt'
        SourceReviewZipPath = Join-Path $sourceOutboxRoot 'review.zip'
        PublishReadyPath = Join-Path $sourceOutboxRoot 'publish.ready.json'
        ReceiptsRoot = $receiptsRoot
        TargetStateRoot = $targetStateRoot
        TargetStatePath = Join-Path $targetStateRoot $stateFileName
        TargetStatusPath = Join-Path $targetStateRoot $statusFileName
        TargetControlPath = Join-Path $targetStateRoot $controlFileName
        TargetEventsPath = Join-Path $targetStateRoot $eventsFileName
        TargetWatcherMutexName = Get-TargetAutoloopTargetWatcherMutexName -TargetRunRoot $targetRunRoot -TargetId $TargetId
    }
}

function Ensure-TargetAutoloopTargetDirectories {
    param([Parameter(Mandatory)]$Paths)

    foreach ($path in @(
            $Paths.TargetRoot,
            $Paths.InboxRoot,
            $Paths.InboxPendingRoot,
            $Paths.InboxClaimedRoot,
            $Paths.InboxProcessedRoot,
            $Paths.InboxFailedRoot,
            $Paths.WorkRoot,
            $Paths.SourceOutboxRoot,
            $Paths.ReceiptsRoot,
            $Paths.TargetStateRoot
        )) {
        Ensure-Directory -Path $path
    }
}

function New-TargetAutoloopTargetStateRecord {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Paths
    )

    $phase = if ([bool]$Target.Enabled) { 'idle' } else { 'disabled' }
    $nextAction = if ([bool]$Target.Enabled) { 'wait-for-input' } else { 'no-op' }
    return [ordered]@{
        Enabled = [bool]$Target.Enabled
        Phase = $phase
        CycleCount = 0
        LastTriggerKind = ''
        LastTriggerSource = ''
        LastTriggerFingerprint = ''
        LastHandledPublishMarkerId = ''
        LastHandledPublishCycleId = 0
        LastHandledPublishParentCycleId = 0
        LastHandledOutputFingerprint = ''
        LastHandledOutputZipHash = ''
        LastSubmittedPromptHash = ''
        LastSubmittedPromptPath = ''
        LastInputPath = ''
        LastClaimedPath = ''
        LastCommandId = ''
        LastCommandPath = ''
        LastReceiptPath = ''
        LastCycleId = 0
        LastParentCycleId = 0
        LastSubmittedAt = ''
        LastProgressSignalAt = ''
        LastOutputReadyAt = ''
        PendingTriggerKind = ''
        PendingTriggerFingerprint = ''
        PendingDispatchEligibleAt = ''
        PendingDispatchDelaySeconds = 0
        PendingPublishedAt = ''
        PendingOutputFingerprint = ''
        PendingPublishCycleId = 0
        PendingPublishParentCycleId = 0
        LastDispatchAt = ''
        LastDispatchState = ''
        LastRouterReadyPath = ''
        RelayTargetFolderState = ''
        LastFailureReason = ''
        NextAction = $nextAction
        PausedPhase = ''
        PausedNextAction = ''
        StoppedPhase = ''
        StoppedNextAction = ''
        CooldownUntil = ''
        CooldownSeconds = [int]$Target.CooldownSeconds
        PublishReadyDispatchDelayMode = [string]$Target.PublishReadyDispatchDelayMode
        PublishReadyDispatchDelaySeconds = [int]$Target.PublishReadyDispatchDelaySeconds
        PublishReadyDispatchMinDelaySeconds = [int]$Target.PublishReadyDispatchMinDelaySeconds
        PublishReadyDispatchMaxDelaySeconds = [int]$Target.PublishReadyDispatchMaxDelaySeconds
        MaxCycleCount = [int]$Target.MaxCycleCount
        TriggerKinds = @($Target.TriggerKinds)
        WorkRepoRoot = [string]$Paths.WorkRepoRoot
        TargetRunRoot = [string]$Paths.TargetRunRoot
        InboxPendingRoot = [string]$Paths.InboxPendingRoot
        InboxClaimedRoot = [string]$Paths.InboxClaimedRoot
        InboxProcessedRoot = [string]$Paths.InboxProcessedRoot
        InboxFailedRoot = [string]$Paths.InboxFailedRoot
        CurrentRequestPath = [string]$Paths.CurrentRequestPath
        LastPromptPath = [string]$Paths.LastPromptPath
        SourceOutboxPath = [string]$Paths.SourceOutboxRoot
        SourceSummaryPath = [string]$Paths.SourceSummaryPath
        SourceReviewZipPath = [string]$Paths.SourceReviewZipPath
        PublishReadyPath = [string]$Paths.PublishReadyPath
        ReceiptsRoot = [string]$Paths.ReceiptsRoot
        TargetStateRoot = [string]$Paths.TargetStateRoot
        TargetStatePath = [string]$Paths.TargetStatePath
        TargetStatusPath = [string]$Paths.TargetStatusPath
        TargetControlPath = [string]$Paths.TargetControlPath
        TargetEventsPath = [string]$Paths.TargetEventsPath
        TargetWatcherMutexName = [string]$Paths.TargetWatcherMutexName
    }
}

function New-TargetAutoloopStateDocument {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RunRoot,
        [string[]]$SelectedTargetIds = @()
    )

    $selectedSet = @{}
    foreach ($selectedTargetId in @($SelectedTargetIds)) {
        if (Test-NonEmptyString $selectedTargetId) {
            $selectedSet[[string]$selectedTargetId] = $true
        }
    }

    $targetMap = [ordered]@{}
    foreach ($target in @($Config.Targets)) {
        $targetId = [string]$target.TargetId
        if ($selectedSet.Count -gt 0 -and -not $selectedSet.ContainsKey($targetId)) {
            continue
        }
        $paths = Get-TargetAutoloopTargetPaths -RunRoot $RunRoot -TargetId $targetId -Target $target -Config $Config
        $targetMap[$targetId] = New-TargetAutoloopTargetStateRecord -Target $target -Paths $paths
    }

    return [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        RunMode = [string]$Config.RunMode
        RunRoot = $RunRoot
        State = 'running'
        LastUpdatedAt = (Get-Date).ToString('o')
        Targets = $targetMap
    }
}

function New-TargetAutoloopControlDocument {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RunRoot
    )

    return [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        RunMode = [string]$Config.RunMode
        RunRoot = $RunRoot
        State = 'running'
        Action = ''
        RequestId = ''
        RequestedAt = ''
        RequestedBy = ''
        PauseRequested = $false
        StopRequested = $false
        LastHandledRequestId = ''
        LastHandledAction = ''
        LastHandledResult = ''
        LastHandledAt = ''
        LastUpdatedAt = (Get-Date).ToString('o')
    }
}

function Clear-TargetAutoloopControlPendingAction {
    param([Parameter(Mandatory)]$ControlDocument)

    $ControlDocument.Action = ''
    $ControlDocument.RequestId = ''
    $ControlDocument.RequestedAt = ''
    $ControlDocument.RequestedBy = ''
    $ControlDocument.PauseRequested = $false
    $ControlDocument.StopRequested = $false
}

function Get-TargetAutoloopPendingControlAction {
    param([Parameter(Mandatory)]$ControlDocument)

    $action = [string](Get-ConfigValue -Object $ControlDocument -Name 'Action' -DefaultValue '')
    if (Test-NonEmptyString $action) {
        return $action
    }

    $controllerState = [string](Get-ConfigValue -Object $ControlDocument -Name 'State' -DefaultValue 'running')
    $stopRequested = [bool](Get-ConfigValue -Object $ControlDocument -Name 'StopRequested' -DefaultValue $false)
    if ($stopRequested -and $controllerState -ne 'stopped') {
        return 'stop'
    }

    $pauseRequested = [bool](Get-ConfigValue -Object $ControlDocument -Name 'PauseRequested' -DefaultValue $false)
    if ($pauseRequested -and $controllerState -ne 'paused') {
        return 'pause'
    }

    return ''
}

function Complete-TargetAutoloopControlAction {
    param(
        [Parameter(Mandatory)]$ControlDocument,
        [Parameter(Mandatory)][ValidateSet('running', 'paused', 'stopped')][string]$State,
        [Parameter(Mandatory)][string]$Result
    )

    $handledRequestId = [string](Get-ConfigValue -Object $ControlDocument -Name 'RequestId' -DefaultValue '')
    $handledAction = Get-TargetAutoloopPendingControlAction -ControlDocument $ControlDocument
    $handledAt = (Get-Date).ToString('o')

    $ControlDocument.State = $State
    $ControlDocument.LastHandledRequestId = $handledRequestId
    $ControlDocument.LastHandledAction = $handledAction
    $ControlDocument.LastHandledResult = [string]$Result
    $ControlDocument.LastHandledAt = $handledAt
    Clear-TargetAutoloopControlPendingAction -ControlDocument $ControlDocument
    $ControlDocument.LastUpdatedAt = $handledAt
}

function Request-TargetAutoloopControlAction {
    param(
        [Parameter(Mandatory)]$ControlDocument,
        [Parameter(Mandatory)][ValidateSet('pause', 'resume', 'stop')][string]$Action,
        [string]$RequestedBy = 'relay_operator_panel'
    )

    $controllerState = [string](Get-ConfigValue -Object $ControlDocument -Name 'State' -DefaultValue 'running')
    $pendingAction = Get-TargetAutoloopPendingControlAction -ControlDocument $ControlDocument
    $pendingRequestId = [string](Get-ConfigValue -Object $ControlDocument -Name 'RequestId' -DefaultValue '')

    if (Test-NonEmptyString $pendingAction) {
        if ($pendingAction -eq $Action) {
            return [pscustomobject]@{
                Ok = $true
                Action = $Action
                State = $controllerState
                RequestId = $pendingRequestId
                Result = 'already-pending'
                Message = ('target-autoloop {0} 요청이 이미 진행 중입니다.' -f $Action)
                ReasonCodes = @('control_already_pending')
            }
        }

        return [pscustomobject]@{
            Ok = $false
            Action = $Action
            State = $controllerState
            RequestId = $pendingRequestId
            Result = 'control-pending'
            Message = ('다른 target-autoloop 제어 요청({0})이 이미 진행 중입니다.' -f $pendingAction)
            ReasonCodes = @('control_pending_action_exists')
        }
    }

    switch ($Action) {
        'pause' {
            if ($controllerState -eq 'paused') {
                return [pscustomobject]@{
                    Ok = $true
                    Action = $Action
                    State = $controllerState
                    RequestId = ''
                    Result = 'already-paused'
                    Message = 'target-autoloop이 이미 paused 상태입니다.'
                    ReasonCodes = @('already-paused')
                }
            }
            if ($controllerState -eq 'stopped') {
                return [pscustomobject]@{
                    Ok = $false
                    Action = $Action
                    State = $controllerState
                    RequestId = ''
                    Result = 'stopped'
                    Message = 'stopped 상태에서는 pause를 요청할 수 없습니다.'
                    ReasonCodes = @('controller-stopped')
                }
            }
        }
        'resume' {
            if ($controllerState -eq 'running') {
                return [pscustomobject]@{
                    Ok = $true
                    Action = $Action
                    State = $controllerState
                    RequestId = ''
                    Result = 'already-running'
                    Message = 'target-autoloop이 이미 running 상태입니다.'
                    ReasonCodes = @('already-running')
                }
            }
            if ($controllerState -eq 'stopped') {
                return [pscustomobject]@{
                    Ok = $false
                    Action = $Action
                    State = $controllerState
                    RequestId = ''
                    Result = 'stopped'
                    Message = 'stopped 상태에서는 resume이 아니라 restart가 필요합니다.'
                    ReasonCodes = @('controller-stopped')
                }
            }
        }
        'stop' {
            if ($controllerState -eq 'stopped') {
                return [pscustomobject]@{
                    Ok = $true
                    Action = $Action
                    State = $controllerState
                    RequestId = ''
                    Result = 'already-stopped'
                    Message = 'target-autoloop이 이미 stopped 상태입니다.'
                    ReasonCodes = @('already-stopped')
                }
            }
        }
    }

    $requestedAt = (Get-Date).ToString('o')
    $requestId = [guid]::NewGuid().ToString()
    $ControlDocument.Action = $Action
    $ControlDocument.RequestId = $requestId
    $ControlDocument.RequestedAt = $requestedAt
    $ControlDocument.RequestedBy = [string]$RequestedBy
    $ControlDocument.PauseRequested = ($Action -eq 'pause')
    $ControlDocument.StopRequested = ($Action -eq 'stop')
    $ControlDocument.LastUpdatedAt = $requestedAt
    return [pscustomobject]@{
        Ok = $true
        Action = $Action
        State = $controllerState
        RequestId = $requestId
        Result = 'requested'
        Message = ('target-autoloop {0} 요청을 기록했습니다.' -f $Action)
        ReasonCodes = @((('{0}_requested' -f $Action)))
    }
}

function Get-TargetAutoloopDefaultNextAction {
    param([string[]]$TriggerKinds = @())

    if (@($TriggerKinds) -contains 'publish-ready') {
        return 'wait-for-output'
    }

    return 'wait-for-input'
}

function Restore-TargetAutoloopPausedEntryState {
    param([Parameter(Mandatory)]$Entry)

    $triggerKinds = @(Get-StringArray (Get-ConfigValue -Object $Entry -Name 'TriggerKinds' -DefaultValue @()))
    if (-not [bool](Get-ConfigValue -Object $Entry -Name 'Enabled' -DefaultValue $false)) {
        $Entry.Phase = 'disabled'
        $Entry.NextAction = 'no-op'
        $Entry.PausedPhase = ''
        $Entry.PausedNextAction = ''
        return
    }
    $restoredPhase = [string](Get-ConfigValue -Object $Entry -Name 'PausedPhase' -DefaultValue '')
    $restoredNextAction = [string](Get-ConfigValue -Object $Entry -Name 'PausedNextAction' -DefaultValue '')
    if (-not (Test-NonEmptyString $restoredPhase)) {
        $restoredPhase = 'idle'
    }
    if (-not (Test-NonEmptyString $restoredNextAction)) {
        $restoredNextAction = Get-TargetAutoloopDefaultNextAction -TriggerKinds @($triggerKinds)
    }

    $Entry.Phase = $restoredPhase
    $Entry.NextAction = $restoredNextAction
    $Entry.PausedPhase = ''
    $Entry.PausedNextAction = ''
}

function Restore-TargetAutoloopStoppedEntryState {
    param([Parameter(Mandatory)]$Entry)

    $triggerKinds = @(Get-StringArray (Get-ConfigValue -Object $Entry -Name 'TriggerKinds' -DefaultValue @()))
    if (-not [bool](Get-ConfigValue -Object $Entry -Name 'Enabled' -DefaultValue $false)) {
        $Entry.Phase = 'disabled'
        $Entry.NextAction = 'no-op'
        $Entry.StoppedPhase = ''
        $Entry.StoppedNextAction = ''
        return
    }
    $restoredPhase = [string](Get-ConfigValue -Object $Entry -Name 'StoppedPhase' -DefaultValue '')
    $restoredNextAction = [string](Get-ConfigValue -Object $Entry -Name 'StoppedNextAction' -DefaultValue '')
    if (-not (Test-NonEmptyString $restoredPhase)) {
        $restoredPhase = 'idle'
    }
    if (-not (Test-NonEmptyString $restoredNextAction)) {
        $restoredNextAction = Get-TargetAutoloopDefaultNextAction -TriggerKinds @($triggerKinds)
    }

    $Entry.Phase = $restoredPhase
    $Entry.NextAction = $restoredNextAction
    $Entry.StoppedPhase = ''
    $Entry.StoppedNextAction = ''
}

function Convert-TargetAutoloopTargetMapToRows {
    param($TargetsObject)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($targetId in @(Get-ConfigMemberNames $TargetsObject | Sort-Object)) {
        $entry = Get-ConfigValue -Object $TargetsObject -Name $targetId -DefaultValue $null
        if ($null -eq $entry) {
            continue
        }

        $cycleCount = [int](Get-ConfigValue -Object $entry -Name 'CycleCount' -DefaultValue 0)
        $maxCycleCount = [int](Get-ConfigValue -Object $entry -Name 'MaxCycleCount' -DefaultValue 0)
        $remainingCycleCount = if ($maxCycleCount -gt 0) {
            [math]::Max($maxCycleCount - $cycleCount, 0)
        }
        else {
            $null
        }

        $rows.Add([pscustomobject]([ordered]@{
                    TargetId = $targetId
                    Enabled = [bool](Get-ConfigValue -Object $entry -Name 'Enabled' -DefaultValue $false)
                    Phase = [string](Get-ConfigValue -Object $entry -Name 'Phase' -DefaultValue '')
                    CycleCount = $cycleCount
                    MaxCycleCount = $maxCycleCount
                    RemainingCycleCount = $remainingCycleCount
                    LastTriggerKind = [string](Get-ConfigValue -Object $entry -Name 'LastTriggerKind' -DefaultValue '')
                    LastTriggerSource = [string](Get-ConfigValue -Object $entry -Name 'LastTriggerSource' -DefaultValue '')
                    LastTriggerFingerprint = [string](Get-ConfigValue -Object $entry -Name 'LastTriggerFingerprint' -DefaultValue '')
                    LastHandledPublishMarkerId = [string](Get-ConfigValue -Object $entry -Name 'LastHandledPublishMarkerId' -DefaultValue '')
                    LastHandledPublishCycleId = [int](Get-ConfigValue -Object $entry -Name 'LastHandledPublishCycleId' -DefaultValue 0)
                    LastHandledPublishParentCycleId = [int](Get-ConfigValue -Object $entry -Name 'LastHandledPublishParentCycleId' -DefaultValue 0)
                    LastHandledOutputFingerprint = [string](Get-ConfigValue -Object $entry -Name 'LastHandledOutputFingerprint' -DefaultValue '')
                    LastCommandId = [string](Get-ConfigValue -Object $entry -Name 'LastCommandId' -DefaultValue '')
                    LastCommandPath = [string](Get-ConfigValue -Object $entry -Name 'LastCommandPath' -DefaultValue '')
                    LastReceiptPath = [string](Get-ConfigValue -Object $entry -Name 'LastReceiptPath' -DefaultValue '')
                    LastSubmittedAt = [string](Get-ConfigValue -Object $entry -Name 'LastSubmittedAt' -DefaultValue '')
                    LastProgressSignalAt = [string](Get-ConfigValue -Object $entry -Name 'LastProgressSignalAt' -DefaultValue '')
                    LastOutputReadyAt = [string](Get-ConfigValue -Object $entry -Name 'LastOutputReadyAt' -DefaultValue '')
                    PendingTriggerKind = [string](Get-ConfigValue -Object $entry -Name 'PendingTriggerKind' -DefaultValue '')
                    PendingTriggerFingerprint = [string](Get-ConfigValue -Object $entry -Name 'PendingTriggerFingerprint' -DefaultValue '')
                    PendingDispatchEligibleAt = [string](Get-ConfigValue -Object $entry -Name 'PendingDispatchEligibleAt' -DefaultValue '')
                    PendingDispatchDelaySeconds = [int](Get-ConfigValue -Object $entry -Name 'PendingDispatchDelaySeconds' -DefaultValue 0)
                    PendingPublishedAt = [string](Get-ConfigValue -Object $entry -Name 'PendingPublishedAt' -DefaultValue '')
                    PendingOutputFingerprint = [string](Get-ConfigValue -Object $entry -Name 'PendingOutputFingerprint' -DefaultValue '')
                    PendingPublishCycleId = [int](Get-ConfigValue -Object $entry -Name 'PendingPublishCycleId' -DefaultValue 0)
                    PendingPublishParentCycleId = [int](Get-ConfigValue -Object $entry -Name 'PendingPublishParentCycleId' -DefaultValue 0)
                    LastDispatchAt = [string](Get-ConfigValue -Object $entry -Name 'LastDispatchAt' -DefaultValue '')
                    LastDispatchState = [string](Get-ConfigValue -Object $entry -Name 'LastDispatchState' -DefaultValue '')
                    LastRouterReadyPath = [string](Get-ConfigValue -Object $entry -Name 'LastRouterReadyPath' -DefaultValue '')
                    RelayTargetFolderState = [string](Get-ConfigValue -Object $entry -Name 'RelayTargetFolderState' -DefaultValue '')
                    LastFailureReason = [string](Get-ConfigValue -Object $entry -Name 'LastFailureReason' -DefaultValue '')
                    NextAction = [string](Get-ConfigValue -Object $entry -Name 'NextAction' -DefaultValue '')
                    CooldownUntil = [string](Get-ConfigValue -Object $entry -Name 'CooldownUntil' -DefaultValue '')
                    WorkRepoRoot = [string](Get-ConfigValue -Object $entry -Name 'WorkRepoRoot' -DefaultValue '')
                    TargetRunRoot = [string](Get-ConfigValue -Object $entry -Name 'TargetRunRoot' -DefaultValue '')
                    TargetStateRoot = [string](Get-ConfigValue -Object $entry -Name 'TargetStateRoot' -DefaultValue '')
                    TargetStatePath = [string](Get-ConfigValue -Object $entry -Name 'TargetStatePath' -DefaultValue '')
                    TargetStatusPath = [string](Get-ConfigValue -Object $entry -Name 'TargetStatusPath' -DefaultValue '')
                    TargetControlPath = [string](Get-ConfigValue -Object $entry -Name 'TargetControlPath' -DefaultValue '')
                    TargetEventsPath = [string](Get-ConfigValue -Object $entry -Name 'TargetEventsPath' -DefaultValue '')
                    TargetWatcherMutexName = [string](Get-ConfigValue -Object $entry -Name 'TargetWatcherMutexName' -DefaultValue '')
                    PublishReadyDispatchDelayMode = [string](Get-ConfigValue -Object $entry -Name 'PublishReadyDispatchDelayMode' -DefaultValue 'fixed')
                    PublishReadyDispatchDelaySeconds = [int](Get-ConfigValue -Object $entry -Name 'PublishReadyDispatchDelaySeconds' -DefaultValue 0)
                    PublishReadyDispatchMinDelaySeconds = [int](Get-ConfigValue -Object $entry -Name 'PublishReadyDispatchMinDelaySeconds' -DefaultValue ([int](Get-ConfigValue -Object $entry -Name 'PublishReadyDispatchDelaySeconds' -DefaultValue 0)))
                    PublishReadyDispatchMaxDelaySeconds = [int](Get-ConfigValue -Object $entry -Name 'PublishReadyDispatchMaxDelaySeconds' -DefaultValue ([int](Get-ConfigValue -Object $entry -Name 'PublishReadyDispatchDelaySeconds' -DefaultValue 0)))
                })) | Out-Null
    }

    return $rows.ToArray()
}

function New-TargetAutoloopStatusDocument {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$StateDocument,
        $ControlDocument = $null,
        [string]$WatcherState = '',
        [string]$WatcherStopReason = '',
        [string]$WatcherMutexName = '',
        [string[]]$WatcherTargetIds = @(),
        [string]$HeartbeatAt = '',
        [string]$ProcessStartedAt = '',
        [int]$ConfiguredRunDurationSec = 0
    )

    $targetRows = @(Convert-TargetAutoloopTargetMapToRows -TargetsObject (Get-ConfigValue -Object $StateDocument -Name 'Targets' -DefaultValue @{}))
    $watcherTargetIds = @(
        $WatcherTargetIds |
            Where-Object { Test-NonEmptyString $_ } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
    if (@($watcherTargetIds).Count -eq 0) {
        $watcherTargetIds = @(
            $targetRows |
                ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') } |
                Where-Object { Test-NonEmptyString $_ } |
                Sort-Object -Unique
        )
    }
    $enabledTargetIds = @(
        $targetRows |
            Where-Object { [bool]$_.Enabled } |
            ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') } |
            Where-Object { Test-NonEmptyString $_ } |
            Sort-Object -Unique
    )
    $watcherTargetScope = if (@($watcherTargetIds).Count -gt 0 -and @($enabledTargetIds).Count -gt 0 -and @($watcherTargetIds).Count -lt @($enabledTargetIds).Count) { 'scoped' } else { 'all' }
    $counts = [ordered]@{
        TotalTargets = @($targetRows).Count
        EnabledTargets = @($targetRows | Where-Object { [bool]$_.Enabled }).Count
        DispatchDelayTargets = @($targetRows | Where-Object { [string]$_.Phase -eq 'dispatch-delay' }).Count
        QueuedTargets = @($targetRows | Where-Object { [string]$_.Phase -eq 'queued' }).Count
        WaitingOutputTargets = @($targetRows | Where-Object { [string]$_.Phase -eq 'waiting-output' }).Count
        FailedTargets = @($targetRows | Where-Object { [string]$_.Phase -eq 'failed' }).Count
        LimitReachedTargets = @($targetRows | Where-Object { [string]$_.Phase -eq 'limit-reached' }).Count
    }
    $controllerState = if ($null -ne $ControlDocument) { [string](Get-ConfigValue -Object $ControlDocument -Name 'State' -DefaultValue 'running') } else { 'running' }
    $delaySummary = Get-TargetAutoloopDelaySummary -TargetRows @($targetRows)
    $proofReceipt = Get-TargetAutoloopProofReceiptSummary `
        -SmokeReceiptPath ((Get-TargetAutoloopStatePaths -RunRoot $RunRoot -Config $Config).SmokeReceiptPath) `
        -AcceptanceReceiptPath ((Get-TargetAutoloopStatePaths -RunRoot $RunRoot -Config $Config).AcceptanceReceiptPath) `
        -TargetRows @($targetRows)
    $proofCloseout = Get-TargetAutoloopProofCloseoutSummary -ProofReceipt $proofReceipt
    $controlPendingAction = if ($null -ne $ControlDocument) { [string](Get-ConfigValue -Object $ControlDocument -Name 'Action' -DefaultValue '') } else { '' }
    $controlPendingRequestId = if ($null -ne $ControlDocument) { [string](Get-ConfigValue -Object $ControlDocument -Name 'RequestId' -DefaultValue '') } else { '' }
    $controlRequestedAt = if ($null -ne $ControlDocument) { [string](Get-ConfigValue -Object $ControlDocument -Name 'RequestedAt' -DefaultValue '') } else { '' }
    $controlRequestedBy = if ($null -ne $ControlDocument) { [string](Get-ConfigValue -Object $ControlDocument -Name 'RequestedBy' -DefaultValue '') } else { '' }
    $lastHandledRequestId = if ($null -ne $ControlDocument) { [string](Get-ConfigValue -Object $ControlDocument -Name 'LastHandledRequestId' -DefaultValue '') } else { '' }
    $lastHandledAction = if ($null -ne $ControlDocument) { [string](Get-ConfigValue -Object $ControlDocument -Name 'LastHandledAction' -DefaultValue '') } else { '' }
    $lastHandledResult = if ($null -ne $ControlDocument) { [string](Get-ConfigValue -Object $ControlDocument -Name 'LastHandledResult' -DefaultValue '') } else { '' }
    $lastHandledAt = if ($null -ne $ControlDocument) { [string](Get-ConfigValue -Object $ControlDocument -Name 'LastHandledAt' -DefaultValue '') } else { '' }

    return [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        RunMode = [string]$Config.RunMode
        RunRoot = $RunRoot
        ControllerState = $controllerState
        ControlPendingAction = $controlPendingAction
        ControlPendingRequestId = $controlPendingRequestId
        ControlRequestedAt = $controlRequestedAt
        ControlRequestedBy = $controlRequestedBy
        LastHandledRequestId = $lastHandledRequestId
        LastHandledAction = $lastHandledAction
        LastHandledResult = $lastHandledResult
        LastHandledAt = $lastHandledAt
        WatcherState = $WatcherState
        WatcherStopReason = $WatcherStopReason
        WatcherMutexName = $WatcherMutexName
        WatcherTargetIds = @($watcherTargetIds)
        WatcherTargetScope = $watcherTargetScope
        HeartbeatAt = $HeartbeatAt
        ProcessStartedAt = $ProcessStartedAt
        ConfiguredRunDurationSec = $ConfiguredRunDurationSec
        State = [string](Get-ConfigValue -Object $StateDocument -Name 'State' -DefaultValue '')
        LastUpdatedAt = (Get-Date).ToString('o')
        Counts = $counts
        DelaySummary = $delaySummary
        SmokeReceipt = $proofReceipt
        ProofCloseout = $proofCloseout
        Targets = @($targetRows)
        ModeCapabilities = [ordered]@{
            CommandQueue = $true
            TypedWindowDispatch = $false
            RouterReadyDispatch = [bool]$Config.DispatchQueuedCommandsInline
            PublishReadyLoop = ([string]$Config.RunMode -eq 'target-autoloop')
            MaxConcurrentTargets = [int]$Config.MaxConcurrentTargets
            MaxConcurrentSubmits = [int]$Config.MaxConcurrentSubmits
        }
    }
}

function Get-TargetAutoloopStatusTargetRowMap {
    param($StatusDocument)

    $map = @{}
    foreach ($row in @(Get-ConfigValue -Object $StatusDocument -Name 'Targets' -DefaultValue @())) {
        $targetId = [string](Get-ConfigValue -Object $row -Name 'TargetId' -DefaultValue '')
        if (Test-NonEmptyString $targetId) {
            $map[$targetId] = $row
        }
    }
    return $map
}

function Get-TargetAutoloopTargetSidecarPaths {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId,
        $TargetEntry,
        $Config = $null
    )

    $targetRunRoot = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetRunRoot' -DefaultValue $RunRoot)
    if (-not (Test-NonEmptyString $targetRunRoot)) {
        $targetRunRoot = $RunRoot
    }

    $targetRoot = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetRoot)) {
        $targetRoot = Join-Path (Join-Path $targetRunRoot 'targets') $TargetId
    }

    $stateFileName = if ($null -ne $Config) { [string](Get-ConfigValue -Object $Config -Name 'StateFileName' -DefaultValue 'target-state.json') } else { 'target-state.json' }
    $statusFileName = if ($null -ne $Config) { [string](Get-ConfigValue -Object $Config -Name 'StatusFileName' -DefaultValue 'target-autoloop-status.json') } else { 'target-autoloop-status.json' }
    $controlFileName = if ($null -ne $Config) { [string](Get-ConfigValue -Object $Config -Name 'ControlFileName' -DefaultValue 'target-autoloop-control.json') } else { 'target-autoloop-control.json' }
    $eventsFileName = if ($null -ne $Config) { [string](Get-ConfigValue -Object $Config -Name 'EventsFileName' -DefaultValue 'target-events.jsonl') } else { 'target-events.jsonl' }

    $targetStateRoot = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetStateRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetStateRoot)) {
        $targetStateRoot = Join-Path $targetRoot '.state'
    }

    $targetStatePath = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetStatePath' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetStatePath)) {
        $targetStatePath = Join-Path $targetStateRoot $stateFileName
    }
    $targetStatusPath = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetStatusPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetStatusPath)) {
        $targetStatusPath = Join-Path $targetStateRoot $statusFileName
    }
    $targetControlPath = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetControlPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetControlPath)) {
        $targetControlPath = Join-Path $targetStateRoot $controlFileName
    }
    $targetEventsPath = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetEventsPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetEventsPath)) {
        $targetEventsPath = Join-Path $targetStateRoot $eventsFileName
    }
    $targetWatcherMutexName = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetWatcherMutexName' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetWatcherMutexName)) {
        $targetWatcherMutexName = Get-TargetAutoloopTargetWatcherMutexName -TargetRunRoot $targetRunRoot -TargetId $TargetId
    }

    return [pscustomobject][ordered]@{
        TargetRunRoot = $targetRunRoot
        TargetRoot = $targetRoot
        TargetStateRoot = $targetStateRoot
        TargetStatePath = $targetStatePath
        TargetStatusPath = $targetStatusPath
        TargetControlPath = $targetControlPath
        TargetEventsPath = $targetEventsPath
        TargetWatcherMutexName = $targetWatcherMutexName
    }
}

function New-TargetAutoloopTargetSidecarStateDocument {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$StateDocument,
        [Parameter(Mandatory)]$TargetEntry,
        [Parameter(Mandatory)]$SidecarPaths
    )

    return [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        SidecarKind = 'target-state'
        SidecarScope = 'target'
        RunMode = [string](Get-ConfigValue -Object $StateDocument -Name 'RunMode' -DefaultValue '')
        RunRoot = $RunRoot
        TargetId = $TargetId
        State = [string](Get-ConfigValue -Object $StateDocument -Name 'State' -DefaultValue '')
        LastUpdatedAt = [string](Get-ConfigValue -Object $StateDocument -Name 'LastUpdatedAt' -DefaultValue '')
        TargetStatePath = [string]$SidecarPaths.TargetStatePath
        TargetStatusPath = [string]$SidecarPaths.TargetStatusPath
        TargetControlPath = [string]$SidecarPaths.TargetControlPath
        TargetEventsPath = [string]$SidecarPaths.TargetEventsPath
        TargetWatcherMutexName = [string]$SidecarPaths.TargetWatcherMutexName
        Target = $TargetEntry
    }
}

function New-TargetAutoloopTargetSidecarControlDocument {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$ControlDocument,
        [Parameter(Mandatory)]$SidecarPaths
    )

    return [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        SidecarKind = 'target-control'
        SidecarScope = 'global-control-mirror'
        RunMode = [string](Get-ConfigValue -Object $ControlDocument -Name 'RunMode' -DefaultValue '')
        RunRoot = $RunRoot
        TargetId = $TargetId
        State = [string](Get-ConfigValue -Object $ControlDocument -Name 'State' -DefaultValue '')
        Action = [string](Get-ConfigValue -Object $ControlDocument -Name 'Action' -DefaultValue '')
        RequestId = [string](Get-ConfigValue -Object $ControlDocument -Name 'RequestId' -DefaultValue '')
        RequestedAt = [string](Get-ConfigValue -Object $ControlDocument -Name 'RequestedAt' -DefaultValue '')
        RequestedBy = [string](Get-ConfigValue -Object $ControlDocument -Name 'RequestedBy' -DefaultValue '')
        LastHandledRequestId = [string](Get-ConfigValue -Object $ControlDocument -Name 'LastHandledRequestId' -DefaultValue '')
        LastHandledAction = [string](Get-ConfigValue -Object $ControlDocument -Name 'LastHandledAction' -DefaultValue '')
        LastHandledResult = [string](Get-ConfigValue -Object $ControlDocument -Name 'LastHandledResult' -DefaultValue '')
        LastHandledAt = [string](Get-ConfigValue -Object $ControlDocument -Name 'LastHandledAt' -DefaultValue '')
        LastUpdatedAt = [string](Get-ConfigValue -Object $ControlDocument -Name 'LastUpdatedAt' -DefaultValue '')
        TargetControlPath = [string]$SidecarPaths.TargetControlPath
        TargetWatcherMutexName = [string]$SidecarPaths.TargetWatcherMutexName
        Control = $ControlDocument
    }
}

function New-TargetAutoloopTargetSidecarStatusDocument {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$StatusDocument,
        $StatusRow = $null,
        [Parameter(Mandatory)]$SidecarPaths
    )

    return [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        SidecarKind = 'target-status'
        SidecarScope = 'target'
        RunMode = [string](Get-ConfigValue -Object $StatusDocument -Name 'RunMode' -DefaultValue '')
        RunRoot = $RunRoot
        TargetId = $TargetId
        ControllerState = [string](Get-ConfigValue -Object $StatusDocument -Name 'ControllerState' -DefaultValue '')
        ControlPendingAction = [string](Get-ConfigValue -Object $StatusDocument -Name 'ControlPendingAction' -DefaultValue '')
        ControlPendingRequestId = [string](Get-ConfigValue -Object $StatusDocument -Name 'ControlPendingRequestId' -DefaultValue '')
        WatcherState = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherState' -DefaultValue '')
        WatcherStopReason = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherStopReason' -DefaultValue '')
        WatcherMutexName = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherMutexName' -DefaultValue '')
        WatcherTargetIds = @(Get-ConfigValue -Object $StatusDocument -Name 'WatcherTargetIds' -DefaultValue @())
        WatcherTargetScope = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherTargetScope' -DefaultValue '')
        HeartbeatAt = [string](Get-ConfigValue -Object $StatusDocument -Name 'HeartbeatAt' -DefaultValue '')
        ProcessStartedAt = [string](Get-ConfigValue -Object $StatusDocument -Name 'ProcessStartedAt' -DefaultValue '')
        State = [string](Get-ConfigValue -Object $StatusDocument -Name 'State' -DefaultValue '')
        LastUpdatedAt = [string](Get-ConfigValue -Object $StatusDocument -Name 'LastUpdatedAt' -DefaultValue '')
        TargetStatusPath = [string]$SidecarPaths.TargetStatusPath
        TargetControlPath = [string]$SidecarPaths.TargetControlPath
        TargetStatePath = [string]$SidecarPaths.TargetStatePath
        TargetEventsPath = [string]$SidecarPaths.TargetEventsPath
        TargetWatcherMutexName = [string]$SidecarPaths.TargetWatcherMutexName
        Target = $StatusRow
    }
}

function Sync-TargetAutoloopTargetSidecarDocuments {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RunRoot,
        $StateDocument = $null,
        $ControlDocument = $null,
        $StatusDocument = $null,
        [bool]$WriteState = $true,
        [bool]$WriteControl = $true,
        [bool]$WriteStatus = $true
    )

    if ($null -eq $StateDocument) {
        return
    }

    $stateTargetMap = Get-TargetAutoloopTargetStateMap -StateDocument $StateDocument
    $statusRowMap = if ($null -ne $StatusDocument) {
        Get-TargetAutoloopStatusTargetRowMap -StatusDocument $StatusDocument
    }
    else {
        @{}
    }

    foreach ($targetId in @($stateTargetMap.Keys | Sort-Object)) {
        if (-not (Test-NonEmptyString ([string]$targetId))) {
            continue
        }
        $entry = $stateTargetMap[$targetId]
        if ($null -eq $entry) {
            continue
        }

        $sidecarPaths = Get-TargetAutoloopTargetSidecarPaths -RunRoot $RunRoot -TargetId ([string]$targetId) -TargetEntry $entry -Config $Config
        Ensure-Directory -Path ([string]$sidecarPaths.TargetStateRoot)

        if ($WriteState) {
            Write-JsonFileAtomically `
                -Path ([string]$sidecarPaths.TargetStatePath) `
                -Payload (New-TargetAutoloopTargetSidecarStateDocument `
                    -RunRoot $RunRoot `
                    -TargetId ([string]$targetId) `
                    -StateDocument $StateDocument `
                    -TargetEntry $entry `
                    -SidecarPaths $sidecarPaths)
        }
        if ($WriteControl -and $null -ne $ControlDocument) {
            Write-JsonFileAtomically `
                -Path ([string]$sidecarPaths.TargetControlPath) `
                -Payload (New-TargetAutoloopTargetSidecarControlDocument `
                    -RunRoot $RunRoot `
                    -TargetId ([string]$targetId) `
                    -ControlDocument $ControlDocument `
                    -SidecarPaths $sidecarPaths)
        }
        if ($WriteStatus -and $null -ne $StatusDocument) {
            $statusRow = if ($statusRowMap.ContainsKey([string]$targetId)) { $statusRowMap[[string]$targetId] } else { $null }
            Write-JsonFileAtomically `
                -Path ([string]$sidecarPaths.TargetStatusPath) `
                -Payload (New-TargetAutoloopTargetSidecarStatusDocument `
                    -RunRoot $RunRoot `
                    -TargetId ([string]$targetId) `
                    -StatusDocument $StatusDocument `
                    -StatusRow $statusRow `
                    -SidecarPaths $sidecarPaths)
        }
        if ((Test-NonEmptyString ([string]$sidecarPaths.TargetEventsPath)) -and -not (Test-Path -LiteralPath ([string]$sidecarPaths.TargetEventsPath) -PathType Leaf)) {
            Ensure-Directory -Path (Split-Path -Parent ([string]$sidecarPaths.TargetEventsPath))
            '' | Set-Content -LiteralPath ([string]$sidecarPaths.TargetEventsPath) -Encoding UTF8
        }
    }
}

function Get-TargetAutoloopTargetStateMap {
    param($StateDocument)

    $map = [ordered]@{}
    $targetsObject = Get-ConfigValue -Object $StateDocument -Name 'Targets' -DefaultValue @{}
    foreach ($targetId in @(Get-ConfigMemberNames $targetsObject | Sort-Object)) {
        $map[$targetId] = Get-ConfigValue -Object $targetsObject -Name $targetId -DefaultValue $null
    }
    return $map
}

function Set-TargetAutoloopTargetStateMap {
    param(
        [Parameter(Mandatory)]$TargetStateMap,
        [Parameter(Mandatory)]$StateDocument
    )

    $StateDocument.Targets = [ordered]@{}
    foreach ($targetId in @($TargetStateMap.Keys | Sort-Object)) {
        $StateDocument.Targets[$targetId] = $TargetStateMap[$targetId]
    }
}

function Append-TargetAutoloopEvent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][string]$TargetId,
        [string]$TriggerKind = '',
        [string]$TriggerFingerprint = '',
        [hashtable]$Extra = @{}
    )

    $payload = [ordered]@{
        Timestamp = (Get-Date).ToString('o')
        EventType = $EventType
        TargetId = $TargetId
        TriggerKind = $TriggerKind
        TriggerFingerprint = $TriggerFingerprint
    }
    foreach ($key in @($Extra.Keys | Sort-Object)) {
        $payload[$key] = $Extra[$key]
    }
    Append-LineUtf8NoBom -Path $Path -Line (($payload | ConvertTo-Json -Depth 10 -Compress))
}

function Test-TargetAutoloopPublishReadyValid {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ExpectedTargetId
    )

    foreach ($path in @($Paths.SourceSummaryPath, $Paths.SourceReviewZipPath, $Paths.PublishReadyPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
    }

    try {
        $marker = Read-JsonObject -Path $Paths.PublishReadyPath
    }
    catch {
        return $false
    }

    foreach ($requiredField in @('SchemaVersion', 'RunMode', 'TargetId', 'SummaryPath', 'ReviewZipPath', 'PublishedAt', 'SummarySizeBytes', 'ReviewZipSizeBytes', 'PublishedBy', 'OutputFingerprint')) {
        if (-not (Test-NonEmptyString ([string](Get-ConfigValue -Object $marker -Name $requiredField -DefaultValue '')))) {
            return $false
        }
    }

    if ([string](Get-ConfigValue -Object $marker -Name 'RunMode' -DefaultValue '') -ne 'target-autoloop') {
        return $false
    }

    if ([string](Get-ConfigValue -Object $marker -Name 'TargetId' -DefaultValue '') -ne $ExpectedTargetId) {
        return $false
    }

    if ((Get-NormalizedFullPath -Path ([string](Get-ConfigValue -Object $marker -Name 'SummaryPath' -DefaultValue ''))) -ne (Get-NormalizedFullPath -Path ([string]$Paths.SourceSummaryPath))) {
        return $false
    }

    if ((Get-NormalizedFullPath -Path ([string](Get-ConfigValue -Object $marker -Name 'ReviewZipPath' -DefaultValue ''))) -ne (Get-NormalizedFullPath -Path ([string]$Paths.SourceReviewZipPath))) {
        return $false
    }

    $validationPassed = Get-ConfigValue -Object $marker -Name 'ValidationPassed' -DefaultValue $null
    if ($validationPassed -is [bool] -and -not [bool]$validationPassed) {
        return $false
    }

    $markerCycleId = 0
    $markerParentCycleId = 0
    if (-not [int]::TryParse([string](Get-ConfigValue -Object $marker -Name 'CycleId' -DefaultValue ''), [ref]$markerCycleId)) {
        return $false
    }
    if (-not [int]::TryParse([string](Get-ConfigValue -Object $marker -Name 'ParentCycleId' -DefaultValue ''), [ref]$markerParentCycleId)) {
        return $false
    }
    if ($markerCycleId -lt 0 -or $markerParentCycleId -lt 0) {
        return $false
    }

    $summaryItem = Get-Item -LiteralPath $Paths.SourceSummaryPath -ErrorAction Stop
    $zipItem = Get-Item -LiteralPath $Paths.SourceReviewZipPath -ErrorAction Stop
    $summarySizeExpected = 0L
    $zipSizeExpected = 0L
    if (-not [int64]::TryParse([string](Get-ConfigValue -Object $marker -Name 'SummarySizeBytes' -DefaultValue ''), [ref]$summarySizeExpected)) {
        return $false
    }
    if (-not [int64]::TryParse([string](Get-ConfigValue -Object $marker -Name 'ReviewZipSizeBytes' -DefaultValue ''), [ref]$zipSizeExpected)) {
        return $false
    }
    if ($summarySizeExpected -ne [int64]$summaryItem.Length) {
        return $false
    }
    if ($zipSizeExpected -ne [int64]$zipItem.Length) {
        return $false
    }

    $summaryHashExpected = [string](Get-ConfigValue -Object $marker -Name 'SummarySha256' -DefaultValue '')
    if (Test-NonEmptyString $summaryHashExpected) {
        if ((Get-FileHashHex -Path $Paths.SourceSummaryPath).ToLowerInvariant() -ne $summaryHashExpected.ToLowerInvariant()) {
            return $false
        }
    }

    $zipHashExpected = [string](Get-ConfigValue -Object $marker -Name 'ReviewZipSha256' -DefaultValue '')
    if (Test-NonEmptyString $zipHashExpected) {
        if ((Get-FileHashHex -Path $Paths.SourceReviewZipPath).ToLowerInvariant() -ne $zipHashExpected.ToLowerInvariant()) {
            return $false
        }
    }

    return $true
}

function Get-TargetAutoloopContractRouteBadge {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$State)

    switch ($State) {
        'ready' { return 'ROUTE READY' }
        'partial' { return 'ROUTE CHECK' }
        'invalid' { return 'ROUTE CHECK' }
        default { return 'ROUTE EMPTY' }
    }
}

function Get-TargetAutoloopContractSnapshotCore {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$SummaryState,
        [Parameter(Mandatory)]$ReviewZipState,
        [Parameter(Mandatory)]$PublishReadyState
    )

    $publishValid = $false
    try {
        $publishValid = Test-TargetAutoloopPublishReadyValid -Paths $Paths -ExpectedTargetId $TargetId
    }
    catch {
        $publishValid = $false
    }

    $publishReadyExists = [bool](Get-ConfigValue -Object $PublishReadyState -Name 'Exists' -DefaultValue $false)
    $summaryExists = [bool](Get-ConfigValue -Object $SummaryState -Name 'Exists' -DefaultValue $false)
    $reviewZipExists = [bool](Get-ConfigValue -Object $ReviewZipState -Name 'Exists' -DefaultValue $false)
    $publishMarker = $null
    if ($publishReadyExists) {
        try {
            $publishMarker = Read-JsonObject -Path ([string]$Paths.PublishReadyPath)
        }
        catch {
            $publishMarker = $null
        }
    }

    $contractState = 'missing'
    $reason = 'no-contract-files'
    if ($publishValid) {
        $contractState = 'ready'
        $reason = 'publish-ready-valid'
    }
    elseif ($publishReadyExists) {
        $contractState = 'invalid'
        $reason = 'publish-ready-invalid'
    }
    elseif ($summaryExists -or $reviewZipExists) {
        $contractState = 'partial'
        if ($summaryExists -and $reviewZipExists) {
            $reason = 'summary-review-without-marker'
        }
        elseif ($summaryExists) {
            $reason = 'summary-only'
        }
        else {
            $reason = 'review-only'
        }
    }

    return [pscustomobject]@{
        State = $contractState
        Reason = $reason
        RouteBadge = (Get-TargetAutoloopContractRouteBadge -State $contractState)
        PublishReadyValid = [bool]$publishValid
        SummaryExists = [bool]$summaryExists
        ReviewZipExists = [bool]$reviewZipExists
        PublishReadyExists = [bool]$publishReadyExists
        OutputFingerprint = [string](Get-ConfigValue -Object $publishMarker -Name 'OutputFingerprint' -DefaultValue '')
        PublishedAt = [string](Get-ConfigValue -Object $publishMarker -Name 'PublishedAt' -DefaultValue '')
    }
}

function Get-TargetAutoloopContractFileExists {
    param(
        $Contract,
        [Parameter(Mandatory)][string]$FlatName,
        [Parameter(Mandatory)][string]$NestedName
    )

    if ([bool](Get-ConfigValue -Object $Contract -Name $FlatName -DefaultValue $false)) {
        return $true
    }

    $nested = Get-ConfigValue -Object $Contract -Name $NestedName -DefaultValue $null
    return [bool](Get-ConfigValue -Object $nested -Name 'Exists' -DefaultValue $false)
}

function Get-TargetAutoloopDeliverySnapshot {
    param(
        [Parameter(Mandatory)]$Contract,
        $StateRecord = $null,
        $StatusRow = $null,
        $RouterSessionState = $null,
        [switch]$UseRouterSessionFallback
    )

    $publishReadyExists = Get-TargetAutoloopContractFileExists -Contract $Contract -FlatName 'PublishReadyExists' -NestedName 'PublishReady'
    $summaryExists = Get-TargetAutoloopContractFileExists -Contract $Contract -FlatName 'SummaryExists' -NestedName 'Summary'
    $reviewZipExists = Get-TargetAutoloopContractFileExists -Contract $Contract -FlatName 'ReviewZipExists' -NestedName 'ReviewZip'
    $artifactState = if ([bool](Get-ConfigValue -Object $Contract -Name 'PublishReadyValid' -DefaultValue $false)) {
        'created'
    }
    elseif ($publishReadyExists) {
        'invalid-marker'
    }
    elseif ($summaryExists -or $reviewZipExists) {
        'partial'
    }
    else {
        'missing'
    }

    $markerFingerprint = [string](Get-ConfigValue -Object $Contract -Name 'OutputFingerprint' -DefaultValue '')
    $lastHandledOutputFingerprint = [string](Get-ConfigValue -Object $StateRecord -Name 'LastHandledOutputFingerprint' -DefaultValue ([string](Get-ConfigValue -Object $StatusRow -Name 'LastHandledOutputFingerprint' -DefaultValue '')))
    $watcherAccepted = (Test-NonEmptyString $markerFingerprint) -and ($markerFingerprint -eq $lastHandledOutputFingerprint)
    $watcherState = if ($artifactState -ne 'created') {
        'waiting-artifact'
    }
    elseif ($watcherAccepted) {
        'accepted-current-marker'
    }
    else {
        'not-yet-accepted-current-marker'
    }

    $lastDispatchState = [string](Get-ConfigValue -Object $StateRecord -Name 'LastDispatchState' -DefaultValue ([string](Get-ConfigValue -Object $StatusRow -Name 'LastDispatchState' -DefaultValue '')))
    $lastRouterReadyPath = [string](Get-ConfigValue -Object $StateRecord -Name 'LastRouterReadyPath' -DefaultValue ([string](Get-ConfigValue -Object $StatusRow -Name 'LastRouterReadyPath' -DefaultValue '')))
    $pendingDispatchEligibleAt = [string](Get-ConfigValue -Object $StateRecord -Name 'PendingDispatchEligibleAt' -DefaultValue ([string](Get-ConfigValue -Object $StatusRow -Name 'PendingDispatchEligibleAt' -DefaultValue '')))
    $pendingDispatchDelaySeconds = [int](Get-ConfigValue -Object $StateRecord -Name 'PendingDispatchDelaySeconds' -DefaultValue ([int](Get-ConfigValue -Object $StatusRow -Name 'PendingDispatchDelaySeconds' -DefaultValue 0)))
    $routerStateName = [string](Get-ConfigValue -Object $RouterSessionState -Name 'State' -DefaultValue '')
    $routerDelivered = $lastDispatchState -eq 'router-ready-file-created' -or (Test-NonEmptyString $lastRouterReadyPath)
    $routerStage = if ($routerDelivered) {
        'ready-file-created'
    }
    elseif ($lastDispatchState -eq 'dispatch-delay-waiting') {
        'dispatch-delay-waiting'
    }
    elseif ([bool]$UseRouterSessionFallback -and $lastDispatchState -in @('router-session-not-ready', 'router-session-mismatch')) {
        $lastDispatchState
    }
    elseif (Test-NonEmptyString $lastDispatchState) {
        if ([bool]$UseRouterSessionFallback) { 'dispatch-' + $lastDispatchState } else { $lastDispatchState }
    }
    elseif ([bool]$UseRouterSessionFallback -and (Test-NonEmptyString $routerStateName) -and $routerStateName -ne 'ok') {
        'router-' + $routerStateName
    }
    else {
        'not-delivered'
    }

    $nextActionCode = ''
    $nextActionLabel = ''
    $nextAction = if ($artifactState -eq 'missing') {
        $nextActionCode = 'create-artifacts'
        $nextActionLabel = '산출물 생성 필요'
        'summary.txt와 review.zip을 만든 뒤 publish helper로 publish.ready.json을 생성해야 합니다.'
    }
    elseif ($artifactState -eq 'partial') {
        $nextActionCode = 'complete-artifacts'
        $nextActionLabel = '누락 산출물 보완'
        'summary.txt/review.zip/publish.ready.json 중 누락된 산출물을 채운 뒤 publish helper를 다시 실행해야 합니다.'
    }
    elseif ($artifactState -eq 'invalid-marker') {
        $nextActionCode = 'regenerate-marker'
        $nextActionLabel = 'marker 재생성'
        'publish.ready.json marker가 strict contract 검증을 통과하지 못했습니다. helper로 marker를 다시 생성해야 합니다.'
    }
    elseif ($watcherState -eq 'not-yet-accepted-current-marker') {
        $nextActionCode = 'wait-or-restart-watcher'
        $nextActionLabel = 'watcher accepted 확인'
        'publish.ready.json은 생성됐지만 watcher accepted가 아직 없습니다. 감지기 running 상태, RunRoot, target 상태를 먼저 확인하세요.'
    }
    elseif ($lastDispatchState -eq 'dispatch-delay-waiting') {
        $nextActionCode = 'wait-dispatch-delay'
        $nextActionLabel = 'dispatch delay 확인'
        ('watcher는 marker를 accepted 처리했고 publish-ready dispatch delay 대기 중입니다. delaySeconds={0}, eligibleAt={1}' -f $pendingDispatchDelaySeconds, $(if (Test-NonEmptyString $pendingDispatchEligibleAt) { $pendingDispatchEligibleAt } else { '-' }))
    }
    elseif (-not $routerDelivered) {
        $nextActionCode = 'check-router-delivery'
        $nextActionLabel = 'router 전달 확인'
        if ([bool]$UseRouterSessionFallback) {
            ('watcher는 marker를 accepted 처리했지만 router 전달이 끝나지 않았습니다. router/runtime 세션과 ready 파일 소비 상태를 확인하세요. router={0}' -f $routerStage)
        }
        else {
            ('watcher는 marker를 accepted 처리했지만 router 전달이 끝나지 않았습니다. dispatch={0}' -f $routerStage)
        }
    }
    else {
        $nextActionCode = 'check-cell-processing'
        $nextActionLabel = '셀창 처리 확인'
        'router ready 파일이 생성됐습니다. 이후 셀창 처리/processed 상태와 다음 target queue 상태를 확인하세요.'
    }

    return [pscustomobject]@{
        Artifact = $artifactState
        Watcher = $watcherState
        Router = $routerStage
        CurrentMarkerFingerprint = $markerFingerprint
        LastHandledOutputFingerprint = $lastHandledOutputFingerprint
        LastDispatchState = $lastDispatchState
        LastRouterReadyPath = $lastRouterReadyPath
        PendingDispatchEligibleAt = $pendingDispatchEligibleAt
        PendingDispatchDelaySeconds = $pendingDispatchDelaySeconds
        Summary = ('artifact={0} / watcher={1} / router={2}' -f $artifactState, $watcherState, $routerStage)
        NextAction = $nextAction
        NextActionCode = $nextActionCode
        NextActionLabel = $nextActionLabel
    }
}

function Get-TargetAutoloopInputTriggerFingerprint {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $rawFingerprint = [ordered]@{
        Path = (Get-NormalizedFullPath -Path $Path)
        Length = [int64]$item.Length
        LastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
        ContentSha256 = (Get-FileHashHex -Path $Path).ToLowerInvariant()
    } | ConvertTo-Json -Depth 6 -Compress
    return (Get-TextHashHex -Text $rawFingerprint)
}

function Get-TargetAutoloopPublishReadyFingerprint {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ExpectedTargetId
    )

    if (-not (Test-TargetAutoloopPublishReadyValid -Paths $Paths -ExpectedTargetId $ExpectedTargetId)) {
        throw "publish.ready.json is not valid for target: $ExpectedTargetId"
    }

    $marker = Read-JsonObject -Path $Paths.PublishReadyPath
    $payload = [ordered]@{
        PublishReadyPath = (Get-NormalizedFullPath -Path $Paths.PublishReadyPath)
        TargetId = [string](Get-ConfigValue -Object $marker -Name 'TargetId' -DefaultValue '')
        PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
        PublishedBy = [string](Get-ConfigValue -Object $marker -Name 'PublishedBy' -DefaultValue '')
        CycleId = [int](Get-ConfigValue -Object $marker -Name 'CycleId' -DefaultValue 0)
        ParentCycleId = [int](Get-ConfigValue -Object $marker -Name 'ParentCycleId' -DefaultValue 0)
        OutputFingerprint = [string](Get-ConfigValue -Object $marker -Name 'OutputFingerprint' -DefaultValue '')
        SummaryPath = (Get-NormalizedFullPath -Path $Paths.SourceSummaryPath)
        SummarySha256 = (Get-FileHashHex -Path $Paths.SourceSummaryPath).ToLowerInvariant()
        ReviewZipPath = (Get-NormalizedFullPath -Path $Paths.SourceReviewZipPath)
        ReviewZipSha256 = (Get-FileHashHex -Path $Paths.SourceReviewZipPath).ToLowerInvariant()
    } | ConvertTo-Json -Depth 8 -Compress
    return (Get-TextHashHex -Text $payload)
}
