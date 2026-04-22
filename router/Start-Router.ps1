[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$RunDurationMs = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

. (Join-Path $PSScriptRoot 'RuntimeMap.ps1')
. (Join-Path $PSScriptRoot 'FileQueue.ps1')
. (Join-Path $PSScriptRoot 'RelayMessageMetadata.ps1')
. (Join-Path $PSScriptRoot 'MessageArchive.ps1')

function New-Utf8StrictEncoding {
    return [System.Text.UTF8Encoding]::new($false, $true)
}

function Write-RelayLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level.ToUpperInvariant(), $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    Write-Host $line
}

function Write-RetryPendingMetadata {
    param(
        [Parameter(Mandatory)][string]$RetryPath,
        [Parameter(Mandatory)][string]$FailureCategory,
        [Parameter(Mandatory)][string]$FailureMessage,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$OriginalPath,
        [Parameter(Mandatory)][int]$Attempt
    )

    if (-not (Test-Path -LiteralPath $RetryPath -PathType Leaf)) {
        return
    }

    $metadataPath = ($RetryPath + '.meta.json')
    $payload = [ordered]@{
        SchemaVersion = '1.0.0'
        RetryPath = $RetryPath
        FailureCategory = $FailureCategory
        FailureMessage = $FailureMessage
        TargetId = $TargetId
        OriginalPath = $OriginalPath
        Attempt = $Attempt
        RecordedAt = (Get-Date).ToString('o')
    }

    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
}

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-Config {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config not found: $Path"
    }

    $config = Import-PowerShellDataFile -Path $Path
    Test-Config -Config $config
    return $config
}

function Test-Config {
    param([Parameter(Mandatory)]$Config)

    foreach ($propertyName in @(
        'Root', 'InboxRoot', 'ProcessedRoot', 'FailedRoot', 'RetryPendingRoot', 'RuntimeRoot',
        'RuntimeMapPath', 'RouterStatePath', 'RouterMutexName', 'LogsRoot', 'RouterLogPath', 'AhkExePath',
        'AhkScriptPath', 'ShellPath', 'ResolverShellPath', 'MaxPayloadChars', 'MaxPayloadBytes', 'SweepIntervalMs',
        'IdleSleepMs', 'RetryDelayMs', 'MaxRetryCount', 'SendTimeoutMs'
    )) {
        if ($null -eq $Config.$propertyName) {
            throw "Missing config property: $propertyName"
        }
    }

    foreach ($propertyName in @('Root', 'InboxRoot', 'ProcessedRoot', 'FailedRoot', 'RetryPendingRoot', 'RuntimeRoot', 'LogsRoot', 'RouterLogPath', 'RuntimeMapPath', 'RouterStatePath', 'RouterMutexName', 'AhkExePath', 'AhkScriptPath', 'ResolverShellPath')) {
        if (-not (Test-NonEmptyString $Config.$propertyName)) {
            throw "Missing or empty config property: $propertyName"
        }
    }

    if (-not (Test-Path -LiteralPath ([string]$Config.AhkExePath))) {
        throw "AutoHotkey executable not found: $($Config.AhkExePath)"
    }

    if (-not (Test-Path -LiteralPath ([string]$Config.AhkScriptPath))) {
        throw "AutoHotkey script not found: $($Config.AhkScriptPath)"
    }

    if (-not $Config.Targets -or $Config.Targets.Count -ne 8) {
        throw 'Config must contain exactly 8 targets.'
    }

    $idSet = @{}
    $titleSet = @{}
    $folderSet = @{}

    foreach ($target in $Config.Targets) {
        foreach ($propertyName in @('Id', 'WindowTitle', 'Folder')) {
            if (-not (Test-NonEmptyString $target.$propertyName)) {
                throw "Target missing property: $propertyName"
            }
        }

        $id = [string]$target.Id
        $title = [string]$target.WindowTitle
        $folder = Normalize-RelayPath -Path ([string]$target.Folder)

        if ($idSet.ContainsKey($id)) { throw "Duplicate target id: $id" }
        if ($titleSet.ContainsKey($title)) { throw "Duplicate window title: $title" }
        if ($folderSet.ContainsKey($folder)) { throw "Duplicate target folder: $folder" }

        $idSet[$id] = $true
        $titleSet[$title] = $true
        $folderSet[$folder] = $true
    }
}

function Resolve-IgnoredRoot {
    param([Parameter(Mandatory)]$Config)

    $explicitValue = $null
    if (TryGet-RelaySettingValue -Config $Config -Name 'IgnoredRoot' -Value ([ref]$explicitValue) -AllowNull:$false) {
        $explicitPath = [string]$explicitValue
        if (Test-NonEmptyString $explicitPath) {
            return $explicitPath
        }
    }

    $laneName = Split-Path -Leaf ([string]$Config.InboxRoot)
    return (Join-Path (Join-Path ([string]$Config.Root) 'ignored') $laneName)
}

function Wait-UntilFileReadable {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutMs = 5000
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $fs.Dispose()
            return $true
        }
        catch {
            Start-Sleep -Milliseconds 150
        }
    }

    return $false
}

function Get-EffectiveFixedSuffix {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Target
    )

    if ($null -ne $Target.FixedSuffix) {
        return [string]$Target.FixedSuffix
    }

    return [string]$Config.DefaultFixedSuffix
}

function Get-EffectiveEnterCount {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Target
    )

    if ($null -ne $Target.EnterCount) {
        return [int]$Target.EnterCount
    }

    return [int]$Config.DefaultEnterCount
}

function Get-RelayTimingSetting {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$DefaultValue
    )

    $value = $null
    if (TryGet-RelaySettingValue -Config $Config -Name $Name -Value ([ref]$value) -AllowNull:$false) {
        return [int]$value
    }

    return $DefaultValue
}

function Get-AdjustedTextSettleSetting {
    param(
        [Parameter(Mandatory)]$Config,
        [AllowEmptyString()][string]$Payload
    )

    $baseTextSettleMs = Get-RelayTimingSetting -Config $Config -Name 'TextSettleMs' -DefaultValue 400
    $perKbTextSettleMs = Get-RelayTimingSetting -Config $Config -Name 'TextSettlePerKbMs' -DefaultValue 0
    $maxTextSettleMs = Get-RelayTimingSetting -Config $Config -Name 'TextSettleMaxMs' -DefaultValue $baseTextSettleMs
    $maxTextSettleMs = [Math]::Max($baseTextSettleMs, $maxTextSettleMs)

    $payloadBytes = 0
    if (-not [string]::IsNullOrEmpty($Payload)) {
        $payloadBytes = [System.Text.Encoding]::UTF8.GetByteCount($Payload)
    }

    $extraTextSettleMs = 0
    if ($perKbTextSettleMs -gt 0 -and $payloadBytes -gt 0) {
        $payloadKb = [Math]::Ceiling($payloadBytes / 1024.0)
        $extraTextSettleMs = [int]($payloadKb * $perKbTextSettleMs)
    }

    $effectiveTextSettleMs = [int]($baseTextSettleMs + $extraTextSettleMs)
    if ($effectiveTextSettleMs -gt $maxTextSettleMs) {
        $effectiveTextSettleMs = $maxTextSettleMs
    }

    return [pscustomobject]@{
        PayloadBytes          = [int]$payloadBytes
        BaseTextSettleMs      = [int]$baseTextSettleMs
        ExtraTextSettleMs     = [int]$extraTextSettleMs
        MaxTextSettleMs       = [int]$maxTextSettleMs
        EffectiveTextSettleMs = [int]$effectiveTextSettleMs
    }
}

function Get-RelayBooleanSetting {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$DefaultValue
    )

    $value = $null
    if (TryGet-RelaySettingValue -Config $Config -Name $Name -Value ([ref]$value) -AllowNull:$false) {
        return [bool]$value
    }

    return $DefaultValue
}

function Get-RelayStringListSetting {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$DefaultValues
    )

    $value = $null
    if (-not (TryGet-RelaySettingValue -Config $Config -Name $Name -Value ([ref]$value) -AllowNull:$false)) {
        return @($DefaultValues)
    }

    if ($value -is [System.Array]) {
        $items = @(
            $value |
                ForEach-Object { [string]$_ } |
                Where-Object { Test-NonEmptyString $_ } |
                ForEach-Object { $_.Trim().ToLowerInvariant() }
        )
        if ($items.Count -gt 0) {
            return $items
        }

        return @($DefaultValues)
    }

    $text = [string]$value
    if (-not (Test-NonEmptyString $text)) {
        return @($DefaultValues)
    }

    $parsed = @(
        $text -split '[,;]' |
            ForEach-Object { [string]$_ } |
            Where-Object { Test-NonEmptyString $_ } |
            ForEach-Object { $_.Trim().ToLowerInvariant() }
    )

    if ($parsed.Count -gt 0) {
        return $parsed
    }

    return @($DefaultValues)
}

function TryGet-RelaySettingValue {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ref]$Value,
        [switch]$AllowNull
    )

    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains($Name)) {
            $candidate = $Config[$Name]
            if ($AllowNull -or $null -ne $candidate) {
                $Value.Value = $candidate
                return $true
            }
        }

        return $false
    }

    $property = $Config.PSObject.Properties[$Name]
    if ($null -ne $property) {
        if ($AllowNull -or $null -ne $property.Value) {
            $Value.Value = $property.Value
            return $true
        }

        return $false
    }

    return $false
}

function Normalize-MultilineText {
    param([Parameter(Mandatory)][string]$Value)

    return (($Value -replace "`r?`n", "`r`n").TrimEnd([char[]]"`r`n"))
}

function Compose-Payload {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter()][AllowEmptyString()][string]$FixedSuffix
    )

    $normalizedBody = Normalize-MultilineText -Value $Body

    if ($null -eq $FixedSuffix -or $FixedSuffix.Length -eq 0) {
        return $normalizedBody
    }

    $normalizedSuffix = Normalize-MultilineText -Value $FixedSuffix
    return ($normalizedBody + "`r`n`r`n" + $normalizedSuffix)
}

function New-RelayFailureMessage {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )

    return ($Category + '::' + $Message)
}

function Resolve-RelayFailure {
    param([Parameter(Mandatory)][string]$Text)

    if ($Text -match '^(?<category>[a-z_]+)::(?<message>.*)$') {
        return [pscustomobject]@{
            Category = $Matches['category']
            Message  = $Matches['message']
        }
    }

    return [pscustomobject]@{
        Category = 'send_failed'
        Message  = $Text
    }
}

function Resolve-RelayArchiveReason {
    param([Parameter(Mandatory)][string]$Message)

    if ($Message -match '^(?<code>[a-z0-9-]+):\s*(?<detail>.*)$') {
        return [pscustomobject]@{
            Code   = [string]$Matches['code']
            Detail = [string]$Matches['detail']
        }
    }

    return [pscustomobject]@{
        Code   = 'unknown'
        Detail = [string]$Message
    }
}

function Set-WorkItemObservedCreatedAtDiagnostics {
    param(
        [Parameter(Mandatory)]$Item,
        [string]$RawValue = '',
        [string]$UtcValue = ''
    )

    foreach ($entry in @(
            @{ Name = 'ObservedCreatedAtRaw'; Value = [string]$RawValue },
            @{ Name = 'ObservedCreatedAtUtc'; Value = [string]$UtcValue }
        )) {
        $property = $Item.PSObject.Properties[[string]$entry.Name]
        if ($null -eq $property) {
            $Item | Add-Member -NotePropertyName ([string]$entry.Name) -NotePropertyValue ([string]$entry.Value)
            continue
        }

        $property.Value = [string]$entry.Value
    }
}

function Acquire-RouterMutex {
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
            throw "router mutex already held: $Name"
        }

        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Get-LauncherRuntimeContext {
    param([Parameter(Mandatory)]$RuntimeItems)

    $sessionIds = @(
        $RuntimeItems |
            ForEach-Object { [string]$_.LauncherSessionId } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    $launchedAtValues = @(
        $RuntimeItems |
            ForEach-Object { [string]$_.LaunchedAt } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object |
            Select-Object -Unique
    )
    $launcherPids = @(
        $RuntimeItems |
            ForEach-Object {
                if ($null -ne $_.LauncherPid -and [int]$_.LauncherPid -gt 0) {
                    [int]$_.LauncherPid
                }
            } |
            Sort-Object |
            Select-Object -Unique
    )
    $hostKinds = @(
        $RuntimeItems |
            ForEach-Object { [string]$_.HostKind } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object |
            Select-Object -Unique
    )

    return [pscustomobject]@{
        LauncherSessionId = if ($sessionIds.Count -eq 1) { $sessionIds[0] } elseif ($sessionIds.Count -gt 1) { ($sessionIds -join ',') } else { '' }
        LaunchedAt        = if ($launchedAtValues.Count -ge 1) { $launchedAtValues[0] } else { '' }
        LauncherPid       = if ($launcherPids.Count -eq 1) { [int]$launcherPids[0] } else { 0 }
        HostKinds         = @($hostKinds)
        SessionCount      = $sessionIds.Count
    }
}

function Format-CommandArgument {
    param([Parameter(Mandatory)][string]$Value)

    return ("'" + $Value.Replace("'", "''") + "'")
}

function Get-RootCommandText {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ScriptName,
        [string]$ConfigPath = '',
        [string[]]$ExtraArguments = @()
    )

    $tokens = @(
        'powershell',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Format-CommandArgument -Value (Join-Path $Root $ScriptName))
    )

    if (Test-NonEmptyString $ConfigPath) {
        $tokens += @('-ConfigPath', (Format-CommandArgument -Value $ConfigPath))
    }

    foreach ($argument in $ExtraArguments) {
        if (Test-NonEmptyString $argument) {
            $tokens += $argument
        }
    }

    return ($tokens -join ' ')
}

function New-ActionableMessage {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string[]]$NextCommands = @()
    )

    $commands = @(
        $NextCommands |
            Where-Object { Test-NonEmptyString $_ } |
            Select-Object -Unique
    )

    if ($commands.Count -eq 0) {
        return $Message
    }

    return ($Message + ' next: ' + ($commands -join ' | next: '))
}

function Test-LauncherRuntimeContext {
    param(
        [Parameter(Mandatory)]$RuntimeItems,
        [Parameter(Mandatory)][string]$RuntimeMapPath
    )

    $blankSessionTargetIds = New-Object System.Collections.Generic.List[string]
    $sessionIdSet = @{}

    foreach ($item in $RuntimeItems) {
        $targetId = if ($null -ne $item.TargetId) { [string]$item.TargetId } else { '<blank-target-id>' }
        $launcherSessionId = if ($null -ne $item.LauncherSessionId) { [string]$item.LauncherSessionId } else { '' }

        if ([string]::IsNullOrWhiteSpace($launcherSessionId)) {
            $blankSessionTargetIds.Add($targetId)
            continue
        }

        $sessionIdSet[$launcherSessionId] = $true
    }

    if ($blankSessionTargetIds.Count -gt 0) {
        $blankTargets = @($blankSessionTargetIds | Sort-Object -Unique)
        throw "Runtime map contains blank LauncherSessionId: $RuntimeMapPath targets=$($blankTargets -join ', ')"
    }

    $sessionIds = @($sessionIdSet.Keys | Sort-Object)
    if ($sessionIds.Count -ne 1) {
        throw "Runtime map must contain exactly one LauncherSessionId: $RuntimeMapPath sessions=$($sessionIds -join ', ')"
    }
}

function Test-RuntimeMapTargets {
    param(
        [Parameter(Mandatory)]$RuntimeItems,
        [Parameter(Mandatory)]$Targets,
        [Parameter(Mandatory)][string]$RuntimeMapPath
    )

    $expectedIds = @($Targets | ForEach-Object { [string]$_.Id } | Sort-Object -Unique)
    $actualIds = @()
    $actualIdSet = @{}
    $duplicateIds = New-Object System.Collections.Generic.List[string]

    foreach ($item in $RuntimeItems) {
        $targetId = if ($null -ne $item.TargetId) { [string]$item.TargetId } else { '' }
        if ([string]::IsNullOrWhiteSpace($targetId)) {
            throw "Runtime map contains blank target id: $RuntimeMapPath"
        }

        $actualIds += $targetId
        if ($actualIdSet.ContainsKey($targetId)) {
            $duplicateIds.Add($targetId)
            continue
        }

        $actualIdSet[$targetId] = $true
    }

    if ($duplicateIds.Count -gt 0) {
        $duplicates = @($duplicateIds | Sort-Object -Unique)
        throw "Runtime map contains duplicate target ids: $($duplicates -join ', ')"
    }

    $actualUniqueIds = @($actualIdSet.Keys | Sort-Object)
    $missingIds = @($expectedIds | Where-Object { $_ -notin $actualUniqueIds })
    $extraIds = @($actualUniqueIds | Where-Object { $_ -notin $expectedIds })

    if ($missingIds.Count -gt 0 -or $extraIds.Count -gt 0) {
        $parts = @()
        if ($missingIds.Count -gt 0) {
            $parts += ('missing=' + ($missingIds -join ','))
        }
        if ($extraIds.Count -gt 0) {
            $parts += ('extra=' + ($extraIds -join ','))
        }

        throw "Runtime map target ids do not match config: $($parts -join '; ')"
    }
}

function Get-FailureCategoryFromAhkExitCode {
    param([int]$ExitCode)

    switch ($ExitCode) {
        0 { return 'success' }
        12 { return 'file_invalid' }
        13 { return 'file_invalid' }
        15 { return 'window_not_found' }
        20 { return 'window_not_found' }
        42 { return 'focus_lost' }
        43 { return 'user_active_hold' }
        40 { return 'send_failed' }
        default { return 'send_failed' }
    }
}

function ConvertTo-SafeRelayFileToken {
    param([string]$Value)

    if (-not (Test-NonEmptyString $Value)) {
        return 'message'
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Value.ToCharArray()) {
        if ($char -in $invalidChars -or [char]::IsWhiteSpace($char)) {
            [void]$builder.Append('_')
            continue
        }

        [void]$builder.Append($char)
    }

    $safeValue = $builder.ToString().Trim('_')
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return 'message'
    }

    return $safeValue
}

function New-AhkDebugLogPath {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetId,
        [string]$PayloadLabel = ''
    )

    $debugRoot = Join-Path ([string]$Config.LogsRoot) 'ahk-debug'
    $targetRoot = Join-Path $debugRoot $TargetId
    Ensure-Directory -Path $targetRoot

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $label = ConvertTo-SafeRelayFileToken -Value ([System.IO.Path]::GetFileNameWithoutExtension($PayloadLabel))
    $fileName = 'send_{0}__{1}.log' -f $stamp, $label
    return (Join-Path $targetRoot $fileName)
}

function Invoke-AhkSend {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$Payload,
        [Parameter(Mandatory)][int]$EnterCount,
        [string]$PayloadLabel = ''
    )

    $payloadFile = Join-Path ([string]$Config.LogsRoot) ('payload_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($payloadFile, $Payload, (New-Utf8NoBomEncoding))
    $debugLogPath = New-AhkDebugLogPath -Config $Config -TargetId $TargetId -PayloadLabel $PayloadLabel

    $activateSettleMs = Get-RelayTimingSetting -Config $Config -Name 'ActivateSettleMs' -DefaultValue 120
    $textSettle = Get-AdjustedTextSettleSetting -Config $Config -Payload $Payload
    $textSettleMs = [int]$textSettle.EffectiveTextSettleMs
    $enterDelayMs = Get-RelayTimingSetting -Config $Config -Name 'EnterDelayMs' -DefaultValue 150
    $postSubmitDelayMs = Get-RelayTimingSetting -Config $Config -Name 'PostSubmitDelayMs' -DefaultValue 150
    $submitRetryModes = @(Get-RelayStringListSetting -Config $Config -Name 'SubmitRetryModes' -DefaultValues @('enter'))
    $submitRetryIntervalMs = Get-RelayTimingSetting -Config $Config -Name 'SubmitRetryIntervalMs' -DefaultValue 1000
    $requireActiveBeforeEnter = Get-RelayBooleanSetting -Config $Config -Name 'RequireActiveBeforeEnter' -DefaultValue $true
    $requireUserIdleBeforeSend = Get-RelayBooleanSetting -Config $Config -Name 'RequireUserIdleBeforeSend' -DefaultValue $false
    $minUserIdleBeforeSendMs = Get-RelayTimingSetting -Config $Config -Name 'MinUserIdleBeforeSendMs' -DefaultValue 0
    $requireActiveBeforeEnterArg = if ($requireActiveBeforeEnter) { '1' } else { '0' }
    $requireUserIdleBeforeSendArg = if ($requireUserIdleBeforeSend) { '1' } else { '0' }

    try {
        $proc = Start-Process -FilePath ([string]$Config.AhkExePath) -ArgumentList @(
            [string]$Config.AhkScriptPath,
            '--runtime', [string]$Config.RuntimeMapPath,
            '--targetId', $TargetId,
            '--resolverShell', [string]$Config.ResolverShellPath,
            '--file', $payloadFile,
            '--enter', [string]$EnterCount,
            '--timeoutMs', [string]$Config.SendTimeoutMs,
            '--activateSettleMs', [string]$activateSettleMs,
            '--textSettleMs', [string]$textSettleMs,
            '--enterDelayMs', [string]$enterDelayMs,
            '--postSubmitDelayMs', [string]$postSubmitDelayMs,
            '--submitModes', ([string]::Join(',', $submitRetryModes)),
            '--submitRetryIntervalMs', [string]$submitRetryIntervalMs,
            '--requireActiveBeforeEnter', $requireActiveBeforeEnterArg,
            '--requireUserIdleBeforeSend', $requireUserIdleBeforeSendArg,
            '--minUserIdleBeforeSendMs', [string]$minUserIdleBeforeSendMs,
            '--debugLog', $debugLogPath
        ) -Wait -PassThru -WindowStyle Hidden

        return [pscustomobject]@{
            ExitCode = [int]$proc.ExitCode
            DebugLogPath = $debugLogPath
            PayloadBytes = [int]$textSettle.PayloadBytes
            TextSettleMs = [int]$textSettleMs
            BaseTextSettleMs = [int]$textSettle.BaseTextSettleMs
            ExtraTextSettleMs = [int]$textSettle.ExtraTextSettleMs
        }
    }
    finally {
        if (Test-Path -LiteralPath $payloadFile) {
            Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Process-WorkItem {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$LogPath,
        [datetime]$RouterStartedAtUtc = [datetime]::MinValue,
        [string]$ExpectedLauncherSessionId = ''
    )

    $path = [string]$Item.Path

    if (-not (Test-Path -LiteralPath $path)) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'file_invalid' -Message "file not found: $path")))
    }

    if (-not (Wait-UntilFileReadable -Path $path -TimeoutMs ([int]$Config.SendTimeoutMs))) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'file_invalid' -Message "file not readable within timeout: $path")))
    }

    $metadataDocument = Read-ReadyFileMetadata -ReadyFilePath $path
    $requireReadyDeliveryMetadata = Get-RelayBooleanSetting -Config $Config -Name 'RequireReadyDeliveryMetadata' -DefaultValue $false
    $requirePairTransportMetadata = Get-RelayBooleanSetting -Config $Config -Name 'RequirePairTransportMetadata' -DefaultValue $false
    if ($requireReadyDeliveryMetadata -and -not $metadataDocument.Exists) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'ignored' -Message "metadata-missing: path=$path")))
    }

    if (Test-RelayMetadataNonEmptyString ([string]$metadataDocument.ParseError)) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'ignored' -Message "metadata-parse-failed: $($metadataDocument.Path) error=$($metadataDocument.ParseError)")))
    }

    $metadataMessageType = [string](Get-RelayMetadataPropertyValue -Object $metadataDocument.Data -Name 'MessageType' -DefaultValue '')
    $shouldValidateMetadataFields = $requireReadyDeliveryMetadata -or ($requirePairTransportMetadata -and (Test-IsPairRelayMessageType -MessageType $metadataMessageType))
    if ($shouldValidateMetadataFields) {
        $requiredFieldNames = @(Get-ReadyFileMetadataRequiredFieldNames -MessageType $metadataMessageType -RequirePairTransportMetadata:$requirePairTransportMetadata)
        $missingMetadataFields = @(Get-RelayMetadataMissingRequiredFieldNames -Object $metadataDocument.Data -RequiredFieldNames $requiredFieldNames)
        if ($missingMetadataFields.Count -gt 0) {
            $reasonCode = if ($requirePairTransportMetadata -and (Test-IsPairRelayMessageType -MessageType $metadataMessageType)) { 'paired-metadata-missing-fields' } else { 'metadata-missing-fields' }
            throw (New-Object System.Exception((New-RelayFailureMessage -Category 'ignored' -Message "${reasonCode}: messageType=$metadataMessageType fields=$($missingMetadataFields -join ',') path=$path")))
        }
    }

    if ($requirePairTransportMetadata -and (Test-IsPairRelayMessageType -MessageType $metadataMessageType) -and -not (Test-IsSupportedPairedRelayMessageType -MessageType $metadataMessageType)) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'ignored' -Message "message-type-unsupported: messageType=$metadataMessageType path=$path")))
    }

    $metadataTargetId = [string](Get-RelayMetadataPropertyValue -Object $metadataDocument.Data -Name 'TargetId' -DefaultValue '')
    if ((Test-RelayMetadataNonEmptyString $metadataTargetId) -and ($metadataTargetId.Trim() -ne ([string]$Target.Id).Trim())) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'ignored' -Message "metadata-target-mismatch: expected=$([string]$Target.Id) actual=$metadataTargetId path=$path")))
    }

    $metadataLauncherSessionId = [string](Get-RelayMetadataPropertyValue -Object $metadataDocument.Data -Name 'LauncherSessionId' -DefaultValue '')
    if ((Test-RelayMetadataNonEmptyString $metadataLauncherSessionId) -and (Test-RelayMetadataNonEmptyString $ExpectedLauncherSessionId) -and ($metadataLauncherSessionId.Trim() -ne $ExpectedLauncherSessionId.Trim())) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'ignored' -Message "launcher-session-mismatch: expected=$ExpectedLauncherSessionId actual=$metadataLauncherSessionId path=$path")))
    }

    $ignorePreexistingReadyFiles = Get-RelayBooleanSetting -Config $Config -Name 'IgnorePreexistingReadyFiles' -DefaultValue $false
    if ($ignorePreexistingReadyFiles -and $RouterStartedAtUtc -ne [datetime]::MinValue) {
        $readyCreatedAtUtc = [datetime]::MinValue
        $observedCreatedAtRaw = ''
        $observedCreatedAtUtc = ''
        $metadataCreatedAt = [string](Get-RelayMetadataPropertyValue -Object $metadataDocument.Data -Name 'CreatedAt' -DefaultValue '')
        if (Test-RelayMetadataNonEmptyString $metadataCreatedAt) {
            $observedCreatedAtRaw = $metadataCreatedAt
            $parsedMetadataCreatedAt = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($metadataCreatedAt, [ref]$parsedMetadataCreatedAt)) {
                $readyCreatedAtUtc = $parsedMetadataCreatedAt.UtcDateTime
                $observedCreatedAtUtc = $readyCreatedAtUtc.ToString('o')
            }
        }
        if ($readyCreatedAtUtc -eq [datetime]::MinValue) {
            $readyCreatedAtUtc = (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTimeUtc
            $observedCreatedAtUtc = $readyCreatedAtUtc.ToString('o')
        }
        Set-WorkItemObservedCreatedAtDiagnostics -Item $Item -RawValue $observedCreatedAtRaw -UtcValue $observedCreatedAtUtc
        if ($readyCreatedAtUtc -lt $RouterStartedAtUtc) {
            throw (New-Object System.Exception((New-RelayFailureMessage -Category 'ignored' -Message "preexisting-before-router-start: created=$($readyCreatedAtUtc.ToString('o')) cutoff=$($RouterStartedAtUtc.ToString('o')) path=$path")))
        }
    }

    try {
        $body = [System.IO.File]::ReadAllText($path, (New-Utf8StrictEncoding))
    }
    catch {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'encoding_error' -Message "utf8 read failed: $path")))
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'file_invalid' -Message "empty txt: $path")))
    }

    $fixedSuffix = Get-EffectiveFixedSuffix -Config $Config -Target $Target
    $enterCount = Get-EffectiveEnterCount -Config $Config -Target $Target
    $payload = Compose-Payload -Body $body -FixedSuffix $fixedSuffix

    if ($payload.Length -gt [int]$Config.MaxPayloadChars) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'file_invalid' -Message "payload chars exceeded: $($payload.Length)")))
    }

    $payloadBytes = (New-Utf8NoBomEncoding).GetByteCount($payload)
    if ($payloadBytes -gt [int]$Config.MaxPayloadBytes) {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category 'file_invalid' -Message "payload bytes exceeded: $payloadBytes")))
    }

    $submitRetryModes = @(Get-RelayStringListSetting -Config $Config -Name 'SubmitRetryModes' -DefaultValues @('enter'))
    $sendResult = Invoke-AhkSend -Config $Config -TargetId ([string]$Target.Id) -Payload $payload -EnterCount $enterCount -PayloadLabel ([System.IO.Path]::GetFileName($path))
    $exitCode = [int]$sendResult.ExitCode
    Write-RelayLog -Path $LogPath -Level 'info' -Message ("sending target={0} enter={1} submitModes={2} file={3} payloadBytes={4} textSettleMs={5} ahkDebugLog={6}" -f $Target.Id, $enterCount, ($submitRetryModes -join '>'), $path, $sendResult.PayloadBytes, $sendResult.TextSettleMs, $sendResult.DebugLogPath)
    $category = Get-FailureCategoryFromAhkExitCode -ExitCode $exitCode

    if ($category -ne 'success') {
        throw (New-Object System.Exception((New-RelayFailureMessage -Category $category -Message "AHK exit code: $exitCode debugLog=$($sendResult.DebugLogPath)")))
    }

    Write-RelayLog -Path $LogPath -Level 'info' -Message "input sequence complete target=$($Target.Id) file=$path ahkDebugLog=$($sendResult.DebugLogPath)"
}

$config = Get-Config -Path $ConfigPath
$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$ignorePreexistingReadyFiles = Get-RelayBooleanSetting -Config $config -Name 'IgnorePreexistingReadyFiles' -DefaultValue $false
$requireReadyDeliveryMetadata = Get-RelayBooleanSetting -Config $config -Name 'RequireReadyDeliveryMetadata' -DefaultValue $false
$requirePairTransportMetadata = Get-RelayBooleanSetting -Config $config -Name 'RequirePairTransportMetadata' -DefaultValue $false
$preexistingHandlingMode = if ($ignorePreexistingReadyFiles) { 'ignore-archive' } else { 'process' }
$ignoredRoot = Resolve-IgnoredRoot -Config $config

foreach ($path in @(
    $config.Root, $config.InboxRoot, $config.ProcessedRoot, $config.FailedRoot,
    $config.RetryPendingRoot, $config.RuntimeRoot, $config.LogsRoot, $ignoredRoot
)) {
    Ensure-Directory -Path ([string]$path)
}

foreach ($target in $config.Targets) {
    Ensure-Directory -Path ([string]$target.Folder)
}

$targetById = @{}
foreach ($target in $config.Targets) {
    $targetById[[string]$target.Id] = $target
}

$logPath = [string]$config.RouterLogPath
if (-not (Test-Path -LiteralPath $logPath)) {
    [System.IO.File]::WriteAllText($logPath, '', (New-Utf8NoBomEncoding))
}

$queue = [System.Collections.Generic.Queue[object]]::new()
$stateMap = @{}
$watchers = @()
$eventSourceIds = @()
$lastError = ''
$currentItem = $null
$runTimer = [System.Diagnostics.Stopwatch]::StartNew()
$routerStatus = 'running'
$runtimeItems = @()
$routerMutex = $null
$routerStateCommon = @{}
$routerStateCache = @{}
$routerMutexName = [string]$config.RouterMutexName
$launcherContext = $null
$routerStartedAt = ''
$routerStartedAtUtc = [datetime]::MinValue
$commandRoot = Split-Path -Parent $PSScriptRoot
$ensureTargetsCommand = Get-RootCommandText -Root $commandRoot -ScriptName 'ensure-targets.ps1' -ConfigPath $resolvedConfigPath
$showStatusCommand = Get-RootCommandText -Root $commandRoot -ScriptName 'show-relay-status.ps1' -ConfigPath $resolvedConfigPath
$routerStateCommon = @{
    RouterMutexName    = $routerMutexName
    RouterPid          = $PID
    RouterStartedAt    = ''
    LauncherSessionId  = ''
    LauncherLaunchedAt = ''
    LauncherPid        = 0
    HostKinds          = @()
    PreexistingHandlingMode = [string]$preexistingHandlingMode
    IgnorePreexistingReadyFiles = [bool]$ignorePreexistingReadyFiles
    RequireReadyDeliveryMetadata = [bool]$requireReadyDeliveryMetadata
    RequirePairTransportMetadata = [bool]$requirePairTransportMetadata
    IgnoredRoot        = [string]$ignoredRoot
}

try {
    try {
        $routerMutex = Acquire-RouterMutex -Name $routerMutexName
    }
    catch {
        throw (New-Object System.Exception((New-ActionableMessage -Message $_.Exception.Message -NextCommands @($showStatusCommand))))
    }

    try {
        $runtimeItems = Read-RuntimeMap -Path ([string]$config.RuntimeMapPath)
    }
    catch {
        throw (New-Object System.Exception((New-ActionableMessage -Message $_.Exception.Message -NextCommands @($ensureTargetsCommand, $showStatusCommand))))
    }

    if ($runtimeItems.Count -ne $config.Targets.Count) {
        $message = "Runtime map must contain $($config.Targets.Count) targets: $($config.RuntimeMapPath)"
        throw (New-Object System.Exception((New-ActionableMessage -Message $message -NextCommands @($ensureTargetsCommand, $showStatusCommand))))
    }

    try {
        Test-RuntimeMapTargets -RuntimeItems $runtimeItems -Targets $config.Targets -RuntimeMapPath ([string]$config.RuntimeMapPath)
    }
    catch {
        throw (New-Object System.Exception((New-ActionableMessage -Message $_.Exception.Message -NextCommands @($ensureTargetsCommand, $showStatusCommand))))
    }

    try {
        Test-LauncherRuntimeContext -RuntimeItems $runtimeItems -RuntimeMapPath ([string]$config.RuntimeMapPath)
    }
    catch {
        throw (New-Object System.Exception((New-ActionableMessage -Message $_.Exception.Message -NextCommands @($ensureTargetsCommand, $showStatusCommand))))
    }

    $launcherContext = Get-LauncherRuntimeContext -RuntimeItems $runtimeItems
    $routerStartedAt = (Get-Date).ToString('o')
    $routerStartedAtUtc = [datetimeoffset]::Parse($routerStartedAt).UtcDateTime
    $routerStateCommon = @{
        RouterMutexName    = $routerMutexName
        RouterPid          = $PID
        RouterStartedAt    = $routerStartedAt
        LauncherSessionId  = [string]$launcherContext.LauncherSessionId
        LauncherLaunchedAt = [string]$launcherContext.LaunchedAt
        LauncherPid        = [int]$launcherContext.LauncherPid
        HostKinds          = @($launcherContext.HostKinds)
        PreexistingHandlingMode = [string]$preexistingHandlingMode
        IgnorePreexistingReadyFiles = [bool]$ignorePreexistingReadyFiles
        RequireReadyDeliveryMetadata = [bool]$requireReadyDeliveryMetadata
        RequirePairTransportMetadata = [bool]$requirePairTransportMetadata
        IgnoredRoot        = [string]$ignoredRoot
    }

    Write-RelayLog -Path $logPath -Level 'info' -Message "router started pid=$PID mutex=$routerMutexName launcherSession=$($launcherContext.LauncherSessionId) launcherPid=$($launcherContext.LauncherPid) ignorePreexisting=$ignorePreexistingReadyFiles preexistingMode=$preexistingHandlingMode requireReadyMetadata=$requireReadyDeliveryMetadata requirePairMetadata=$requirePairTransportMetadata ignoredRoot=$ignoredRoot"

    foreach ($target in $config.Targets) {
        $folder = [string]$target.Folder
        $targetId = [string]$target.Id

        $watcher = [System.IO.FileSystemWatcher]::new($folder, '*.ready.txt')
        $watcher.IncludeSubdirectories = $false
        $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, CreationTime'
        $watcher.EnableRaisingEvents = $true
        $watchers += $watcher

        foreach ($eventName in @('Created', 'Renamed')) {
            $sourceId = "RelayFs.$targetId.$eventName"
            Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $sourceId | Out-Null
            $eventSourceIds += $sourceId
        }

        Write-RelayLog -Path $logPath -Level 'info' -Message "watching target=$targetId folder=$folder"
    }

    $lastSweep = [datetime]::MinValue

    while ($true) {
        if ($RunDurationMs -gt 0 -and $runTimer.ElapsedMilliseconds -ge $RunDurationMs) {
            break
        }

        $fsEvents = @(Get-Event | Where-Object { $_.SourceIdentifier -like 'RelayFs.*' })
        foreach ($ev in $fsEvents) {
            try {
                $parts = $ev.SourceIdentifier.Split('.')
                $targetId = $parts[1]
                $path = [string]$ev.SourceEventArgs.FullPath

                if ($targetById.ContainsKey($targetId)) {
                    Enqueue-ReadyFile -Path $path -TargetId $targetId -Queue $queue -StateMap $stateMap -LogPath $logPath -Reason $ev.SourceIdentifier
                }
            }
            finally {
                Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
            }
        }

        $now = Get-Date
        if (($now - $lastSweep).TotalMilliseconds -ge [int]$config.SweepIntervalMs) {
            foreach ($target in $config.Targets) {
                Get-ChildItem -LiteralPath ([string]$target.Folder) -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc, Name |
                    ForEach-Object {
                        Enqueue-ReadyFile -Path $_.FullName -TargetId ([string]$target.Id) -Queue $queue -StateMap $stateMap -LogPath $logPath -Reason 'periodic-scan'
                    }
            }

            $lastSweep = $now
        }

        if ($queue.Count -eq 0) {
            Write-RouterState -Path ([string]$config.RouterStatePath) -Queue $queue -StateMap $stateMap -CurrentItem $currentItem -LastError $lastError -Status $routerStatus -StateCache $routerStateCache @routerStateCommon | Out-Null
            Start-Sleep -Milliseconds ([int]$config.IdleSleepMs)
            continue
        }

        $item = $queue.Dequeue()
        $currentItem = $item
        $stateMap[[string]$item.StateKey] = 'processing'
        $target = $targetById[[string]$item.TargetId]
        $attemptsAllowed = [int]$config.MaxRetryCount + 1
        $attempt = 0
        $done = $false

        while (-not $done) {
            $attempt += 1

            try {
                Write-RelayLog -Path $logPath -Level 'info' -Message "processing attempt=$attempt/$attemptsAllowed target=$($target.Id) file=$($item.Path)"
                Process-WorkItem -Config $config -Target $target -Item $item -LogPath $logPath -RouterStartedAtUtc $routerStartedAtUtc -ExpectedLauncherSessionId ([string]$launcherContext.LauncherSessionId)

                $processedPath = Move-MessageToArchive -SourcePath ([string]$item.Path) -DestinationRoot ([string]$config.ProcessedRoot) -TargetId ([string]$target.Id)
                if ($null -ne $processedPath) {
                    Write-RelayLog -Path $logPath -Level 'info' -Message "moved to processed: $processedPath"
                }

                $done = $true
                $lastError = ''
            }
            catch {
                $failure = Resolve-RelayFailure -Text $_.Exception.Message
                $lastError = ($failure.Category + ': ' + $failure.Message)
                $failureLogLevel = if ($failure.Category -in @('window_not_found', 'focus_lost', 'user_active_hold', 'ignored')) { 'warn' } else { 'error' }
                Write-RelayLog -Path $logPath -Level $failureLogLevel -Message "attempt failed target=$($target.Id) file=$($item.Path) category=$($failure.Category) reason=$($failure.Message)"

                switch ($failure.Category) {
                    'window_not_found' {
                        $retryPath = Move-MessageToArchive -SourcePath ([string]$item.Path) -DestinationRoot ([string]$config.RetryPendingRoot) -TargetId ([string]$target.Id)
                        if ($null -ne $retryPath) {
                            Write-RetryPendingMetadata -RetryPath $retryPath -FailureCategory $failure.Category -FailureMessage $failure.Message -TargetId ([string]$target.Id) -OriginalPath ([string]$item.Path) -Attempt $attempt
                            Write-RelayLog -Path $logPath -Level 'warn' -Message "moved to retry-pending: $retryPath"
                        }
                        $done = $true
                    }
                    'focus_lost' {
                        $retryPath = Move-MessageToArchive -SourcePath ([string]$item.Path) -DestinationRoot ([string]$config.RetryPendingRoot) -TargetId ([string]$target.Id)
                        if ($null -ne $retryPath) {
                            Write-RetryPendingMetadata -RetryPath $retryPath -FailureCategory $failure.Category -FailureMessage $failure.Message -TargetId ([string]$target.Id) -OriginalPath ([string]$item.Path) -Attempt $attempt
                            Write-RelayLog -Path $logPath -Level 'warn' -Message "moved to retry-pending: $retryPath"
                        }
                        $done = $true
                    }
                    'user_active_hold' {
                        $retryPath = Move-MessageToArchive -SourcePath ([string]$item.Path) -DestinationRoot ([string]$config.RetryPendingRoot) -TargetId ([string]$target.Id)
                        if ($null -ne $retryPath) {
                            Write-RetryPendingMetadata -RetryPath $retryPath -FailureCategory $failure.Category -FailureMessage $failure.Message -TargetId ([string]$target.Id) -OriginalPath ([string]$item.Path) -Attempt $attempt
                            Write-RelayLog -Path $logPath -Level 'warn' -Message "moved to retry-pending: $retryPath"
                        }
                        $done = $true
                    }
                    'ignored' {
                        $ignoredPath = Move-MessageToArchive -SourcePath ([string]$item.Path) -DestinationRoot $ignoredRoot -TargetId ([string]$target.Id)
                        if ($null -ne $ignoredPath) {
                            $archiveReason = Resolve-RelayArchiveReason -Message ([string]$failure.Message)
                            $observedCreatedAtRaw = if ($null -ne $item.PSObject.Properties['ObservedCreatedAtRaw']) { [string]$item.ObservedCreatedAtRaw } else { '' }
                            $observedCreatedAtUtc = if ($null -ne $item.PSObject.Properties['ObservedCreatedAtUtc']) { [string]$item.ObservedCreatedAtUtc } else { '' }
                            Write-ReadyFileArchiveMetadata `
                                -ReadyFilePath ([string]$ignoredPath) `
                                -ArchiveState 'ignored' `
                                -ReasonCode ([string]$archiveReason.Code) `
                                -ReasonDetail ([string]$archiveReason.Detail) `
                                -ObservedCreatedAtRaw $observedCreatedAtRaw `
                                -ObservedCreatedAtUtc $observedCreatedAtUtc | Out-Null
                            Write-RelayLog -Path $logPath -Level 'warn' -Message "moved to ignored: $ignoredPath"
                        }
                        $done = $true
                    }
                    'send_failed' {
                        if ($attempt -lt $attemptsAllowed) {
                            Start-Sleep -Milliseconds ([int]$config.RetryDelayMs)
                        }
                        else {
                            $failedPath = Move-MessageToArchive -SourcePath ([string]$item.Path) -DestinationRoot ([string]$config.FailedRoot) -TargetId ([string]$target.Id)
                            if ($null -ne $failedPath) {
                                Write-RelayLog -Path $logPath -Level 'error' -Message "moved to failed: $failedPath"
                            }
                            $done = $true
                        }
                    }
                    default {
                        $failedPath = Move-MessageToArchive -SourcePath ([string]$item.Path) -DestinationRoot ([string]$config.FailedRoot) -TargetId ([string]$target.Id)
                        if ($null -ne $failedPath) {
                            Write-RelayLog -Path $logPath -Level 'error' -Message "moved to failed: $failedPath"
                        }
                        $done = $true
                    }
                }
            }
        }

        $stateMap.Remove([string]$item.StateKey) | Out-Null
        $currentItem = $null
        Write-RouterState -Path ([string]$config.RouterStatePath) -Queue $queue -StateMap $stateMap -CurrentItem $currentItem -LastError $lastError -Status $routerStatus -StateCache $routerStateCache @routerStateCommon | Out-Null
    }
}
catch {
    $routerStatus = 'failed'
    $lastError = $_.Exception.Message
    throw
}
finally {
    if ($routerStatus -ne 'failed') {
        $routerStatus = 'stopped'
    }

    foreach ($id in $eventSourceIds) {
        Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
    }

    foreach ($watcher in $watchers) {
        try {
            $watcher.EnableRaisingEvents = $false
            $watcher.Dispose()
        }
        catch {
        }
    }

    Get-Event | Where-Object { $_.SourceIdentifier -like 'RelayFs.*' } | ForEach-Object {
        Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue
    }

    Write-RouterState -Path ([string]$config.RouterStatePath) -Queue $queue -StateMap $stateMap -CurrentItem $currentItem -LastError $lastError -Status $routerStatus -StoppedAt ((Get-Date).ToString('o')) -StateCache $routerStateCache -Force @routerStateCommon | Out-Null

    if ($null -ne $routerMutex) {
        try {
            $routerMutex.ReleaseMutex()
        }
        catch {
        }

        $routerMutex.Dispose()
    }
}
