[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$WorkRepoRoot,
    [string]$BindingsPath,
    [string]$LaunchCommand,
    [string]$AutoloopStatusPath,
    [switch]$Apply,
    [switch]$AsJson,
    [switch]$SkipAutoloopSafetyCheck,
    [int]$CloseTimeoutSeconds = 12,
    [int]$LaunchTimeoutSeconds = 25,
    [int]$AutoloopStatusFreshSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'router\RuntimeMap.ps1')
. (Join-Path $PSScriptRoot 'WindowDiscovery.ps1')

function Test-NonEmptyString {
    param([object]$Value)
    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-ObjectValue {
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

function Get-StringArrayValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return @(
            $Value |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @($text)
}

function Copy-ObjectToOrderedMap {
    param($Object)

    $map = [ordered]@{}
    if ($null -eq $Object) {
        return $map
    }
    if ($Object -is [hashtable]) {
        foreach ($key in $Object.Keys) {
            $map[$key] = $Object[$key]
        }
        return $map
    }
    foreach ($property in $Object.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }
    return $map
}

function ConvertTo-HwndInt64 {
    param($Value)

    if ($null -eq $Value) {
        return 0L
    }
    try {
        return [int64]$Value
    }
    catch {
        return 0L
    }
}

function ConvertTo-PowerShellLiteral {
    param([AllowNull()][string]$Value)

    return "'" + ([string]($Value ?? '')).Replace("'", "''") + "'"
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootPath
    )

    try {
        $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
    }
    catch {
        return $false
    }
    return (
        $resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $resolvedPath.StartsWith($resolvedRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Ensure-BoundVisibleTargetWindowApi {
    if ('Relay.BoundVisibleTargetWindowApi' -as [type]) {
        return
    }

    Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace Relay {
    public static class BoundVisibleTargetWindowApi {
        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool PostMessageW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }
}
'@
}

function Test-LiveHwnd {
    param([int64]$Hwnd)

    if ($Hwnd -le 0) {
        return $false
    }
    Ensure-BoundVisibleTargetWindowApi
    $ptr = [IntPtr]::new($Hwnd)
    return ([Relay.BoundVisibleTargetWindowApi]::IsWindow($ptr) -and [Relay.BoundVisibleTargetWindowApi]::IsWindowVisible($ptr))
}

function Request-CloseHwnd {
    param([int64]$Hwnd)

    if ($Hwnd -le 0) {
        return $false
    }
    Ensure-BoundVisibleTargetWindowApi
    return [Relay.BoundVisibleTargetWindowApi]::PostMessageW([IntPtr]::new($Hwnd), [uint32]0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
}

function Move-VisibleWindow {
    param(
        [Parameter(Mandatory)][int64]$Hwnd,
        [Parameter(Mandatory)][int[]]$Rect
    )

    if ($Hwnd -le 0 -or @($Rect).Count -ne 4) {
        return $false
    }
    $left = [int]$Rect[0]
    $top = [int]$Rect[1]
    $width = [int]$Rect[2] - $left
    $height = [int]$Rect[3] - $top
    if ($width -le 0 -or $height -le 0) {
        return $false
    }
    Ensure-BoundVisibleTargetWindowApi
    $ptr = [IntPtr]::new($Hwnd)
    [Relay.BoundVisibleTargetWindowApi]::ShowWindow($ptr, 9) | Out-Null
    [Relay.BoundVisibleTargetWindowApi]::ShowWindow($ptr, 5) | Out-Null
    return [Relay.BoundVisibleTargetWindowApi]::MoveWindow($ptr, $left, $top, $width, $height, $true)
}

function Wait-HwndClosed {
    param(
        [int64]$Hwnd,
        [int]$TimeoutSeconds
    )

    if ($Hwnd -le 0) {
        return $true
    }
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-LiveHwnd -Hwnd $Hwnd)) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return (-not (Test-LiveHwnd -Hwnd $Hwnd))
}

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'pwsh')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }
        if (Test-NonEmptyString $command.Source) {
            return [string]$command.Source
        }
        if (Test-NonEmptyString $command.Path) {
            return [string]$command.Path
        }
        return [string]$name
    }
    throw 'pwsh (PowerShell 7+) executable not found.'
}

function Read-BindingDocument {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Binding file not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Binding file is empty: $Path"
    }
    try {
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        throw "Binding file parse error: $($_.Exception.Message)"
    }

    $windows = Get-ObjectValue -Object $parsed -Name 'windows' -DefaultValue $null
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

function Get-BindingTargetWindow {
    param(
        [Parameter(Mandatory)][object[]]$Windows,
        [Parameter(Mandatory)][string]$TargetId
    )

    $matches = @($Windows | Where-Object {
        [string](Get-ObjectValue -Object $_ -Name 'target_id' -DefaultValue (Get-ObjectValue -Object $_ -Name 'TargetId' -DefaultValue '')) -eq $TargetId
    })
    if ($matches.Count -eq 0) {
        throw "Binding profile does not contain target_id: $TargetId"
    }
    if ($matches.Count -gt 1) {
        throw "Binding profile contains duplicate target_id: $TargetId"
    }
    return $matches[0]
}

function Normalize-TargetDirForCompare {
    param([AllowNull()][string]$Value)

    $text = [string]($Value ?? '')
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }
    try {
        return [System.IO.Path]::GetFullPath($text).TrimEnd('\', '/')
    }
    catch {
        return $text.TrimEnd('\', '/')
    }
}

function Get-BindingTargetDirMap {
    param(
        [Parameter(Mandatory)][object[]]$Windows,
        [AllowNull()][string]$DefaultTargetDir = '',
        [AllowNull()][string]$ReplaceTargetId = '',
        [AllowNull()][string]$ReplaceTargetDir = ''
    )

    $map = [ordered]@{}
    foreach ($window in @($Windows)) {
        $windowTargetId = [string](Get-ObjectValue -Object $window -Name 'target_id' -DefaultValue (Get-ObjectValue -Object $window -Name 'TargetId' -DefaultValue ''))
        if (-not (Test-NonEmptyString $windowTargetId)) {
            continue
        }
        if ((Test-NonEmptyString $ReplaceTargetId) -and $windowTargetId -eq $ReplaceTargetId) {
            $windowTargetDir = [string]($ReplaceTargetDir ?? '')
        }
        else {
            $windowTargetDir = [string](Get-ObjectValue -Object $window -Name 'target_dir' -DefaultValue $DefaultTargetDir)
        }
        if (Test-NonEmptyString $windowTargetDir) {
            $map[$windowTargetId] = $windowTargetDir
        }
    }
    return $map
}

function Get-TargetDirSet {
    param([Parameter(Mandatory)]$TargetDirs)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($TargetDirs.Values)) {
        $normalized = Normalize-TargetDirForCompare -Value ([string]($value ?? ''))
        if (Test-NonEmptyString $normalized) {
            $set.Add($normalized) | Out-Null
        }
    }
    return ,$set
}

function Get-ConfigTarget {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetId
    )

    return @($Config.Targets | Where-Object { [string]$_.Id -eq $TargetId } | Select-Object -First 1)[0]
}

function Get-TargetOrdinal {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetId
    )

    $index = 1
    foreach ($target in @($Config.Targets | Sort-Object Id)) {
        if ([string]$target.Id -eq $TargetId) {
            return $index
        }
        $index++
    }
    return 0
}

function Build-BaseTitle {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][string]$TargetId
    )

    $baseTitle = [string](Get-ObjectValue -Object $Binding -Name 'base_title' -DefaultValue '')
    if (Test-NonEmptyString $baseTitle) {
        return $baseTitle
    }
    $target = Get-ConfigTarget -Config $Config -TargetId $TargetId
    $configuredTitle = if ($null -ne $target) { [string]$target.WindowTitle } else { '' }
    $pairId = [string](Get-ObjectValue -Object $Binding -Name 'pair_id' -DefaultValue '')
    $roleName = [string](Get-ObjectValue -Object $Binding -Name 'role_name' -DefaultValue '')
    if (Test-NonEmptyString $configuredTitle -and (Test-NonEmptyString $pairId) -and (Test-NonEmptyString $roleName)) {
        return ('{0} | {1} | {2}-{3}' -f $configuredTitle, $TargetId, $pairId, $roleName)
    }
    if (Test-NonEmptyString $configuredTitle) {
        return $configuredTitle
    }
    $prefix = [string](Get-ObjectValue -Object $Config -Name 'WindowTitlePrefix' -DefaultValue 'BotTestLive-Window')
    $ordinal = Get-TargetOrdinal -Config $Config -TargetId $TargetId
    if ($ordinal -gt 0) {
        return ('{0}-{1:00} | {2}' -f $prefix, $ordinal, $TargetId)
    }
    return $TargetId
}

function Build-LaunchScript {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$BaseTitle,
        [Parameter(Mandatory)][string]$RootPath,
        [AllowEmptyString()][string]$LaunchCommand
    )

    $targetLiteral = ConvertTo-PowerShellLiteral $TargetId
    $pairLiteral = ConvertTo-PowerShellLiteral $PairId
    $roleLiteral = ConvertTo-PowerShellLiteral $RoleName
    $pairRoleLiteral = ConvertTo-PowerShellLiteral ('{0}-{1}' -f $PairId, $RoleName)
    $baseLiteral = ConvertTo-PowerShellLiteral $BaseTitle
    $rootLiteral = ConvertTo-PowerShellLiteral $RootPath
    $launchLiteral = ConvertTo-PowerShellLiteral $LaunchCommand

    return @"
`$script:RelayTargetId = $targetLiteral
`$script:RelayPairId = $pairLiteral
`$script:RelayRoleName = $roleLiteral
`$script:RelayPairRole = $pairRoleLiteral
`$script:RelayBaseTitle = $baseLiteral
`$script:RelayRootPath = $rootLiteral
`$script:RelayLaunchCommand = $launchLiteral
Set-Location -LiteralPath `$script:RelayRootPath
`$activatePath = Join-Path `$script:RelayRootPath 'venv\Scripts\Activate.ps1'
if (Test-Path -LiteralPath `$activatePath -PathType Leaf) {
    & `$activatePath
}
`$Host.UI.RawUI.WindowTitle = (`$script:RelayBaseTitle + ' | PID ' + `$PID)
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host (' TARGET : ' + `$script:RelayTargetId) -ForegroundColor Cyan
Write-Host (' PAIR   : ' + `$script:RelayPairRole) -ForegroundColor Yellow
Write-Host (' PID    : ' + `$PID) -ForegroundColor Green
Write-Host (' ROOT   : ' + `$script:RelayRootPath) -ForegroundColor DarkCyan
if (-not [string]::IsNullOrWhiteSpace(`$script:RelayLaunchCommand)) {
    Write-Host (' LAUNCH : ' + `$script:RelayLaunchCommand) -ForegroundColor Magenta
}
Write-Host ('=' * 60) -ForegroundColor DarkGray
function global:prompt {
    `$Host.UI.RawUI.WindowTitle = (`$script:RelayBaseTitle + ' | PID ' + `$PID)
    return ('[' + `$script:RelayTargetId + '|' + `$script:RelayPairRole + '|PID:' + `$PID + '] PS ' + `$executionContext.SessionState.Path.CurrentLocation + '> ')
}
if (-not [string]::IsNullOrWhiteSpace(`$script:RelayLaunchCommand)) {
    Invoke-Expression `$script:RelayLaunchCommand
}
"@
}

function Find-NewVisibleWindow {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$KnownHwnds,
        [Parameter(Mandatory)][string]$BaseTitle,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        foreach ($window in @(Get-VisibleWindows -IncludeRect)) {
            $hwndText = [string]$window.Hwnd
            if ($KnownHwnds.Contains($hwndText)) {
                continue
            }
            $title = [string]$window.Title
            if ($title.StartsWith($BaseTitle, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $window
            }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "New visible window not found for base title: $BaseTitle"
}

function Write-JsonDocumentUtf8 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Document
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $json = $Document | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Utf8NoBomEncoding))
}

function Resolve-AutoloopStatusPath {
    param(
        $Config,
        [AllowEmptyString()][string]$RequestedPath
    )

    if (Test-NonEmptyString $RequestedPath) {
        return [System.IO.Path]::GetFullPath($RequestedPath)
    }

    $targetAutoloop = Get-ObjectValue -Object $Config -Name 'TargetAutoloop' -DefaultValue $null
    $runRootBase = [string](Get-ObjectValue -Object $targetAutoloop -Name 'RunRootBase' -DefaultValue '')
    if (-not (Test-NonEmptyString $runRootBase)) {
        return ''
    }
    if (-not (Test-Path -LiteralPath $runRootBase -PathType Container)) {
        return ''
    }

    $latest = Get-ChildItem -LiteralPath $runRootBase -Recurse -Filter 'target-autoloop-status.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        return ''
    }
    return [string]$latest.FullName
}

function Get-AutoloopStatusTargetRow {
    param(
        $StatusDocument,
        [Parameter(Mandatory)][string]$TargetId
    )

    $targets = Get-ObjectValue -Object $StatusDocument -Name 'Targets' -DefaultValue $null
    if ($null -eq $targets) {
        return $null
    }
    if ($targets -is [System.Array]) {
        return @($targets | Where-Object {
            [string](Get-ObjectValue -Object $_ -Name 'TargetId' -DefaultValue '') -eq $TargetId
        } | Select-Object -First 1)[0]
    }
    $property = $targets.PSObject.Properties[$TargetId]
    if ($null -ne $property) {
        return $property.Value
    }
    return @($targets | Where-Object {
        [string](Get-ObjectValue -Object $_ -Name 'TargetId' -DefaultValue '') -eq $TargetId
    } | Select-Object -First 1)[0]
}

function Get-AutoloopRestartSafety {
    param(
        [AllowEmptyString()][string]$StatusPath,
        [Parameter(Mandatory)][string]$TargetId,
        [int]$FreshSeconds
    )

    $result = [ordered]@{
        Checked = $false
        Allowed = $true
        Reason = ''
        StatusPath = [string]($StatusPath ?? '')
        StatusFresh = $false
        StatusAgeSeconds = $null
        WatcherState = ''
        ControllerState = ''
        WatcherTargetIds = @()
        TargetPhase = ''
        TargetDispatchState = ''
    }

    if (-not (Test-NonEmptyString $StatusPath)) {
        $result['Reason'] = 'status-path-not-resolved'
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
        $result['Reason'] = 'status-path-not-found'
        return [pscustomobject]$result
    }

    $result['Checked'] = $true
    $statusFile = Get-Item -LiteralPath $StatusPath
    $ageSeconds = [Math]::Round(((Get-Date).ToUniversalTime() - $statusFile.LastWriteTimeUtc).TotalSeconds, 3)
    $result['StatusAgeSeconds'] = $ageSeconds
    $freshLimit = [Math]::Max(1, $FreshSeconds)
    $statusFresh = ($ageSeconds -le $freshLimit)
    $result['StatusFresh'] = [bool]$statusFresh
    if (-not $statusFresh) {
        $result['Reason'] = 'status-stale'
        return [pscustomobject]$result
    }

    try {
        $statusDocument = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $result['Allowed'] = $false
        $result['Reason'] = "status-parse-failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    $watcherState = [string](Get-ObjectValue -Object $statusDocument -Name 'WatcherState' -DefaultValue (
        Get-ObjectValue -Object $statusDocument -Name 'State' -DefaultValue ''
    ))
    $controllerState = [string](Get-ObjectValue -Object $statusDocument -Name 'ControllerState' -DefaultValue '')
    $watcherTargetIds = @(
        Get-StringArrayValue -Value (Get-ObjectValue -Object $statusDocument -Name 'WatcherTargetIds' -DefaultValue @())
    )
    $targetRow = Get-AutoloopStatusTargetRow -StatusDocument $statusDocument -TargetId $TargetId
    $phase = if ($null -ne $targetRow) { [string](Get-ObjectValue -Object $targetRow -Name 'Phase' -DefaultValue '') } else { '' }
    $dispatchState = if ($null -ne $targetRow) { [string](Get-ObjectValue -Object $targetRow -Name 'LastDispatchState' -DefaultValue '') } else { '' }

    $result['WatcherState'] = $watcherState
    $result['ControllerState'] = $controllerState
    $result['WatcherTargetIds'] = @($watcherTargetIds)
    $result['TargetPhase'] = $phase
    $result['TargetDispatchState'] = $dispatchState

    $normalizedPhase = $phase.Trim().ToLowerInvariant()
    $normalizedDispatchState = $dispatchState.Trim().ToLowerInvariant()
    $activePhases = @('input-detected', 'claimed', 'queued', 'waiting-output', 'dispatch-delay', 'cooldown', 'paused')
    $activeDispatchStates = @(
        'dispatch-delay-waiting',
        'router-ready-file-created',
        'queue-command-created',
        'queued',
        'sending',
        'running',
        'submit-started',
        'submit-complete',
        'send-complete',
        'processed-ready'
    )

    if ($activePhases -contains $normalizedPhase) {
        $result['Allowed'] = $false
        $result['Reason'] = "target-active-phase:$phase"
        return [pscustomobject]$result
    }
    if ($activeDispatchStates -contains $normalizedDispatchState) {
        $result['Allowed'] = $false
        $result['Reason'] = "target-active-dispatch:$dispatchState"
        return [pscustomobject]$result
    }

    if ($watcherState.Trim().ToLowerInvariant() -eq 'running') {
        if ($watcherTargetIds.Count -eq 0) {
            $result['Allowed'] = $false
            $result['Reason'] = 'fresh-running-watcher-scope-unknown'
            return [pscustomobject]$result
        }
        if ($watcherTargetIds -contains $TargetId) {
            $result['Allowed'] = $false
            $result['Reason'] = "fresh-running-watcher-includes-target:$TargetId"
            return [pscustomobject]$result
        }
    }

    $result['Reason'] = 'safe'
    return [pscustomobject]$result
}

$resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
    throw "ConfigPath not found: $resolvedConfigPath"
}

$config = Import-PowerShellDataFile -LiteralPath $resolvedConfigPath
$laneName = [string](Get-ObjectValue -Object $config -Name 'LaneName' -DefaultValue '')
if ($laneName -ne 'bottest-live-visible') {
    throw "Restart-BoundVisibleTarget is only allowed for bottest-live-visible. Config LaneName=$laneName"
}

$normalizedTargetId = [string]$TargetId
if (-not (Test-NonEmptyString $normalizedTargetId)) {
    throw 'TargetId is required.'
}

$resolvedWorkRepoRoot = [System.IO.Path]::GetFullPath($WorkRepoRoot)
if (-not (Test-Path -LiteralPath $resolvedWorkRepoRoot -PathType Container)) {
    throw "WorkRepoRoot not found: $resolvedWorkRepoRoot"
}
if (Test-PathWithinRoot -Path $resolvedWorkRepoRoot -RootPath $root) {
    throw "WorkRepoRoot must be outside automation repo. automationRoot=$root workRepoRoot=$resolvedWorkRepoRoot"
}

if (-not (Test-NonEmptyString $BindingsPath)) {
    $BindingsPath = [string](Get-ObjectValue -Object $config -Name 'BindingProfilePath' -DefaultValue '')
}
if (-not (Test-NonEmptyString $BindingsPath)) {
    throw 'BindingsPath is required. Pass -BindingsPath or set BindingProfilePath in config.'
}
$resolvedBindingsPath = [System.IO.Path]::GetFullPath($BindingsPath)
$bindingDoc = Read-BindingDocument -Path $resolvedBindingsPath
$bindingWindow = Get-BindingTargetWindow -Windows $bindingDoc.Windows -TargetId $normalizedTargetId
$configTarget = Get-ConfigTarget -Config $config -TargetId $normalizedTargetId
if ($null -eq $configTarget) {
    throw "Config Targets does not contain TargetId: $normalizedTargetId"
}

$pairId = [string](Get-ObjectValue -Object $bindingWindow -Name 'pair_id' -DefaultValue '')
$roleName = [string](Get-ObjectValue -Object $bindingWindow -Name 'role_name' -DefaultValue '')
$baseTitle = Build-BaseTitle -Config $config -Binding $bindingWindow -TargetId $normalizedTargetId
$oldHwnd = ConvertTo-HwndInt64 -Value (Get-ObjectValue -Object $bindingWindow -Name 'hwnd' -DefaultValue (Get-ObjectValue -Object $bindingWindow -Name 'Hwnd' -DefaultValue 0))
$oldShellPid = [int](Get-ObjectValue -Object $bindingWindow -Name 'shell_pid' -DefaultValue 0)
$defaultTargetDir = [string](Get-ObjectValue -Object $bindingDoc.Data -Name 'target_dir' -DefaultValue '')
$oldTargetDir = [string](Get-ObjectValue -Object $bindingWindow -Name 'target_dir' -DefaultValue $defaultTargetDir)
$rect = @(
    Get-ObjectValue -Object $bindingWindow -Name 'rect' -DefaultValue @()
) | ForEach-Object { [int]$_ }
if (@($rect).Count -ne 4) {
    throw "Binding target '$normalizedTargetId' does not have a valid rect."
}
if (-not (Test-NonEmptyString $LaunchCommand)) {
    $LaunchCommand = [string](Get-ObjectValue -Object $bindingDoc.Data -Name 'launch_command' -DefaultValue '')
}

$oldLive = Test-LiveHwnd -Hwnd $oldHwnd
$knownHwnds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($window in @(Get-VisibleWindows)) {
    $knownHwnds.Add([string]$window.Hwnd) | Out-Null
}

$resolvedAutoloopStatusPath = Resolve-AutoloopStatusPath -Config $config -RequestedPath $AutoloopStatusPath
$autoloopSafety = Get-AutoloopRestartSafety `
    -StatusPath $resolvedAutoloopStatusPath `
    -TargetId $normalizedTargetId `
    -FreshSeconds $AutoloopStatusFreshSeconds
$oldTargetDirNormalized = Normalize-TargetDirForCompare -Value $oldTargetDir
$newTargetDirNormalized = Normalize-TargetDirForCompare -Value $resolvedWorkRepoRoot
$targetDirChanging = -not $oldTargetDirNormalized.Equals($newTargetDirNormalized, [System.StringComparison]::OrdinalIgnoreCase)
$targetDirsBefore = Get-BindingTargetDirMap -Windows $bindingDoc.Windows -DefaultTargetDir $defaultTargetDir
$targetDirsAfter = Get-BindingTargetDirMap `
    -Windows $bindingDoc.Windows `
    -DefaultTargetDir $defaultTargetDir `
    -ReplaceTargetId $normalizedTargetId `
    -ReplaceTargetDir $resolvedWorkRepoRoot
$targetDirSetBefore = Get-TargetDirSet -TargetDirs $targetDirsBefore
$targetDirSetAfter = Get-TargetDirSet -TargetDirs $targetDirsAfter

$result = [ordered]@{
    Success = $true
    Apply = [bool]$Apply
    ConfigPath = $resolvedConfigPath
    BindingsPath = $resolvedBindingsPath
    TargetId = $normalizedTargetId
    PairId = $pairId
    RoleName = $roleName
    BaseTitle = $baseTitle
    OldHwnd = if ($oldHwnd -gt 0) { [string]$oldHwnd } else { '' }
    OldShellPid = if ($oldShellPid -gt 0) { [string]$oldShellPid } else { '' }
    OldTargetDir = $oldTargetDir
    OldTargetDirNormalized = $oldTargetDirNormalized
    NewTargetDir = $resolvedWorkRepoRoot
    NewTargetDirNormalized = $newTargetDirNormalized
    TargetDirChanging = [bool]$targetDirChanging
    TargetDirsBefore = [pscustomobject]$targetDirsBefore
    TargetDirsAfter = [pscustomobject]$targetDirsAfter
    MixedTargetDirsBefore = ($targetDirSetBefore.Count -gt 1)
    MixedTargetDirsAfter = ($targetDirSetAfter.Count -gt 1)
    LaunchCommand = [string]$LaunchCommand
    Rect = @($rect)
    OldLive = [bool]$oldLive
    CloseRequested = $false
    Closed = $false
    Launched = $false
    BindingUpdated = $false
    NewShellPid = ''
    NewWindowPid = ''
    NewHwnd = ''
    NewWindowTitle = ''
    NewWindowClass = ''
    Moved = $false
    UpdatedAt = ''
    RuntimeAttachRequiredAfterApply = [bool]$Apply
    FollowUpAttachCommand = ("launcher/Attach-TargetsFromBindings.ps1 -TargetId {0}" -f $normalizedTargetId)
    AutoloopSafetyChecked = [bool]$autoloopSafety.Checked
    AutoloopSafetyAllowed = [bool]$autoloopSafety.Allowed
    AutoloopSafetyReason = [string]$autoloopSafety.Reason
    AutoloopStatusPath = [string]$autoloopSafety.StatusPath
    AutoloopStatusFresh = [bool]$autoloopSafety.StatusFresh
    AutoloopStatusAgeSeconds = $autoloopSafety.StatusAgeSeconds
    AutoloopWatcherState = [string]$autoloopSafety.WatcherState
    AutoloopControllerState = [string]$autoloopSafety.ControllerState
    AutoloopWatcherTargetIds = @($autoloopSafety.WatcherTargetIds)
    AutoloopTargetPhase = [string]$autoloopSafety.TargetPhase
    AutoloopTargetDispatchState = [string]$autoloopSafety.TargetDispatchState
    AutoloopSafetySkipped = [bool]$SkipAutoloopSafetyCheck
    Note = 'Only the binding-managed HWND for the requested target is eligible for close/relaunch.'
}

if (-not $Apply) {
    $result['PlannedOnly'] = $true
    if ($AsJson) {
        [pscustomobject]$result | ConvertTo-Json -Depth 8
        return
    }
    [pscustomobject]$result
    return
}

if ((-not $SkipAutoloopSafetyCheck) -and (-not [bool]$autoloopSafety.Allowed)) {
    throw (
        "Autoloop safety check blocked target restart: target={0} reason={1} statusPath={2}. " +
        "Pause/stop the watcher or clear target pending state before using -Apply."
    ) -f $normalizedTargetId, ([string]$autoloopSafety.Reason), ([string]$autoloopSafety.StatusPath)
}

if ($oldLive) {
    $result['CloseRequested'] = [bool](Request-CloseHwnd -Hwnd $oldHwnd)
    if (-not [bool]$result['CloseRequested']) {
        throw "WM_CLOSE request failed for target=$normalizedTargetId hwnd=$oldHwnd"
    }
    $result['Closed'] = [bool](Wait-HwndClosed -Hwnd $oldHwnd -TimeoutSeconds $CloseTimeoutSeconds)
    if (-not [bool]$result['Closed']) {
        throw "Timed out waiting for target=$normalizedTargetId hwnd=$oldHwnd to close."
    }
}
else {
    $result['Closed'] = $true
}
if ($oldHwnd -gt 0) {
    $knownHwnds.Remove([string]$oldHwnd) | Out-Null
}

$powershellExe = Resolve-PowerShellExecutable
$launchScript = Build-LaunchScript `
    -TargetId $normalizedTargetId `
    -PairId $pairId `
    -RoleName $roleName `
    -BaseTitle $baseTitle `
    -RootPath $resolvedWorkRepoRoot `
    -LaunchCommand ([string]$LaunchCommand)

$process = Start-Process `
    -FilePath $powershellExe `
    -ArgumentList @('-NoProfile', '-NoExit', '-Command', $launchScript) `
    -WorkingDirectory $resolvedWorkRepoRoot `
    -PassThru

$newWindow = Find-NewVisibleWindow -KnownHwnds $knownHwnds -BaseTitle $baseTitle -TimeoutSeconds $LaunchTimeoutSeconds
$moved = Move-VisibleWindow -Hwnd ([int64]$newWindow.Hwnd) -Rect ([int[]]$rect)
Start-Sleep -Milliseconds 250
$movedWindow = @(
    Get-VisibleWindows -IncludeRect |
        Where-Object { [string]$_.Hwnd -eq [string]$newWindow.Hwnd } |
        Select-Object -First 1
)[0]
if ($null -eq $movedWindow) {
    $movedWindow = $newWindow
}

$updatedWindow = Copy-ObjectToOrderedMap -Object $bindingWindow
$updatedWindow['target_id'] = $normalizedTargetId
$updatedWindow['pair_id'] = $pairId
$updatedWindow['role_name'] = $roleName
$updatedWindow['base_title'] = $baseTitle
$updatedWindow['window_title'] = [string]$movedWindow.Title
$updatedWindow['shell_pid'] = [int]$process.Id
$updatedWindow['window_pid'] = [int]$movedWindow.ProcessId
$updatedWindow['hwnd'] = [string]$movedWindow.Hwnd
$updatedWindow['rect'] = @(
    [int]$rect[0],
    [int]$rect[1],
    [int]$rect[2],
    [int]$rect[3]
)
$updatedWindow['window_class'] = [string]$movedWindow.ClassName
$updatedWindow['target_dir'] = $resolvedWorkRepoRoot

$updatedWindows = @()
foreach ($window in @($bindingDoc.Windows)) {
    $windowTargetId = [string](Get-ObjectValue -Object $window -Name 'target_id' -DefaultValue (Get-ObjectValue -Object $window -Name 'TargetId' -DefaultValue ''))
    if ($windowTargetId -eq $normalizedTargetId) {
        $updatedWindows += [pscustomobject]$updatedWindow
    }
    else {
        $preservedWindow = Copy-ObjectToOrderedMap -Object $window
        $preservedTargetDir = [string](Get-ObjectValue -Object $preservedWindow -Name 'target_dir' -DefaultValue $defaultTargetDir)
        if (Test-NonEmptyString $preservedTargetDir) {
            $preservedWindow['target_dir'] = $preservedTargetDir
        }
        $updatedWindows += [pscustomobject]$preservedWindow
    }
}

$updatedAt = (Get-Date).ToString('o')
$writtenTargetDirs = Get-BindingTargetDirMap -Windows $updatedWindows -DefaultTargetDir $defaultTargetDir
$writtenTargetDirSet = Get-TargetDirSet -TargetDirs $writtenTargetDirs
$outputDocument = Copy-ObjectToOrderedMap -Object $bindingDoc.Data
$outputDocument['updated_at'] = $updatedAt
$outputDocument['target_dirs'] = [pscustomobject]$writtenTargetDirs
$outputDocument['mixed_target_dirs'] = ($writtenTargetDirSet.Count -gt 1)
if ($writtenTargetDirSet.Count -eq 1) {
    $singleTargetDir = @($writtenTargetDirs.Values | Select-Object -First 1)[0]
    $outputDocument['target_dir'] = [string]$singleTargetDir
}
else {
    $outputDocument['target_dir'] = ''
}
$outputDocument['last_restarted_target_id'] = $normalizedTargetId
$outputDocument['last_restarted_target_dir'] = $resolvedWorkRepoRoot
$outputDocument['windows'] = @($updatedWindows)
Write-JsonDocumentUtf8 -Path $resolvedBindingsPath -Document ([pscustomobject]$outputDocument)

$result['Launched'] = $true
$result['BindingUpdated'] = $true
$result['NewShellPid'] = [string]$process.Id
$result['NewWindowPid'] = [string]$movedWindow.ProcessId
$result['NewHwnd'] = [string]$movedWindow.Hwnd
$result['NewWindowTitle'] = [string]$movedWindow.Title
$result['NewWindowClass'] = [string]$movedWindow.ClassName
$result['Moved'] = [bool]$moved
$result['UpdatedAt'] = $updatedAt
$result['TargetDirsAfter'] = [pscustomobject]$writtenTargetDirs
$result['MixedTargetDirsAfter'] = ($writtenTargetDirSet.Count -gt 1)

if ($AsJson) {
    [pscustomobject]$result | ConvertTo-Json -Depth 8
    return
}

[pscustomobject]$result
