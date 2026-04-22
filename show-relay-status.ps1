[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$RecentCount = 5,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
. (Join-Path $PSScriptRoot 'router\BindingSessionScope.ps1')
. (Join-Path $PSScriptRoot 'router\RelayMessageMetadata.ps1')

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-ObjectPropertyValue {
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

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Format-CommandArgument {
    param([Parameter(Mandatory)][string]$Value)

    return ("'" + $Value.Replace("'", "''") + "'")
}

function Get-CommandText {
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

function Read-JsonDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('array', 'object')][string]$ExpectedShape
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists      = $false
            ParseError  = ''
            Data        = if ($ExpectedShape -eq 'array') { @() } else { $null }
            LastWriteAt = ''
        }
    }

    $lastWriteAt = (Get-Item -LiteralPath $Path).LastWriteTime.ToString('o')
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            Exists      = $true
            ParseError  = ''
            Data        = if ($ExpectedShape -eq 'array') { @() } else { $null }
            LastWriteAt = $lastWriteAt
        }
    }

    try {
        $parsed = ConvertFrom-RelayJsonText -Json $raw
    }
    catch {
        return [pscustomobject]@{
            Exists      = $true
            ParseError  = $_.Exception.Message
            Data        = if ($ExpectedShape -eq 'array') { @() } else { $null }
            LastWriteAt = $lastWriteAt
        }
    }

    $data = if ($ExpectedShape -eq 'array') {
        if ($null -eq $parsed) {
            @()
        }
        elseif ($parsed -is [System.Array]) {
            $parsed
        }
        else {
            ,$parsed
        }
    }
    else {
        $parsed
    }

    return [pscustomobject]@{
        Exists      = $true
        ParseError  = ''
        Data        = $data
        LastWriteAt = $lastWriteAt
    }
}

function Get-RecentFileSummaries {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [string]$Filter = '*',
        [int]$Count = 5
    )

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Path -Filter $Filter -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First $Count |
            ForEach-Object {
                [pscustomobject]@{
                    Name       = $_.Name
                    ModifiedAt = $_.LastWriteTime.ToString('o')
                    SizeBytes  = [int64]$_.Length
                }
            }
    )
}

function Get-IgnoredReasonDisplayLabel {
    param([AllowEmptyString()][string]$Code)

    switch ($Code) {
        'metadata-missing' { return '메타 없음' }
        'metadata-missing-fields' { return '메타 필수값 누락' }
        'preexisting-before-router-start' { return '이전 세션 ready' }
        'launcher-session-mismatch' { return '런처 세션 불일치' }
        'paired-metadata-missing-fields' { return 'pair 메타 필수값 누락' }
        'metadata-target-mismatch' { return 'target 메타 불일치' }
        'metadata-parse-failed' { return '메타 파싱 실패' }
        'message-type-unsupported' { return '지원하지 않는 message type' }
        'archive-metadata-missing' { return 'archive 메타 없음' }
        'archive-metadata-parse-failed' { return 'archive 메타 파싱 실패' }
        'unknown' { return '무시 사유 미확인' }
        default {
            if (Test-NonEmptyString $Code) {
                return $Code
            }

            return ''
        }
    }
}

function Get-IgnoredArchiveSummary {
    param([Parameter(Mandatory)][string]$ReadyFilePath)

    $archiveDocument = Read-ReadyFileArchiveMetadata -ReadyFilePath $ReadyFilePath
    $reasonCode = ''
    $reasonDetail = ''

    if (-not $archiveDocument.Exists) {
        $reasonCode = 'archive-metadata-missing'
        $reasonDetail = 'archive metadata missing'
    }
    elseif (Test-NonEmptyString $archiveDocument.ParseError) {
        $reasonCode = 'archive-metadata-parse-failed'
        $reasonDetail = [string]$archiveDocument.ParseError
    }
    else {
        $reasonCode = [string](Get-ObjectPropertyValue -Object $archiveDocument.Data -Name 'ArchiveReasonCode' -DefaultValue '')
        $reasonDetail = [string](Get-ObjectPropertyValue -Object $archiveDocument.Data -Name 'ArchiveReasonDetail' -DefaultValue '')
        if (-not (Test-NonEmptyString $reasonCode)) {
            $reasonCode = 'unknown'
        }
    }

    return [pscustomobject]@{
        ReasonCode               = $reasonCode
        ReasonLabel              = (Get-IgnoredReasonDisplayLabel -Code $reasonCode)
        ReasonDetail             = $reasonDetail
        ArchiveMetadataExists    = [bool]$archiveDocument.Exists
        ArchiveMetadataParseError = [string]$archiveDocument.ParseError
    }
}

function Get-IgnoredReasonCounts {
    param([AllowEmptyString()][string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $counts = @{}
    foreach ($item in Get-ChildItem -LiteralPath $Path -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue) {
        $summary = Get-IgnoredArchiveSummary -ReadyFilePath $item.FullName
        $reasonCode = [string]$summary.ReasonCode
        if (-not (Test-NonEmptyString $reasonCode)) {
            $reasonCode = 'unknown'
        }

        if ($counts.ContainsKey($reasonCode)) {
            $counts[$reasonCode] = [int]$counts[$reasonCode] + 1
        }
        else {
            $counts[$reasonCode] = 1
        }
    }

    $rows = foreach ($reasonCode in ($counts.Keys | Sort-Object)) {
        [pscustomobject]@{
            Code  = [string]$reasonCode
            Label = (Get-IgnoredReasonDisplayLabel -Code ([string]$reasonCode))
            Count = [int]$counts[$reasonCode]
        }
    }

    return @(
        $rows |
            Sort-Object `
                @{ Expression = { [int]$_.Count }; Descending = $true }, `
                @{ Expression = { [string]$_.Code }; Descending = $false }
    )
}

function Get-RecentIgnoredFileSummaries {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [int]$Count = 5
    )

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Path -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First $Count |
            ForEach-Object {
                $ignoredSummary = Get-IgnoredArchiveSummary -ReadyFilePath $_.FullName
                [pscustomobject]@{
                    Name        = $_.Name
                    ModifiedAt  = $_.LastWriteTime.ToString('o')
                    SizeBytes   = [int64]$_.Length
                    ReasonCode  = [string]$ignoredSummary.ReasonCode
                    ReasonLabel = [string]$ignoredSummary.ReasonLabel
                    ReasonDetail = [string]$ignoredSummary.ReasonDetail
                }
            }
    )
}

function Get-UnsafeRelaunchAuditSummary {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists      = $false
            ParseError  = ''
            Count       = 0
            LastWriteAt = ''
            LastRecord  = $null
        }
    }

    $lines = @(
        Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $count = (@($lines)).Count
    $lastWriteAt = (Get-Item -LiteralPath $Path).LastWriteTime.ToString('o')
    if ($count -eq 0) {
        return [pscustomobject]@{
            Exists      = $true
            ParseError  = ''
            Count       = 0
            LastWriteAt = $lastWriteAt
            LastRecord  = $null
        }
    }

    $lastRecord = $null
    try {
        $lastRecord = (ConvertFrom-RelayJsonText -Json $lines[-1])
    }
    catch {
        return [pscustomobject]@{
            Exists      = $true
            ParseError  = $_.Exception.Message
            Count       = $count
            LastWriteAt = $lastWriteAt
            LastRecord  = $null
        }
    }

    return [pscustomobject]@{
        Exists      = $true
        ParseError  = ''
        Count       = $count
        LastWriteAt = $lastWriteAt
        LastRecord  = $lastRecord
    }
}

function Get-StringList {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ } | Where-Object { Test-NonEmptyString $_ })
    }

    $single = [string]$Value
    if (Test-NonEmptyString $single) {
        return @($single)
    }

    return @()
}

function Resolve-IgnoredRoot {
    param(
        [Parameter(Mandatory)]$Config,
        $RouterState = $null
    )

    $routerStateIgnoredRoot = [string](Get-ObjectPropertyValue -Object $RouterState -Name 'IgnoredRoot' -DefaultValue '')
    if (Test-NonEmptyString $routerStateIgnoredRoot) {
        return $routerStateIgnoredRoot
    }

    $configIgnoredRoot = [string](Get-ObjectPropertyValue -Object $Config -Name 'IgnoredRoot' -DefaultValue '')
    if (Test-NonEmptyString $configIgnoredRoot) {
        return $configIgnoredRoot
    }

    $rootPath = [string](Get-ObjectPropertyValue -Object $Config -Name 'Root' -DefaultValue '')
    $inboxRoot = [string](Get-ObjectPropertyValue -Object $Config -Name 'InboxRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $rootPath) -or -not (Test-NonEmptyString $inboxRoot)) {
        return ''
    }

    $laneName = Split-Path -Leaf $inboxRoot
    return (Join-Path (Join-Path $rootPath 'ignored') $laneName)
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

$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$runtimeDoc = Read-JsonDocument -Path ([string]$config.RuntimeMapPath) -ExpectedShape 'array'
$routerStateDoc = Read-JsonDocument -Path ([string]$config.RouterStatePath) -ExpectedShape 'object'
$unsafeRelaunchAudit = Get-UnsafeRelaunchAuditSummary -Path (Join-Path ([string]$config.LogsRoot) 'unsafe-force-kill.log')
$bindingProfilePath = [string](Get-ObjectPropertyValue -Object $config -Name 'BindingProfilePath' -DefaultValue '')
$bindingProfileDoc = if (Test-NonEmptyString $bindingProfilePath) {
    Read-JsonDocument -Path $bindingProfilePath -ExpectedShape 'object'
}
else {
    [pscustomobject]@{
        Exists      = $false
        ParseError  = ''
        Data        = $null
        LastWriteAt = ''
    }
}
$runtimeItems = @($runtimeDoc.Data)
$routerState = $routerStateDoc.Data
$ignoredRoot = Resolve-IgnoredRoot -Config $config -RouterState $routerState
$bindingScope = Get-BindingSessionScope -Config $config -BindingDocument $bindingProfileDoc
$configuredTargetIds = @($bindingScope.ConfiguredTargetIds)
$expectedTargetIds = @($bindingScope.ExpectedTargetIds)
$bindingWindowEntries = @($bindingScope.BindingWindows)
$bindingWindowTargetIds = @($bindingScope.BindingWindowTargetIds)
$scopedBindingTargetIds = @($bindingScope.ScopedBindingTargetIds)
$runtimeById = @{}
$duplicateRuntimeIds = New-Object System.Collections.Generic.List[string]
$blankRuntimeIds = New-Object System.Collections.Generic.List[string]
$launcherSessionIds = @{}

foreach ($item in $runtimeItems) {
    $targetId = [string](Get-ObjectPropertyValue -Object $item -Name 'TargetId' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetId)) {
        $blankRuntimeIds.Add('<blank-target-id>')
        continue
    }

    if ($runtimeById.ContainsKey($targetId)) {
        $duplicateRuntimeIds.Add($targetId)
        continue
    }

    $runtimeById[$targetId] = $item
    $launcherSessionId = [string](Get-ObjectPropertyValue -Object $item -Name 'LauncherSessionId' -DefaultValue '')
    if (Test-NonEmptyString $launcherSessionId) {
        $launcherSessionIds[$launcherSessionId] = $true
    }
}

$actualTargetIds = @($runtimeById.Keys | Sort-Object)
$missingTargetIds = @($expectedTargetIds | Where-Object { $_ -notin $actualTargetIds })
$extraTargetIds = @($actualTargetIds | Where-Object { $_ -notin $expectedTargetIds })
$uniqueLauncherSessionIds = @($launcherSessionIds.Keys | Sort-Object)

$targetRows = @()
$readyFileTotal = 0
foreach ($target in $config.Targets | Sort-Object Id) {
    $targetId = [string]$target.Id
    $inScope = ($targetId -in $expectedTargetIds)
    $readyFileCount = if (Test-Path -LiteralPath ([string]$target.Folder)) {
        @(Get-ChildItem -LiteralPath ([string]$target.Folder) -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue).Count
    }
    else {
        0
    }

    $readyFileTotal += $readyFileCount
    $runtime = if ($runtimeById.ContainsKey($targetId)) { $runtimeById[$targetId] } else { $null }
    $runtimeHwnd = [string](Get-ObjectPropertyValue -Object $runtime -Name 'Hwnd' -DefaultValue '')
    $runtimeWindowPid = Get-ObjectPropertyValue -Object $runtime -Name 'WindowPid' -DefaultValue $null
    $runtimeShellPid = Get-ObjectPropertyValue -Object $runtime -Name 'ShellPid' -DefaultValue $null
    $runtimeResolvedBy = [string](Get-ObjectPropertyValue -Object $runtime -Name 'ResolvedBy' -DefaultValue '')
    $runtimeHostKind = [string](Get-ObjectPropertyValue -Object $runtime -Name 'HostKind' -DefaultValue '')
    $runtimeRegistrationMode = [string](Get-ObjectPropertyValue -Object $runtime -Name 'RegistrationMode' -DefaultValue '')
    $runtimeShellStartTimeUtc = [string](Get-ObjectPropertyValue -Object $runtime -Name 'ShellStartTimeUtc' -DefaultValue '')
    $runtimeManagedMarker = [string](Get-ObjectPropertyValue -Object $runtime -Name 'ManagedMarker' -DefaultValue '')
    $runtimeLauncherSessionId = [string](Get-ObjectPropertyValue -Object $runtime -Name 'LauncherSessionId' -DefaultValue '')
    $runtimeManagedMarkerPresent = Test-NonEmptyString $runtimeManagedMarker
    $runtimeStatus = if (-not $inScope -and $bindingScope.PartialReuse) {
        'out-of-scope'
    }
    elseif ($null -eq $runtime) {
        'missing'
    }
    elseif (Test-NonEmptyString $runtimeHwnd -and $null -ne $runtimeWindowPid -and [int]$runtimeWindowPid -gt 0) {
        'ready'
    }
    elseif ($runtimeResolvedBy -eq 'binding-file' -and $null -ne $runtimeWindowPid -and [int]$runtimeWindowPid -gt 0 -and $null -ne $runtimeShellPid -and [int]$runtimeShellPid -gt 0) {
        'ready'
    }
    else {
        'partial'
    }

    $targetRows += [pscustomobject]@{
        TargetId          = $targetId
        InScope           = [bool]$inScope
        ReadyFiles        = $readyFileCount
        RuntimeStatus     = $runtimeStatus
        Hwnd              = $runtimeHwnd
        WindowPid         = if ($null -ne $runtimeWindowPid) { [string]$runtimeWindowPid } else { '' }
        ShellPid          = if ($null -ne $runtimeShellPid) { [string]$runtimeShellPid } else { '' }
        ResolvedBy        = $runtimeResolvedBy
        HostKind          = $runtimeHostKind
        RegistrationMode  = $runtimeRegistrationMode
        ShellStartTimeUtc = $runtimeShellStartTimeUtc
        ManagedMarkerPresent = [bool]$runtimeManagedMarkerPresent
        Managed           = if ($runtimeManagedMarkerPresent) { 'yes' } else { '' }
        LauncherSessionId = $runtimeLauncherSessionId
    }
}

$attachedTargetCount = @($targetRows | Where-Object { $_.InScope -and $_.RegistrationMode -eq 'attached' }).Count
$launchedTargetCount = @($targetRows | Where-Object { $_.InScope -and $_.RegistrationMode -eq 'launched' }).Count
$managedMarkerCount = @($targetRows | Where-Object { $_.InScope -and $_.ManagedMarkerPresent }).Count
$shellStartTimePresentCount = @($targetRows | Where-Object { $_.InScope -and (Test-NonEmptyString $_.ShellStartTimeUtc) }).Count

$processedCount = if (Test-Path -LiteralPath ([string]$config.ProcessedRoot)) { @(Get-ChildItem -LiteralPath ([string]$config.ProcessedRoot) -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue).Count } else { 0 }
$failedCount = if (Test-Path -LiteralPath ([string]$config.FailedRoot)) { @(Get-ChildItem -LiteralPath ([string]$config.FailedRoot) -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue).Count } else { 0 }
$ignoredCount = if ((Test-NonEmptyString $ignoredRoot) -and (Test-Path -LiteralPath $ignoredRoot)) { @(Get-ChildItem -LiteralPath $ignoredRoot -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue).Count } else { 0 }
$retryPendingCount = if (Test-Path -LiteralPath ([string]$config.RetryPendingRoot)) { @(Get-ChildItem -LiteralPath ([string]$config.RetryPendingRoot) -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue).Count } else { 0 }
$ignoredReasonCounts = @(Get-IgnoredReasonCounts -Path $ignoredRoot)

$nextActions = New-Object System.Collections.Generic.List[string]
$commandRoot = $PSScriptRoot
$ensureTargetsCommand = Get-CommandText -Root $commandRoot -ScriptName 'ensure-targets.ps1' -ConfigPath $resolvedConfigPath
$checkTargetWindowVisibilityCommand = Get-CommandText -Root $commandRoot -ScriptName 'check-target-window-visibility.ps1' -ConfigPath $resolvedConfigPath
$startRouterCommand = Get-CommandText -Root $commandRoot -ScriptName 'router.ps1' -ConfigPath $resolvedConfigPath
$requeueCommand = Get-CommandText -Root $commandRoot -ScriptName 'router\Requeue-RetryPending.ps1' -ConfigPath $resolvedConfigPath
$attachFromBindingsCommand = if (Test-NonEmptyString $bindingProfilePath) {
    Get-CommandText -Root $commandRoot -ScriptName 'attach-targets-from-bindings.ps1' -ConfigPath $resolvedConfigPath
}
else {
    ''
}

if ($runtimeDoc.ParseError -or $missingTargetIds.Count -gt 0 -or $extraTargetIds.Count -gt 0 -or $duplicateRuntimeIds.Count -gt 0 -or $blankRuntimeIds.Count -gt 0 -or $uniqueLauncherSessionIds.Count -ne 1) {
    $nextActions.Add($ensureTargetsCommand)
    if (Test-NonEmptyString $attachFromBindingsCommand) {
        $nextActions.Add($attachFromBindingsCommand)
    }
}

if ($retryPendingCount -gt 0) {
    $nextActions.Add($requeueCommand)
}

$routerStatusValue = [string](Get-ObjectPropertyValue -Object $routerState -Name 'Status' -DefaultValue '')
$routerMutexName = [string](Get-ObjectPropertyValue -Object $routerState -Name 'RouterMutexName' -DefaultValue ([string](Get-ObjectPropertyValue -Object $config -Name 'RouterMutexName' -DefaultValue '')))
$routerMutexHeld = $false
if (Test-NonEmptyString $routerMutexName) {
    $routerMutexHeld = Test-MutexHeld -Name $routerMutexName
}

$routerStatus = if ($routerMutexHeld) {
    if (Test-NonEmptyString $routerStatusValue) {
        if ($routerStatusValue -eq 'failed') { 'running-existing' } else { $routerStatusValue }
    }
    else {
        'running-existing'
    }
}
elseif ($null -ne $routerState -and (Test-NonEmptyString $routerStatusValue)) {
    $routerStatusValue
}
else {
    'missing'
}

$configIgnorePreexistingReadyFiles = [bool](Get-ObjectPropertyValue -Object $config -Name 'IgnorePreexistingReadyFiles' -DefaultValue $false)
$configPreexistingHandlingMode = [string](Get-ObjectPropertyValue -Object $config -Name 'PreexistingHandlingMode' -DefaultValue $(if ($configIgnorePreexistingReadyFiles) { 'ignore-archive' } else { 'process' }))
$configRequireReadyDeliveryMetadata = [bool](Get-ObjectPropertyValue -Object $config -Name 'RequireReadyDeliveryMetadata' -DefaultValue $false)
$configRequirePairTransportMetadata = [bool](Get-ObjectPropertyValue -Object $config -Name 'RequirePairTransportMetadata' -DefaultValue $false)

$routerLastError = [string](Get-ObjectPropertyValue -Object $routerState -Name 'LastError' -DefaultValue '')
if (Test-NonEmptyString $routerLastError) {
    if ($routerLastError -like '*AHK exit code:*' -or $routerLastError -like '*window_not_found*' -or $routerLastError -like '*send_failed*') {
        $nextActions.Add($checkTargetWindowVisibilityCommand)
    }
}

if ($routerStatus -notin @('running', 'running-existing') -and $nextActions -notcontains $startRouterCommand) {
    $nextActions.Add($startRouterCommand)
}

$status = [pscustomobject]@{
    Root       = [string]$config.Root
    ConfigPath = $resolvedConfigPath
    Lane       = [pscustomobject]@{
        Name                   = [string](Get-ObjectPropertyValue -Object $config -Name 'LaneName' -DefaultValue '')
        WindowTitlePrefix      = [string](Get-ObjectPropertyValue -Object $config -Name 'WindowTitlePrefix' -DefaultValue '')
        LauncherWrapperPath    = [string](Get-ObjectPropertyValue -Object $config -Name 'LauncherWrapperPath' -DefaultValue '')
        BindingProfilePath     = $bindingProfilePath
        BindingProfileExists   = [bool]$bindingProfileDoc.Exists
        BindingProfileParseError = [string]$bindingProfileDoc.ParseError
        BindingProfileLastWriteAt = [string]$bindingProfileDoc.LastWriteAt
        BindingProfileName     = [string](Get-ObjectPropertyValue -Object $bindingProfileDoc.Data -Name 'profile_name' -DefaultValue '')
        BindingProfileTargetDir = [string](Get-ObjectPropertyValue -Object $bindingProfileDoc.Data -Name 'target_dir' -DefaultValue '')
        BindingProfileLaunchCommand = [string](Get-ObjectPropertyValue -Object $bindingProfileDoc.Data -Name 'launch_command' -DefaultValue '')
    }
    Router     = [pscustomobject]@{
        Status            = $routerStatus
        Exists            = [bool]$routerStateDoc.Exists
        ParseError        = [string]$routerStateDoc.ParseError
        LastWriteAt       = [string]$routerStateDoc.LastWriteAt
        RouterPid         = [int](Get-ObjectPropertyValue -Object $routerState -Name 'RouterPid' -DefaultValue 0)
        QueueCount        = [int](Get-ObjectPropertyValue -Object $routerState -Name 'QueueCount' -DefaultValue 0)
        PendingQueueCount = [int](Get-ObjectPropertyValue -Object $routerState -Name 'PendingQueueCount' -DefaultValue 0)
        LastError         = $routerLastError
        MutexName         = $routerMutexName
        MutexHeld         = [bool]$routerMutexHeld
        RouterStartedAt   = [string](Get-ObjectPropertyValue -Object $routerState -Name 'RouterStartedAt' -DefaultValue '')
        LauncherSessionId = [string](Get-ObjectPropertyValue -Object $routerState -Name 'LauncherSessionId' -DefaultValue '')
        StartupCutoffAt   = if ([bool](Get-ObjectPropertyValue -Object $routerState -Name 'IgnorePreexistingReadyFiles' -DefaultValue $configIgnorePreexistingReadyFiles)) { [string](Get-ObjectPropertyValue -Object $routerState -Name 'RouterStartedAt' -DefaultValue '') } else { '' }
        PreexistingHandlingMode = [string](Get-ObjectPropertyValue -Object $routerState -Name 'PreexistingHandlingMode' -DefaultValue $configPreexistingHandlingMode)
        IgnorePreexistingReadyFiles = [bool](Get-ObjectPropertyValue -Object $routerState -Name 'IgnorePreexistingReadyFiles' -DefaultValue $configIgnorePreexistingReadyFiles)
        RequireReadyDeliveryMetadata = [bool](Get-ObjectPropertyValue -Object $routerState -Name 'RequireReadyDeliveryMetadata' -DefaultValue $configRequireReadyDeliveryMetadata)
        RequirePairTransportMetadata = [bool](Get-ObjectPropertyValue -Object $routerState -Name 'RequirePairTransportMetadata' -DefaultValue $configRequirePairTransportMetadata)
        IgnoredRoot       = $ignoredRoot
    }
    Runtime    = [pscustomobject]@{
        Exists                 = [bool]$runtimeDoc.Exists
        ParseError             = [string]$runtimeDoc.ParseError
        LastWriteAt            = [string]$runtimeDoc.LastWriteAt
        ReuseMode              = [string]$bindingScope.ReuseMode
        PartialReuse           = [bool]$bindingScope.PartialReuse
        ConfiguredTargetCount  = [int]$bindingScope.ConfiguredTargetCount
        ExpectedTargetCount    = [int]$bindingScope.ExpectedTargetCount
        BindingWindowCount     = @($bindingWindowTargetIds).Count
        BindingWindowEntryCount = @($bindingWindowEntries).Count
        BindingUniqueTargetCount = @($bindingWindowTargetIds).Count
        BindingScopedWindowCount = @($scopedBindingTargetIds).Count
        BindingScopedTargetCount = @($scopedBindingTargetIds).Count
        ActivePairIds          = @($bindingScope.ActivePairIds)
        InactivePairIds        = @($bindingScope.InactivePairIds)
        IncompletePairIds      = @($bindingScope.IncompletePairIds)
        ActiveTargetIds        = @($expectedTargetIds)
        InactiveTargetIds      = @($bindingScope.InactiveTargetIds)
        OutOfScopeBindingTargetIds = @($bindingScope.OutOfScopeBindingTargetIds)
        OrphanMatchedTargetIds = @($bindingScope.OrphanMatchedTargetIds)
        SoftFindings           = @($bindingScope.SoftFindings)
        RuntimeEntryCount      = $runtimeItems.Count
        UniqueTargetCount      = $actualTargetIds.Count
        MissingTargetIds       = @($missingTargetIds)
        ExtraTargetIds         = @($extraTargetIds)
        DuplicateTargetIds     = @($duplicateRuntimeIds | Sort-Object -Unique)
        BlankTargetIds         = @($blankRuntimeIds | Sort-Object -Unique)
        LauncherSessionIds     = @($uniqueLauncherSessionIds)
        HasSingleLauncherSession = ($uniqueLauncherSessionIds.Count -eq 1)
        AttachedCount          = $attachedTargetCount
        LaunchedCount          = $launchedTargetCount
        ManagedMarkerCount     = $managedMarkerCount
        ShellStartTimeCount    = $shellStartTimePresentCount
    }
    Counts     = [pscustomobject]@{
        ReadyTotal    = $readyFileTotal
        Processed     = $processedCount
        Failed        = $failedCount
        Ignored       = $ignoredCount
        RetryPending  = $retryPendingCount
    }
    IgnoredReasonCounts = @($ignoredReasonCounts)
    Targets     = @($targetRows | Sort-Object TargetId)
    Recent       = [pscustomobject]@{
        Processed    = @(Get-RecentFileSummaries -Path ([string]$config.ProcessedRoot) -Filter '*.ready.txt' -Count $RecentCount)
        Failed       = @(Get-RecentFileSummaries -Path ([string]$config.FailedRoot) -Filter '*.ready.txt' -Count $RecentCount)
        Ignored      = @(Get-RecentIgnoredFileSummaries -Path $ignoredRoot -Count $RecentCount)
        RetryPending = @(Get-RecentFileSummaries -Path ([string]$config.RetryPendingRoot) -Filter '*.ready.txt' -Count $RecentCount)
    }
    UnsafeRelaunchAudit = [pscustomobject]@{
        Exists             = [bool]$unsafeRelaunchAudit.Exists
        ParseError         = [string]$unsafeRelaunchAudit.ParseError
        Count              = [int]$unsafeRelaunchAudit.Count
        LastWriteAt        = [string]$unsafeRelaunchAudit.LastWriteAt
        LastTimestampUtc   = [string](Get-ObjectPropertyValue -Object $unsafeRelaunchAudit.LastRecord -Name 'TimestampUtc' -DefaultValue '')
        LastUserName       = [string](Get-ObjectPropertyValue -Object $unsafeRelaunchAudit.LastRecord -Name 'UserName' -DefaultValue '')
        LastMachineName    = [string](Get-ObjectPropertyValue -Object $unsafeRelaunchAudit.LastRecord -Name 'MachineName' -DefaultValue '')
        LastRoot           = [string](Get-ObjectPropertyValue -Object $unsafeRelaunchAudit.LastRecord -Name 'Root' -DefaultValue '')
        LastConfigPath     = [string](Get-ObjectPropertyValue -Object $unsafeRelaunchAudit.LastRecord -Name 'ConfigPath' -DefaultValue '')
        LastLauncherSessionId = [string](Get-ObjectPropertyValue -Object $unsafeRelaunchAudit.LastRecord -Name 'LauncherSessionId' -DefaultValue '')
    }
    NextActions = @($nextActions | Select-Object -Unique)
}

if ($AsJson) {
    $status | ConvertTo-Json -Depth 8
    return
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('Relay Status')
$lines.Add(('Root: {0}' -f $status.Root))
$lines.Add(('Config: {0}' -f $status.ConfigPath))
if (Test-NonEmptyString $status.Lane.Name) {
    $lines.Add(('Lane: {0}' -f $status.Lane.Name))
}
if (Test-NonEmptyString $status.Lane.WindowTitlePrefix) {
    $lines.Add(('Window Prefix: {0}' -f $status.Lane.WindowTitlePrefix))
}
if (Test-NonEmptyString $status.Lane.BindingProfilePath) {
    $lines.Add(('Binding Profile: exists={0} path={1}' -f $status.Lane.BindingProfileExists, $status.Lane.BindingProfilePath))
    if (Test-NonEmptyString $status.Lane.BindingProfileLastWriteAt) {
        $lines.Add(('Binding Profile LastWriteAt: {0}' -f $status.Lane.BindingProfileLastWriteAt))
    }
    if (Test-NonEmptyString $status.Lane.BindingProfileName) {
        $lines.Add(('Binding Profile Name: {0}' -f $status.Lane.BindingProfileName))
    }
    if (Test-NonEmptyString $status.Lane.BindingProfileLaunchCommand) {
        $lines.Add(('Binding Launch Command: {0}' -f $status.Lane.BindingProfileLaunchCommand))
    }
    if (Test-NonEmptyString $status.Lane.BindingProfileParseError) {
        $lines.Add(('Binding Profile ParseError: {0}' -f $status.Lane.BindingProfileParseError))
    }
    $lines.Add(('Binding Windows: scoped-targets={0} unique-targets={1} entries={2}' -f $status.Runtime.BindingScopedTargetCount, $status.Runtime.BindingUniqueTargetCount, $status.Runtime.BindingWindowEntryCount))
}
$lines.Add(('Router: status={0} pid={1} queue={2} pending={3}' -f $status.Router.Status, $status.Router.RouterPid, $status.Router.QueueCount, $status.Router.PendingQueueCount))
if (Test-NonEmptyString $status.Router.RouterStartedAt) {
    $lines.Add(('Router StartedAt: {0}' -f $status.Router.RouterStartedAt))
}
if ($status.Router.IgnorePreexistingReadyFiles) {
    $lines.Add(('Router IgnorePreexistingReadyFiles: true root={0}' -f $status.Router.IgnoredRoot))
    if (Test-NonEmptyString $status.Router.StartupCutoffAt) {
        $lines.Add(('Router StartupCutoffAt: {0}' -f $status.Router.StartupCutoffAt))
    }
}
if (Test-NonEmptyString $status.Router.PreexistingHandlingMode) {
    $lines.Add(('Router PreexistingHandlingMode: {0}' -f $status.Router.PreexistingHandlingMode))
}
if ($status.Router.RequireReadyDeliveryMetadata -or $status.Router.RequirePairTransportMetadata) {
    $lines.Add(('Router MetadataContract: ready={0} pair={1}' -f $status.Router.RequireReadyDeliveryMetadata, $status.Router.RequirePairTransportMetadata))
}

if (Test-NonEmptyString $status.Router.LastError) {
    $lines.Add(('Router LastError: {0}' -f $status.Router.LastError))
}

if (Test-NonEmptyString $status.Router.ParseError) {
    $lines.Add(('Router State ParseError: {0}' -f $status.Router.ParseError))
}

$lines.Add(('Runtime: entries={0}/{1} unique={2} sessions={3} configured={4}' -f $status.Runtime.RuntimeEntryCount, $status.Runtime.ExpectedTargetCount, $status.Runtime.UniqueTargetCount, $status.Runtime.LauncherSessionIds.Count, $status.Runtime.ConfiguredTargetCount))
$lines.Add(('Runtime Scope: mode={0} partial={1}' -f $status.Runtime.ReuseMode, $status.Runtime.PartialReuse))
$lines.Add(('Runtime ActivePairs: {0}' -f ($(if ($status.Runtime.ActivePairIds.Count -gt 0) { $status.Runtime.ActivePairIds -join ', ' } else { '(none)' }))))
if ($status.Runtime.InactiveTargetIds.Count -gt 0) {
    $lines.Add(('Runtime InactiveTargets: {0}' -f ($status.Runtime.InactiveTargetIds -join ', ')))
}
if ($status.Runtime.IncompletePairIds.Count -gt 0) {
    $lines.Add(('Runtime IncompletePairs: {0}' -f ($status.Runtime.IncompletePairIds -join ', ')))
}
if ($status.Runtime.OutOfScopeBindingTargetIds.Count -gt 0) {
    $lines.Add(('Runtime OutOfScopeBindings: {0}' -f ($status.Runtime.OutOfScopeBindingTargetIds -join ', ')))
}
if ($status.Runtime.OrphanMatchedTargetIds.Count -gt 0) {
    $lines.Add(('Runtime Orphans: {0}' -f ($status.Runtime.OrphanMatchedTargetIds -join ', ')))
}
if ($status.Runtime.SoftFindings.Count -gt 0) {
    $lines.Add(('Runtime SoftFindings: {0}' -f ($status.Runtime.SoftFindings -join ', ')))
}
$lines.Add(('Runtime Modes: attached={0} launched={1} managedMarkers={2} shellStartTimes={3}' -f $status.Runtime.AttachedCount, $status.Runtime.LaunchedCount, $status.Runtime.ManagedMarkerCount, $status.Runtime.ShellStartTimeCount))
if ($status.Runtime.MissingTargetIds.Count -gt 0) {
    $lines.Add(('Runtime Missing: {0}' -f ($status.Runtime.MissingTargetIds -join ', ')))
}
if ($status.Runtime.ExtraTargetIds.Count -gt 0) {
    $lines.Add(('Runtime Extra: {0}' -f ($status.Runtime.ExtraTargetIds -join ', ')))
}
if ($status.Runtime.DuplicateTargetIds.Count -gt 0) {
    $lines.Add(('Runtime Duplicates: {0}' -f ($status.Runtime.DuplicateTargetIds -join ', ')))
}
if ($status.Runtime.BlankTargetIds.Count -gt 0) {
    $lines.Add(('Runtime BlankIds: {0}' -f ($status.Runtime.BlankTargetIds -join ', ')))
}
if (Test-NonEmptyString $status.Runtime.ParseError) {
    $lines.Add(('Runtime ParseError: {0}' -f $status.Runtime.ParseError))
}

$lines.Add(('Unsafe Relaunch Audit: count={0} last={1}' -f $status.UnsafeRelaunchAudit.Count, $(if (Test-NonEmptyString $status.UnsafeRelaunchAudit.LastTimestampUtc) { $status.UnsafeRelaunchAudit.LastTimestampUtc } else { '-' })))
if (Test-NonEmptyString $status.UnsafeRelaunchAudit.LastUserName) {
    $lines.Add(('Unsafe Relaunch Last: user={0} machine={1} session={2}' -f $status.UnsafeRelaunchAudit.LastUserName, $status.UnsafeRelaunchAudit.LastMachineName, $status.UnsafeRelaunchAudit.LastLauncherSessionId))
}
if (Test-NonEmptyString $status.UnsafeRelaunchAudit.ParseError) {
    $lines.Add(('Unsafe Relaunch ParseError: {0}' -f $status.UnsafeRelaunchAudit.ParseError))
}

$lines.Add(('Counts: ready={0} processed={1} failed={2} ignored={3} retry-pending={4}' -f $status.Counts.ReadyTotal, $status.Counts.Processed, $status.Counts.Failed, $status.Counts.Ignored, $status.Counts.RetryPending))
if (@($status.IgnoredReasonCounts).Count -gt 0) {
    $ignoredReasonSummary = @(
        $status.IgnoredReasonCounts |
            ForEach-Object {
                if (Test-NonEmptyString ([string]$_.Label)) {
                    return ('{0}={1}' -f [string]$_.Label, [int]$_.Count)
                }

                return ('{0}={1}' -f [string]$_.Code, [int]$_.Count)
            }
    )
    if ($ignoredReasonSummary.Count -gt 0) {
        $lines.Add(('Ignored Reasons: {0}' -f ($ignoredReasonSummary -join ', ')))
    }
}
$lines.Add('')
$lines.Add('Targets')
$targetTable = ($status.Targets | Format-Table TargetId, ReadyFiles, RuntimeStatus, RegistrationMode, Managed, Hwnd, WindowPid, ResolvedBy, HostKind -AutoSize | Out-String).TrimEnd()
$lines.Add($targetTable)

foreach ($section in @('Processed', 'Failed', 'Ignored', 'RetryPending')) {
    $lines.Add('')
    $lines.Add(("Recent {0}" -f $section))
    $items = @($status.Recent.$section)
    if ($items.Count -eq 0) {
        $lines.Add('- (none)')
        continue
    }

    foreach ($item in $items) {
        if ($section -eq 'Ignored' -and (Test-NonEmptyString ([string]$item.ReasonCode))) {
            $reasonText = if (Test-NonEmptyString ([string]$item.ReasonLabel)) { [string]$item.ReasonLabel } else { [string]$item.ReasonCode }
            $lines.Add(('- {0} [{1}] reason={2}' -f $item.Name, $item.ModifiedAt, $reasonText))
            continue
        }

        $lines.Add(('- {0} [{1}]' -f $item.Name, $item.ModifiedAt))
    }
}

$lines.Add('')
$lines.Add('Next Actions')
if ($status.NextActions.Count -eq 0) {
    $lines.Add('- (none)')
}
else {
    foreach ($command in $status.NextActions) {
        $lines.Add(('- {0}' -f $command))
    }
}

$lines
