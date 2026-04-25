[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$BindingsPath,
    [switch]$DiagnosticOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

. (Join-Path $PSScriptRoot '..\router\RuntimeMap.ps1')
. (Join-Path $PSScriptRoot '..\router\BindingSessionScope.ps1')
. (Join-Path $PSScriptRoot 'WindowDiscovery.ps1')

function Get-JsonValue {
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
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
}

function Get-StringList {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $single = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($single)) {
        return @($single)
    }

    return @()
}

function Read-BindingDocument {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Binding file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Binding file is empty: $Path"
    }

    $parsed = $raw | ConvertFrom-Json
    $windows = Get-JsonValue -Object $parsed -Name 'windows' -DefaultValue $null
    if ($null -eq $windows) {
        if ($parsed -is [System.Array]) {
            $windows = $parsed
        }
        elseif ($null -ne $parsed) {
            $windows = ,$parsed
        }
        else {
            $windows = @()
        }
    }

    if (-not ($windows -is [System.Array])) {
        $windows = ,$windows
    }

    return [pscustomobject]@{
        Data    = $parsed
        Windows = @($windows)
    }
}

function Get-ProcessStartTimeUtcString {
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
    }
    catch {
        return ''
    }
}

function Get-ProcessNameSafe {
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName
    }
    catch {
        return ''
    }
}

function Get-HostKind {
    param(
        [string]$ProcessName,
        [string]$WindowClass
    )

    if ($WindowClass -eq 'ConsoleWindowClass' -and $ProcessName -eq 'pwsh') {
        return 'pwsh-console'
    }

    if ($WindowClass -eq 'ConsoleWindowClass' -and $ProcessName -eq 'powershell') {
        return 'powershell-console'
    }

    if ($WindowClass -like '*CASCADIA*' -or $WindowClass -like '*Terminal*') {
        return 'terminal-hosted'
    }

    if ($ProcessName -eq 'pwsh') {
        return 'pwsh-other'
    }

    if ($ProcessName -eq 'powershell') {
        return 'powershell-other'
    }

    return 'unknown'
}

function Resolve-BindingWindow {
    param(
        [Parameter(Mandatory)]$VisibleWindows,
        [int]$WindowPid,
        [string]$Title,
        [string]$WindowClass
    )

    $matches = @()

    if ($WindowPid -gt 0) {
        $matches = @($VisibleWindows | Where-Object { $_.ProcessId -eq $WindowPid })
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $titleMatches = @($VisibleWindows | Where-Object { $_.Title -eq $Title })
        if ($titleMatches.Count -eq 1) {
            return $titleMatches[0]
        }

        if (-not [string]::IsNullOrWhiteSpace($WindowClass)) {
            $classMatches = @($titleMatches | Where-Object { $_.ClassName -eq $WindowClass })
            if ($classMatches.Count -eq 1) {
                return $classMatches[0]
            }
        }
    }

    return $null
}

$config = Import-PowerShellDataFile -Path $ConfigPath
if ([string]::IsNullOrWhiteSpace($BindingsPath)) {
    $BindingsPath = [string](Get-JsonValue -Object $config -Name 'BindingProfilePath' -DefaultValue '')
}

if ([string]::IsNullOrWhiteSpace($BindingsPath)) {
    throw 'BindingsPath is required. Pass -BindingsPath or set BindingProfilePath in the config.'
}

$bindingDoc = Read-BindingDocument -Path $BindingsPath
$sessionScope = Get-BindingSessionScope -BindingDocument $bindingDoc -Config $config
$bindingTargets = @($sessionScope.ScopedBindingWindows)
$bindingByTargetId = @{}
$runtimeEntries = @()
$failures = @()
$visibleWindows = Get-VisibleWindows
$launcherSessionId = [guid]::NewGuid().ToString('N')
$attachedAt = (Get-Date).ToString('o')
$launcherPid = $PID

foreach ($path in @($config.RuntimeRoot, $config.LogsRoot)) {
    Ensure-Directory -Path ([string]$path)
}

foreach ($binding in $bindingTargets) {
    $targetId = [string](Get-JsonValue -Object $binding -Name 'target_id' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($targetId)) {
        $targetId = [string](Get-JsonValue -Object $binding -Name 'TargetId' -DefaultValue '')
    }

    if ([string]::IsNullOrWhiteSpace($targetId)) {
        throw 'Binding file contains an entry without target_id.'
    }

    if ($bindingByTargetId.ContainsKey($targetId)) {
        throw "Binding file contains duplicate target_id: $targetId"
    }

    $bindingByTargetId[$targetId] = $binding
}

foreach ($target in ($config.Targets | Where-Object { [string]$_.Id -in $sessionScope.ActiveTargetIds } | Sort-Object Id)) {
    $targetId = [string]$target.Id
    if (-not $bindingByTargetId.ContainsKey($targetId)) {
        $failures += ("missing-binding:{0}" -f $targetId)
        continue
    }

    $binding = $bindingByTargetId[$targetId]
    $shellPid = [int](Get-JsonValue -Object $binding -Name 'shell_pid' -DefaultValue 0)
    if ($shellPid -le 0) {
        $shellPid = [int](Get-JsonValue -Object $binding -Name 'ShellPid' -DefaultValue 0)
    }

    $windowPid = [int](Get-JsonValue -Object $binding -Name 'window_pid' -DefaultValue 0)
    if ($windowPid -le 0) {
        $windowPid = [int](Get-JsonValue -Object $binding -Name 'WindowPid' -DefaultValue $shellPid)
    }

    $hwnd = [string](Get-JsonValue -Object $binding -Name 'hwnd' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($hwnd)) {
        $hwnd = [string](Get-JsonValue -Object $binding -Name 'Hwnd' -DefaultValue '')
    }

    $title = [string](Get-JsonValue -Object $binding -Name 'window_title' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = [string](Get-JsonValue -Object $binding -Name 'WindowTitle' -DefaultValue '')
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = [string](Get-JsonValue -Object $binding -Name 'base_title' -DefaultValue [string]$target.WindowTitle)
    }

    $windowClass = [string](Get-JsonValue -Object $binding -Name 'window_class' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($windowClass)) {
        $windowClass = [string](Get-JsonValue -Object $binding -Name 'WindowClass' -DefaultValue '')
    }

    $resolvedWindow = Resolve-BindingWindow -VisibleWindows $visibleWindows -WindowPid $windowPid -Title $title -WindowClass $windowClass
    if ($null -ne $resolvedWindow) {
        if ([string]::IsNullOrWhiteSpace($hwnd)) {
            $hwnd = [string]$resolvedWindow.Hwnd
        }

        if ($windowPid -le 0) {
            $windowPid = [int]$resolvedWindow.ProcessId
        }

        if ([string]::IsNullOrWhiteSpace($windowClass)) {
            $windowClass = [string]$resolvedWindow.ClassName
        }

        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = [string]$resolvedWindow.Title
        }
    }

    if ($shellPid -le 0) {
        $failures += ("invalid-shell-pid:{0}" -f $targetId)
        continue
    }

    try {
        Get-Process -Id $shellPid -ErrorAction Stop | Out-Null
    }
    catch {
        $failures += ("shell-missing:{0}:{1}" -f $targetId, $shellPid)
        continue
    }

    $shellProcessName = Get-ProcessNameSafe -ProcessId $shellPid
    $hostKind = Get-HostKind -ProcessName $shellProcessName -WindowClass $windowClass
    $windowObject = [pscustomobject]@{
        ProcessId = $windowPid
        Hwnd      = $hwnd
        ClassName = $windowClass
    }

    $runtimeEntries += New-RuntimeMapEntry `
        -TargetId $targetId `
        -ShellPid $shellPid `
        -Title $title `
        -ShellPath ([string]$config.ShellPath) `
        -Window $windowObject `
        -ResolvedBy 'binding-file' `
        -LookupSucceededAt ((Get-Date).ToString('o')) `
        -LauncherSessionId $launcherSessionId `
        -LaunchedAt $attachedAt `
        -LauncherPid $launcherPid `
        -ProcessName $shellProcessName `
        -WindowClass $windowClass `
        -HostKind $hostKind `
        -RegistrationMode 'attached' `
        -ShellStartTimeUtc (Get-ProcessStartTimeUtcString -ProcessId $shellPid) `
        -ManagedMarker ''

    if ($DiagnosticOnly) {
        Write-Host ("diagnostic binding target={0} shellPid={1} windowPid={2} hwnd={3} hostKind={4} title={5}" -f `
            $targetId,
            $shellPid,
            $windowPid,
            $hwnd,
            $hostKind,
            $title)
    }
    else {
        Write-Host ("attached from binding: target={0} shellPid={1} windowPid={2} hwnd={3} hostKind={4}" -f `
            $targetId,
            $shellPid,
            $windowPid,
            $hwnd,
            $hostKind)
    }
}

$extraBindingTargetIds = @($sessionScope.OutOfScopeBindingTargetIds)
foreach ($extraTargetId in $extraBindingTargetIds) {
    $failures += ("extra-binding:{0}" -f $extraTargetId)
}

if ($DiagnosticOnly) {
    Write-Host ("binding diagnostic summary matched={0} failures={1} runtimeWrite=skipped" -f $runtimeEntries.Count, $failures.Count)
}
else {
    Write-RuntimeMap -Path ([string]$config.RuntimeMapPath) -Items $runtimeEntries
}

if ($failures.Count -gt 0) {
    if ($DiagnosticOnly) {
        throw ("Attach-TargetsFromBindings diagnostic found issues: " + ($failures -join ', '))
    }

    throw ("Attach-TargetsFromBindings failed: " + ($failures -join ', '))
}
