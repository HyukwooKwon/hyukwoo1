[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
. (Join-Path $PSScriptRoot '..\router\BindingSessionScope.ps1')
. (Join-Path $PSScriptRoot 'WindowDiscovery.ps1')

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Convert-ToUtcDateTime {
    param([object]$Value)

    if (-not (Test-NonEmptyString $Value)) {
        return $null
    }

    $text = [string]$Value
    if ($text.EndsWith('Z')) {
        $text = $text.Substring(0, $text.Length - 1) + '+00:00'
    }

    try {
        return ([datetimeoffset]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
    }
    catch {
        return $null
    }
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

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-ProcessHandleInfo {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return [pscustomobject]@{
            Exists            = $false
            ProcessName       = ''
            MainWindowHandle  = 0
            MainWindowTitle   = ''
            StartTimeUtc      = ''
        }
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return [pscustomobject]@{
            Exists            = $true
            ProcessName       = [string]$process.ProcessName
            MainWindowHandle  = [int64]$process.MainWindowHandle
            MainWindowTitle   = [string]$process.MainWindowTitle
            StartTimeUtc      = $process.StartTime.ToUniversalTime().ToString('o')
        }
    }
    catch {
        return [pscustomobject]@{
            Exists            = $false
            ProcessName       = ''
            MainWindowHandle  = 0
            MainWindowTitle   = ''
            StartTimeUtc      = ''
        }
    }
}

function Select-FirstVisibleLocator {
    param(
        [Parameter(Mandatory)]$ByHwnd,
        [Parameter(Mandatory)]$ByWindowPid,
        [Parameter(Mandatory)]$ByShellPid,
        [Parameter(Mandatory)]$ByTitle
    )

    if (@($ByHwnd).Count -gt 0) {
        return [pscustomobject]@{
            Injectable = $true
            Method     = 'hwnd'
            Match      = @($ByHwnd)[0]
            Reason     = ''
        }
    }

    if (@($ByWindowPid).Count -gt 0) {
        return [pscustomobject]@{
            Injectable = $true
            Method     = 'windowPid'
            Match      = @($ByWindowPid)[0]
            Reason     = ''
        }
    }

    if (@($ByShellPid).Count -gt 0) {
        return [pscustomobject]@{
            Injectable = $true
            Method     = 'shellPid'
            Match      = @($ByShellPid)[0]
            Reason     = ''
        }
    }

    $titleMatches = @($ByTitle)
    if ($titleMatches.Count -eq 1) {
        return [pscustomobject]@{
            Injectable = $true
            Method     = 'title'
            Match      = $titleMatches[0]
            Reason     = ''
        }
    }

    if ($titleMatches.Count -gt 1) {
        return [pscustomobject]@{
            Injectable = $false
            Method     = 'title'
            Match      = $null
            Reason     = 'duplicate-visible-title'
        }
    }

    return [pscustomobject]@{
        Injectable = $false
        Method     = ''
        Match      = $null
        Reason     = 'no-visible-window'
    }
}

function Read-RuntimeItems {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists      = $false
            ParseError  = ''
            LastWriteAt = ''
            Items       = @()
        }
    }

    $lastWriteAt = (Get-Item -LiteralPath $Path).LastWriteTime.ToString('o')
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            Exists      = $true
            ParseError  = ''
            LastWriteAt = $lastWriteAt
            Items       = @()
        }
    }

    try {
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            Exists      = $true
            ParseError  = $_.Exception.Message
            LastWriteAt = $lastWriteAt
            Items       = @()
        }
    }

    $items = if ($null -eq $parsed) {
        @()
    }
    elseif ($parsed -is [System.Array]) {
        $parsed
    }
    else {
        ,$parsed
    }

    return [pscustomobject]@{
        Exists      = $true
        ParseError  = ''
        LastWriteAt = $lastWriteAt
        Items       = @($items)
    }
}

function Read-BindingDocument {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists      = $false
            ParseError  = ''
            LastWriteAt = ''
            Data        = $null
        }
    }

    $lastWriteAt = (Get-Item -LiteralPath $Path).LastWriteTime.ToString('o')
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            Exists      = $true
            ParseError  = ''
            LastWriteAt = $lastWriteAt
            Data        = $null
        }
    }

    try {
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            Exists      = $true
            ParseError  = $_.Exception.Message
            LastWriteAt = $lastWriteAt
            Data        = $null
        }
    }

    return [pscustomobject]@{
        Exists      = $true
        ParseError  = ''
        LastWriteAt = $lastWriteAt
        Data        = $parsed
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

$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairTestConfig = if ($config -is [hashtable] -and $config.ContainsKey('PairTest')) { $config.PairTest } else { $null }
$allowedInjectionMethods = @('hwnd')
if ($pairTestConfig -is [hashtable] -and $pairTestConfig.ContainsKey('AllowedWindowVisibilityMethods')) {
    $configuredMethods = @(Get-StringList -Value $pairTestConfig.AllowedWindowVisibilityMethods)
    if ($configuredMethods.Count -gt 0) {
        $allowedInjectionMethods = @($configuredMethods | Sort-Object -Unique)
    }
}
$runtimeDoc = Read-RuntimeItems -Path ([string]$config.RuntimeMapPath)
$bindingProfileDoc = Read-BindingDocument -Path ([string]$config.BindingProfilePath)
$bindingScope = Get-BindingSessionScope -Config $config -BindingDocument $bindingProfileDoc
$visibleWindows = @(Get-VisibleWindows)
$bindingLastWriteAt = [string]$bindingProfileDoc.LastWriteAt
$runtimeLastWriteAt = [string]$runtimeDoc.LastWriteAt
$bindingTimestamp = Convert-ToUtcDateTime -Value $bindingLastWriteAt
$runtimeTimestamp = Convert-ToUtcDateTime -Value $runtimeLastWriteAt
$runtimeStaleAgainstBinding = (
    $null -ne $bindingTimestamp -and
    $null -ne $runtimeTimestamp -and
    $runtimeTimestamp -lt $bindingTimestamp
)
$runtimeById = @{}
$duplicateIds = New-Object System.Collections.Generic.List[string]

foreach ($item in $runtimeDoc.Items) {
    $targetId = [string](Get-ObjectPropertyValue -Object $item -Name 'TargetId' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetId)) {
        continue
    }

    if ($runtimeById.ContainsKey($targetId)) {
        $duplicateIds.Add($targetId)
        continue
    }

    $runtimeById[$targetId] = $item
}

$rows = @()
$injectableCount = 0
$missingRuntimeCount = 0

foreach ($target in @($config.Targets | Where-Object { [string]$_.Id -in $bindingScope.ExpectedTargetIds } | Sort-Object Id)) {
    $targetId = [string]$target.Id
    $runtime = if ($runtimeById.ContainsKey($targetId)) { $runtimeById[$targetId] } else { $null }

    $runtimeTitle = [string](Get-ObjectPropertyValue -Object $runtime -Name 'Title' -DefaultValue [string]$target.WindowTitle)
    $runtimeHwnd = [string](Get-ObjectPropertyValue -Object $runtime -Name 'Hwnd' -DefaultValue '')
    $runtimeWindowPid = [int](Get-ObjectPropertyValue -Object $runtime -Name 'WindowPid' -DefaultValue 0)
    $runtimeShellPid = [int](Get-ObjectPropertyValue -Object $runtime -Name 'ShellPid' -DefaultValue 0)
    $resolvedBy = [string](Get-ObjectPropertyValue -Object $runtime -Name 'ResolvedBy' -DefaultValue '')
    $hostKind = [string](Get-ObjectPropertyValue -Object $runtime -Name 'HostKind' -DefaultValue '')
    $registrationMode = [string](Get-ObjectPropertyValue -Object $runtime -Name 'RegistrationMode' -DefaultValue '')

    if ($null -eq $runtime) {
        $missingRuntimeCount++
        $rows += [pscustomobject]@{
            TargetId                = $targetId
            RuntimePresent          = $false
            ResolvedBy              = ''
            HostKind                = ''
            RegistrationMode        = ''
            RuntimeTitle            = [string]$target.WindowTitle
            RuntimeHwnd             = ''
            RuntimeWindowPid        = ''
            RuntimeShellPid         = ''
            ShellProcessName        = ''
            WindowProcessName       = ''
            ShellMainWindowHandle   = ''
            WindowMainWindowHandle  = ''
            ByHwndCount             = 0
            ByWindowPidCount        = 0
            ByShellPidCount         = 0
            ByTitleCount            = 0
            Injectable              = $false
            InjectionMethod         = ''
            InjectionReason         = 'missing-runtime'
            MatchTitle              = ''
            MatchHwnd               = ''
            MatchWindowPid          = ''
            MatchClassName          = ''
        }
        continue
    }

    $byHwnd = @()
    if (Test-NonEmptyString $runtimeHwnd) {
        $byHwnd = @($visibleWindows | Where-Object { [string]$_.Hwnd -eq $runtimeHwnd })
    }

    $byWindowPid = @()
    if ($runtimeWindowPid -gt 0) {
        $byWindowPid = @($visibleWindows | Where-Object { $_.ProcessId -eq $runtimeWindowPid })
    }

    $byShellPid = @()
    if ($runtimeShellPid -gt 0) {
        $byShellPid = @($visibleWindows | Where-Object { $_.ProcessId -eq $runtimeShellPid })
    }

    $byTitle = @()
    if (Test-NonEmptyString $runtimeTitle) {
        $byTitle = @($visibleWindows | Where-Object { $_.Title -eq $runtimeTitle })
    }

    $resolution = Select-FirstVisibleLocator -ByHwnd $byHwnd -ByWindowPid $byWindowPid -ByShellPid $byShellPid -ByTitle $byTitle
    $injectable = [bool]$resolution.Injectable
    $injectionMethod = [string]$resolution.Method
    $injectionReason = [string]$resolution.Reason
    if ($runtimeStaleAgainstBinding) {
        $injectable = $false
        $injectionReason = 'runtime-stale-against-binding'
    }
    elseif (-not $injectable -and $injectionReason -eq 'duplicate-visible-title' -and ('hwnd' -in $allowedInjectionMethods)) {
        $injectionReason = 'hwnd-required-title-duplicate'
    }
    elseif ($injectable -and $injectionMethod -notin $allowedInjectionMethods) {
        switch ($injectionMethod) {
            'title' { $injectionReason = 'hwnd-required-title-only' }
            'windowPid' { $injectionReason = 'hwnd-required-windowpid-only' }
            'shellPid' { $injectionReason = 'hwnd-required-shellpid-only' }
            default { $injectionReason = 'injection-method-not-allowed' }
        }
        $injectable = $false
    }

    if ($injectable) {
        $injectableCount++
    }

    $shellInfo = Get-ProcessHandleInfo -ProcessId $runtimeShellPid
    $windowInfo = Get-ProcessHandleInfo -ProcessId $runtimeWindowPid
    $match = $resolution.Match

    $rows += [pscustomobject]@{
        TargetId                = $targetId
        RuntimePresent          = $true
        ResolvedBy              = $resolvedBy
        HostKind                = $hostKind
        RegistrationMode        = $registrationMode
        RuntimeTitle            = $runtimeTitle
        RuntimeHwnd             = $runtimeHwnd
        RuntimeWindowPid        = if ($runtimeWindowPid -gt 0) { [string]$runtimeWindowPid } else { '' }
        RuntimeShellPid         = if ($runtimeShellPid -gt 0) { [string]$runtimeShellPid } else { '' }
        ShellProcessName        = $shellInfo.ProcessName
        WindowProcessName       = $windowInfo.ProcessName
        ShellMainWindowHandle   = if ($shellInfo.MainWindowHandle -gt 0) { [string]$shellInfo.MainWindowHandle } else { '' }
        WindowMainWindowHandle  = if ($windowInfo.MainWindowHandle -gt 0) { [string]$windowInfo.MainWindowHandle } else { '' }
        ByHwndCount             = @($byHwnd).Count
        ByWindowPidCount        = @($byWindowPid).Count
        ByShellPidCount         = @($byShellPid).Count
        ByTitleCount            = @($byTitle).Count
        Injectable              = [bool]$injectable
        InjectionMethod         = $injectionMethod
        InjectionReason         = $injectionReason
        MatchTitle              = if ($null -ne $match) { [string]$match.Title } else { '' }
        MatchHwnd               = if ($null -ne $match) { [string]$match.Hwnd } else { '' }
        MatchWindowPid          = if ($null -ne $match) { [string]$match.ProcessId } else { '' }
        MatchClassName          = if ($null -ne $match) { [string]$match.ClassName } else { '' }
    }
}

$status = [pscustomobject]@{
    Root                = [string]$config.Root
    ConfigPath          = $resolvedConfigPath
    RuntimeMapPath      = [string]$config.RuntimeMapPath
    RuntimeExists       = [bool]$runtimeDoc.Exists
    RuntimeParseError   = [string]$runtimeDoc.ParseError
    RuntimeLastWriteAt  = [string]$runtimeDoc.LastWriteAt
    BindingProfileExists = [bool]$bindingProfileDoc.Exists
    BindingProfileLastWriteAt = $bindingLastWriteAt
    RuntimeStaleAgainstBinding = [bool]$runtimeStaleAgainstBinding
    VisibleWindowCount  = @($visibleWindows).Count
    ReuseMode           = [string]$bindingScope.ReuseMode
    PartialReuse        = [bool]$bindingScope.PartialReuse
    ConfiguredTargetCount = [int]$bindingScope.ConfiguredTargetCount
    ExpectedTargetCount = [int]$bindingScope.ExpectedTargetCount
    ActivePairIds       = @($bindingScope.ActivePairIds)
    IncompletePairIds   = @($bindingScope.IncompletePairIds)
    ActiveTargetIds     = @($bindingScope.ExpectedTargetIds)
    InactiveTargetIds   = @($bindingScope.InactiveTargetIds)
    OutOfScopeBindingTargetIds = @($bindingScope.OutOfScopeBindingTargetIds)
    OrphanMatchedTargetIds = @($bindingScope.OrphanMatchedTargetIds)
    SoftFindings        = @($bindingScope.SoftFindings)
    RuntimeEntryCount   = @($runtimeDoc.Items).Count
    DuplicateTargetIds  = @($duplicateIds | Sort-Object -Unique)
    AllowedInjectionMethods = @($allowedInjectionMethods)
    WindowPidOnlyFallbackDetected = (@($rows | Where-Object { [string]$_.InjectionMethod -eq 'windowPid' }).Count -gt 0)
    TitleFallbackRejectedCount = @($rows | Where-Object { [string]$_.InjectionReason -eq 'hwnd-required-title-duplicate' }).Count
    InjectableCount     = $injectableCount
    NonInjectableCount  = @($rows | Where-Object { -not $_.Injectable }).Count
    MissingRuntimeCount = $missingRuntimeCount
    Targets             = @($rows | Sort-Object TargetId)
}

if ($AsJson) {
    $status | ConvertTo-Json -Depth 8
}
else {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Target Window Visibility')
    $lines.Add(('Root: {0}' -f $status.Root))
    $lines.Add(('Config: {0}' -f $status.ConfigPath))
    $lines.Add(('Runtime: exists={0} entries={1}/{2} visibleWindows={3} configured={4}' -f $status.RuntimeExists, $status.RuntimeEntryCount, $status.ExpectedTargetCount, $status.VisibleWindowCount, $status.ConfiguredTargetCount))
    if (Test-NonEmptyString $status.BindingProfileLastWriteAt) {
        $lines.Add(('Binding Profile LastWriteAt: {0}' -f $status.BindingProfileLastWriteAt))
    }
    if (Test-NonEmptyString $status.RuntimeLastWriteAt) {
        $lines.Add(('Runtime LastWriteAt: {0}' -f $status.RuntimeLastWriteAt))
    }
    if ($status.RuntimeStaleAgainstBinding) {
        $lines.Add('RuntimeStaleAgainstBinding: true')
    }
    if ($status.PartialReuse) {
        $lines.Add(('Scope: partial / activePairs={0} / inactiveTargets={1}' -f ($(if ($status.ActivePairIds.Count -gt 0) { $status.ActivePairIds -join ', ' } else { '(none)' })), ($(if ($status.InactiveTargetIds.Count -gt 0) { $status.InactiveTargetIds -join ', ' } else { '(none)' }))))
    }
    if (Test-NonEmptyString $status.RuntimeParseError) {
        $lines.Add(('Runtime ParseError: {0}' -f $status.RuntimeParseError))
    }
    if ($status.DuplicateTargetIds.Count -gt 0) {
        $lines.Add(('Runtime Duplicates: {0}' -f ($status.DuplicateTargetIds -join ', ')))
    }
    $lines.Add(('Injectable: ok={0} fail={1} missingRuntime={2}' -f $status.InjectableCount, $status.NonInjectableCount, $status.MissingRuntimeCount))
    $lines.Add(('AllowedInjectionMethods: {0}' -f ($status.AllowedInjectionMethods -join ', ')))
    $lines.Add(('WindowPidOnlyFallbackDetected: {0}' -f [bool]$status.WindowPidOnlyFallbackDetected))
    if ($status.TitleFallbackRejectedCount -gt 0) {
        $lines.Add(('TitleFallbackRejectedCount: {0}' -f $status.TitleFallbackRejectedCount))
    }
    $lines.Add('')
    $lines.Add('Targets')
    $table = ($status.Targets | Select-Object TargetId, Injectable, InjectionMethod, InjectionReason, RuntimeTitle, RuntimeWindowPid, RuntimeShellPid, ByWindowPidCount, ByShellPidCount, ByTitleCount, MatchTitle | Format-Table -AutoSize | Out-String).TrimEnd()
    $lines.Add($table)
    $lines
}

$methodViolations = @($status.Targets | Where-Object { [bool]$_.Injectable -and [string]$_.InjectionMethod -notin $allowedInjectionMethods })
$hasBlockingIssues = ($status.NonInjectableCount -gt 0 -or $status.MissingRuntimeCount -gt 0 -or $status.DuplicateTargetIds.Count -gt 0 -or (Test-NonEmptyString $status.RuntimeParseError) -or $methodViolations.Count -gt 0)
if ($hasBlockingIssues) {
    $host.SetShouldExit(1)
    return
}

$host.SetShouldExit(0)
return
