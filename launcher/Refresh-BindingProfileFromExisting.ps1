[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$BindingsPath,
    [ValidateSet('Full', 'Pairs')][string]$ReuseMode = 'Full',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

. (Join-Path $PSScriptRoot '..\router\RuntimeMap.ps1')
. (Join-Path $PSScriptRoot '..\router\BindingRefreshReuseScope.ps1')

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

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

function Get-ConfiguredTargetMetadata {
    param(
        [Parameter(Mandatory)]$BindingDocument,
        [Parameter(Mandatory)]$Config
    )

    $targetMap = [ordered]@{}
    $configTargets = @($Config.Targets | Sort-Object Id)
    $configTargetIds = @($configTargets | ForEach-Object { [string]$_.Id })
    $configuredTargets = Get-JsonValue -Object $BindingDocument.Data -Name 'configured_targets' -DefaultValue @()
    if ($null -eq $configuredTargets) {
        $configuredTargets = @()
    }
    elseif (-not ($configuredTargets -is [System.Array])) {
        $configuredTargets = ,$configuredTargets
    }

    foreach ($entry in @($configuredTargets)) {
        $targetId = [string](Get-JsonValue -Object $entry -Name 'target_id' -DefaultValue '')
        if (-not (Test-NonEmptyString $targetId)) {
            $targetId = [string](Get-JsonValue -Object $entry -Name 'TargetId' -DefaultValue '')
        }
        if (-not (Test-NonEmptyString $targetId)) {
            continue
        }

        $pairId = [string](Get-JsonValue -Object $entry -Name 'pair_id' -DefaultValue '')
        if (-not (Test-NonEmptyString $pairId)) {
            $pairId = [string](Get-JsonValue -Object $entry -Name 'PairId' -DefaultValue '')
        }

        $roleName = [string](Get-JsonValue -Object $entry -Name 'role_name' -DefaultValue '')
        if (-not (Test-NonEmptyString $roleName)) {
            $roleName = [string](Get-JsonValue -Object $entry -Name 'RoleName' -DefaultValue '')
        }

        $windowTitle = [string](Get-JsonValue -Object $entry -Name 'window_title' -DefaultValue '')
        if (-not (Test-NonEmptyString $windowTitle)) {
            $windowTitle = [string](Get-JsonValue -Object $entry -Name 'WindowTitle' -DefaultValue '')
        }

        $windowClass = [string](Get-JsonValue -Object $entry -Name 'window_class' -DefaultValue '')
        if (-not (Test-NonEmptyString $windowClass)) {
            $windowClass = [string](Get-JsonValue -Object $entry -Name 'WindowClass' -DefaultValue '')
        }

        $targetMap[$targetId] = [ordered]@{
            target_id    = $targetId
            pair_id      = $pairId
            role_name    = $roleName
            window_title = $windowTitle
            window_class = $windowClass
        }
    }

    foreach ($binding in @($BindingDocument.Windows)) {
        $targetId = [string](Get-JsonValue -Object $binding -Name 'target_id' -DefaultValue '')
        if (-not (Test-NonEmptyString $targetId)) {
            $targetId = [string](Get-JsonValue -Object $binding -Name 'TargetId' -DefaultValue '')
        }
        if (-not (Test-NonEmptyString $targetId)) {
            continue
        }

        if (-not $targetMap.Contains($targetId)) {
            $targetMap[$targetId] = [ordered]@{
                target_id    = $targetId
                pair_id      = ''
                role_name    = ''
                window_title = ''
                window_class = ''
            }
        }

        if (-not (Test-NonEmptyString $targetMap[$targetId]['pair_id'])) {
            $targetMap[$targetId]['pair_id'] = [string](Get-JsonValue -Object $binding -Name 'pair_id' -DefaultValue '')
        }
        if (-not (Test-NonEmptyString $targetMap[$targetId]['role_name'])) {
            $targetMap[$targetId]['role_name'] = [string](Get-JsonValue -Object $binding -Name 'role_name' -DefaultValue '')
        }
        if (-not (Test-NonEmptyString $targetMap[$targetId]['window_title'])) {
            $windowTitle = [string](Get-JsonValue -Object $binding -Name 'window_title' -DefaultValue '')
            if (-not (Test-NonEmptyString $windowTitle)) {
                $windowTitle = [string](Get-JsonValue -Object $binding -Name 'WindowTitle' -DefaultValue '')
            }
            $targetMap[$targetId]['window_title'] = $windowTitle
        }
        if (-not (Test-NonEmptyString $targetMap[$targetId]['window_class'])) {
            $windowClass = [string](Get-JsonValue -Object $binding -Name 'window_class' -DefaultValue '')
            if (-not (Test-NonEmptyString $windowClass)) {
                $windowClass = [string](Get-JsonValue -Object $binding -Name 'WindowClass' -DefaultValue '')
            }
            $targetMap[$targetId]['window_class'] = $windowClass
        }
    }

    foreach ($target in $configTargets) {
        $targetId = [string]$target.Id
        if (-not $targetMap.Contains($targetId)) {
            $targetMap[$targetId] = [ordered]@{
                target_id    = $targetId
                pair_id      = ''
                role_name    = ''
                window_title = [string]$target.WindowTitle
                window_class = ''
            }
            continue
        }

        if (-not (Test-NonEmptyString $targetMap[$targetId]['window_title'])) {
            $targetMap[$targetId]['window_title'] = [string]$target.WindowTitle
        }
    }

    $orderedTargets = New-Object System.Collections.Generic.List[object]
    foreach ($targetId in $configTargetIds) {
        if ($targetMap.Contains($targetId)) {
            $orderedTargets.Add([pscustomobject]$targetMap[$targetId])
        }
    }

    foreach ($targetId in @($targetMap.Keys | Where-Object { $_ -notin $configTargetIds } | Sort-Object)) {
        $orderedTargets.Add([pscustomobject]$targetMap[$targetId])
    }

    return @($orderedTargets.ToArray())
}

function Ensure-WindowApiType {
    if ('Relay.WindowApi' -as [type]) {
        return
    }

    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace Relay {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static class WindowApi {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    }
}
'@
}

function Get-VisibleWindows {
    Ensure-WindowApiType

    $windows = New-Object System.Collections.Generic.List[object]
    [Relay.WindowApi]::EnumWindows({
        param($hWnd, $lParam)

        if (-not [Relay.WindowApi]::IsWindowVisible($hWnd)) {
            return $true
        }

        $windowProcessId = 0
        [Relay.WindowApi]::GetWindowThreadProcessId($hWnd, [ref]$windowProcessId) | Out-Null

        $titleBuffer = [System.Text.StringBuilder]::new(1024)
        [Relay.WindowApi]::GetWindowText($hWnd, $titleBuffer, $titleBuffer.Capacity) | Out-Null
        $title = $titleBuffer.ToString()
        if ([string]::IsNullOrWhiteSpace($title)) {
            return $true
        }

        $classBuffer = [System.Text.StringBuilder]::new(256)
        [Relay.WindowApi]::GetClassName($hWnd, $classBuffer, $classBuffer.Capacity) | Out-Null

        $rect = [Relay.RECT]::new()
        $rectValues = @()
        if ([Relay.WindowApi]::GetWindowRect($hWnd, [ref]$rect)) {
            $rectValues = @(
                [int]$rect.Left,
                [int]$rect.Top,
                [int]$rect.Right,
                [int]$rect.Bottom
            )
        }

        $windows.Add([pscustomobject]@{
            Hwnd      = $hWnd.ToInt64()
            ProcessId = [int]$windowProcessId
            Title     = $title
            ClassName = $classBuffer.ToString()
            Rect      = @($rectValues)
        })

        return $true
    }, [IntPtr]::Zero) | Out-Null

    return $windows
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

    try {
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        throw "Binding file parse error: $($_.Exception.Message)"
    }

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
        Data       = $parsed
        Windows    = @($windows)
        LastWriteAt = (Get-Item -LiteralPath $Path).LastWriteTime.ToString('o')
    }
}

function Resolve-BindingWindow {
    param(
        [Parameter(Mandatory)]$VisibleWindows,
        [string]$Hwnd,
        [int]$WindowPid,
        [string]$Title,
        [string]$WindowClass
    )

    if (Test-NonEmptyString $Hwnd) {
        $hwndMatches = @($VisibleWindows | Where-Object { [string]$_.Hwnd -eq $Hwnd })
        if ($hwndMatches.Count -eq 1) {
            return [pscustomobject]@{ Match = $hwndMatches[0]; Method = 'hwnd'; Reason = '' }
        }
        if ($hwndMatches.Count -gt 1) {
            return [pscustomobject]@{ Match = $null; Method = 'hwnd'; Reason = 'duplicate-hwnd' }
        }
    }

    if ($WindowPid -gt 0) {
        $windowPidMatches = @($VisibleWindows | Where-Object { $_.ProcessId -eq $WindowPid })
        if ($windowPidMatches.Count -eq 1) {
            return [pscustomobject]@{ Match = $windowPidMatches[0]; Method = 'windowPid'; Reason = '' }
        }
    }

    if (Test-NonEmptyString $Title) {
        $titleMatches = @($VisibleWindows | Where-Object { $_.Title -eq $Title })
        if ($titleMatches.Count -eq 1) {
            return [pscustomobject]@{ Match = $titleMatches[0]; Method = 'title'; Reason = '' }
        }

        if (Test-NonEmptyString $WindowClass) {
            $classMatches = @($titleMatches | Where-Object { $_.ClassName -eq $WindowClass })
            if ($classMatches.Count -eq 1) {
                return [pscustomobject]@{ Match = $classMatches[0]; Method = 'title+class'; Reason = '' }
            }
            if ($classMatches.Count -gt 1) {
                return [pscustomobject]@{ Match = $null; Method = 'title+class'; Reason = 'duplicate-visible-title-class' }
            }
        }

        if ($titleMatches.Count -gt 1) {
            return [pscustomobject]@{ Match = $null; Method = 'title'; Reason = 'duplicate-visible-title' }
        }
    }

    return [pscustomobject]@{ Match = $null; Method = ''; Reason = 'no-visible-window' }
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

function Write-JsonDocumentUtf8 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Document
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $json = $Document | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Utf8NoBomEncoding))
}

$config = Import-PowerShellDataFile -Path $resolvedConfigPath
if ([string]::IsNullOrWhiteSpace($BindingsPath)) {
    $BindingsPath = [string](Get-JsonValue -Object $config -Name 'BindingProfilePath' -DefaultValue '')
}

if ([string]::IsNullOrWhiteSpace($BindingsPath)) {
    throw 'BindingsPath is required. Pass -BindingsPath or set BindingProfilePath in the config.'
}

$bindingDoc = Read-BindingDocument -Path $BindingsPath
$configuredTargets = @(Get-ConfiguredTargetMetadata -BindingDocument $bindingDoc -Config $config)
$bindingByTargetId = @{}
$duplicateBindingTargetIds = New-Object System.Collections.Generic.List[string]

foreach ($binding in $bindingDoc.Windows) {
    $targetId = [string](Get-JsonValue -Object $binding -Name 'target_id' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetId)) {
        $targetId = [string](Get-JsonValue -Object $binding -Name 'TargetId' -DefaultValue '')
    }

    if (-not (Test-NonEmptyString $targetId)) {
        throw 'Binding file contains an entry without target_id.'
    }

    if ($bindingByTargetId.ContainsKey($targetId)) {
        $duplicateBindingTargetIds.Add($targetId)
        continue
    }

    $bindingByTargetId[$targetId] = $binding
}

$expectedTargets = @($configuredTargets)
$expectedTargetIds = @($expectedTargets | ForEach-Object { [string](Get-JsonValue -Object $_ -Name 'target_id' -DefaultValue '') } | Where-Object { Test-NonEmptyString $_ })
$extraBindingTargetIds = @($bindingByTargetId.Keys | Where-Object { $_ -notin $expectedTargetIds } | Sort-Object)
$visibleWindows = @(
    Get-VisibleWindows |
        Where-Object {
            $title = [string]$_.Title
            $className = [string]$_.ClassName
            Test-NonEmptyString $title -and (Test-NonEmptyString $className)
        }
)

$targets = @()
$refreshedWindows = @()
$globalFailures = New-Object System.Collections.Generic.List[string]

foreach ($duplicateTargetId in @($duplicateBindingTargetIds | Sort-Object -Unique)) {
    $globalFailures.Add(("duplicate-binding:{0}" -f $duplicateTargetId))
}

foreach ($extraTargetId in $extraBindingTargetIds) {
    $globalFailures.Add(("extra-binding:{0}" -f $extraTargetId))
}

foreach ($target in $expectedTargets) {
    $targetId = [string](Get-JsonValue -Object $target -Name 'target_id' -DefaultValue '')
    $targetPairId = [string](Get-JsonValue -Object $target -Name 'pair_id' -DefaultValue '')
    $targetRoleName = [string](Get-JsonValue -Object $target -Name 'role_name' -DefaultValue '')
    $targetWindowTitle = [string](Get-JsonValue -Object $target -Name 'window_title' -DefaultValue '')
    $targetWindowClass = [string](Get-JsonValue -Object $target -Name 'window_class' -DefaultValue '')
    $binding = if ($bindingByTargetId.ContainsKey($targetId)) { $bindingByTargetId[$targetId] } else { $null }
    if ($null -eq $binding) {
        $targets += [pscustomobject]@{
            TargetId     = $targetId
            PairId       = $targetPairId
            RoleName     = $targetRoleName
            Matched      = $false
            MatchMethod  = ''
            Reason       = 'missing-binding'
            ShellPid     = ''
            WindowPid    = ''
            Hwnd         = ''
            WindowTitle  = $targetWindowTitle
            WindowClass  = $targetWindowClass
        }
        continue
    }

    $shellPid = [int](Get-JsonValue -Object $binding -Name 'shell_pid' -DefaultValue 0)
    if ($shellPid -le 0) {
        $shellPid = [int](Get-JsonValue -Object $binding -Name 'ShellPid' -DefaultValue 0)
    }

    $windowPid = [int](Get-JsonValue -Object $binding -Name 'window_pid' -DefaultValue 0)
    if ($windowPid -le 0) {
        $windowPid = [int](Get-JsonValue -Object $binding -Name 'WindowPid' -DefaultValue 0)
    }

    $hwnd = [string](Get-JsonValue -Object $binding -Name 'hwnd' -DefaultValue '')
    if (-not (Test-NonEmptyString $hwnd)) {
        $hwnd = [string](Get-JsonValue -Object $binding -Name 'Hwnd' -DefaultValue '')
    }

    $windowTitle = [string](Get-JsonValue -Object $binding -Name 'window_title' -DefaultValue '')
    if (-not (Test-NonEmptyString $windowTitle)) {
        $windowTitle = [string](Get-JsonValue -Object $binding -Name 'WindowTitle' -DefaultValue '')
    }
    if (-not (Test-NonEmptyString $windowTitle)) {
        $windowTitle = [string](Get-JsonValue -Object $binding -Name 'base_title' -DefaultValue $targetWindowTitle)
    }

    $windowClass = [string](Get-JsonValue -Object $binding -Name 'window_class' -DefaultValue '')
    if (-not (Test-NonEmptyString $windowClass)) {
        $windowClass = [string](Get-JsonValue -Object $binding -Name 'WindowClass' -DefaultValue '')
    }

    if ($shellPid -le 0) {
        $targets += [pscustomobject]@{
            TargetId     = $targetId
            PairId       = [string](Get-JsonValue -Object $binding -Name 'pair_id' -DefaultValue $targetPairId)
            RoleName     = [string](Get-JsonValue -Object $binding -Name 'role_name' -DefaultValue $targetRoleName)
            Matched      = $false
            MatchMethod  = ''
            Reason       = 'invalid-shell-pid'
            ShellPid     = ''
            WindowPid    = if ($windowPid -gt 0) { [string]$windowPid } else { '' }
            Hwnd         = $hwnd
            WindowTitle  = $windowTitle
            WindowClass  = $windowClass
        }
        continue
    }

    try {
        Get-Process -Id $shellPid -ErrorAction Stop | Out-Null
    }
    catch {
        $targets += [pscustomobject]@{
            TargetId     = $targetId
            PairId       = [string](Get-JsonValue -Object $binding -Name 'pair_id' -DefaultValue $targetPairId)
            RoleName     = [string](Get-JsonValue -Object $binding -Name 'role_name' -DefaultValue $targetRoleName)
            Matched      = $false
            MatchMethod  = ''
            Reason       = 'shell-missing'
            ShellPid     = [string]$shellPid
            WindowPid    = if ($windowPid -gt 0) { [string]$windowPid } else { '' }
            Hwnd         = $hwnd
            WindowTitle  = $windowTitle
            WindowClass  = $windowClass
        }
        continue
    }

    $resolution = Resolve-BindingWindow `
        -VisibleWindows $visibleWindows `
        -Hwnd $hwnd `
        -WindowPid $windowPid `
        -Title $windowTitle `
        -WindowClass $windowClass

    $match = $resolution.Match
    if ($null -eq $match) {
        $targets += [pscustomobject]@{
            TargetId     = $targetId
            PairId       = [string](Get-JsonValue -Object $binding -Name 'pair_id' -DefaultValue $targetPairId)
            RoleName     = [string](Get-JsonValue -Object $binding -Name 'role_name' -DefaultValue $targetRoleName)
            Matched      = $false
            MatchMethod  = [string]$resolution.Method
            Reason       = [string]$resolution.Reason
            ShellPid     = [string]$shellPid
            WindowPid    = if ($windowPid -gt 0) { [string]$windowPid } else { '' }
            Hwnd         = $hwnd
            WindowTitle  = $windowTitle
            WindowClass  = $windowClass
        }
        continue
    }

    $updatedWindow = Copy-ObjectToOrderedMap -Object $binding
    $updatedWindow['target_id'] = $targetId
    $updatedWindow['window_title'] = [string]$match.Title
    $updatedWindow['shell_pid'] = [int]$shellPid
    $updatedWindow['window_pid'] = [int]$match.ProcessId
    $updatedWindow['hwnd'] = [string]$match.Hwnd
    $updatedWindow['window_class'] = [string]$match.ClassName
    if (@($match.Rect).Count -eq 4) {
        $updatedWindow['rect'] = @(
            [int]$match.Rect[0],
            [int]$match.Rect[1],
            [int]$match.Rect[2],
            [int]$match.Rect[3]
        )
    }

    $refreshedWindows += [pscustomobject]$updatedWindow
    $targets += [pscustomobject]@{
        TargetId     = $targetId
        PairId       = [string](Get-JsonValue -Object $binding -Name 'pair_id' -DefaultValue $targetPairId)
        RoleName     = [string](Get-JsonValue -Object $binding -Name 'role_name' -DefaultValue $targetRoleName)
        Matched      = $true
        MatchMethod  = [string]$resolution.Method
        Reason       = ''
        ShellPid     = [string]$shellPid
        WindowPid    = [string]$match.ProcessId
        Hwnd         = [string]$match.Hwnd
        WindowTitle  = [string]$match.Title
        WindowClass  = [string]$match.ClassName
        WindowProcessName = Get-ProcessNameSafe -ProcessId ([int]$match.ProcessId)
    }
}

$reuseScope = Resolve-BindingRefreshReuseScope `
    -Targets $targets `
    -ExpectedTargetIds $expectedTargetIds `
    -GlobalFailures $globalFailures `
    -ReuseMode $ReuseMode

$targets = @($reuseScope.AnnotatedTargets)
$configuredTargetCount = [int]$reuseScope.ConfiguredTargetCount
$sessionExpectedTargetCount = [int]$reuseScope.SessionExpectedTargetCount
$partialReuse = [bool]$reuseScope.PartialReuse
$activeTargetIdSet = @($reuseScope.ActiveTargetIds)
$activePairIdSet = @($reuseScope.ActivePairIds)
$inactivePairIdSet = @($reuseScope.InactivePairIds)
$incompletePairIdSet = @($reuseScope.IncompletePairIds)
$inactiveTargetIdSet = @($reuseScope.InactiveTargetIds)
$orphanMatchedTargetIdSet = @($reuseScope.OrphanMatchedTargetIds)
$softFindings = @($reuseScope.SoftFindings)
$hardFailures = @($reuseScope.HardFailures)

$windowsToWrite = if ($partialReuse) {
    @($refreshedWindows | Where-Object { [string](Get-JsonValue -Object $_ -Name 'target_id' -DefaultValue '') -in $activeTargetIdSet })
}
else {
    @($refreshedWindows)
}

$success = [bool]$reuseScope.Success
$refreshedAt = (Get-Date).ToString('o')

if ($success) {
    $outputDocument = [ordered]@{}
    if ($bindingDoc.Data -is [System.Array]) {
        $outputDocument['updated_at'] = $refreshedAt
    }
    else {
        $outputDocument = Copy-ObjectToOrderedMap -Object $bindingDoc.Data
    }
    $outputDocument['updated_at'] = $refreshedAt
    $outputDocument['reuse_mode'] = if ($partialReuse) { 'pairs' } else { 'full' }
    $outputDocument['partial_reuse'] = [bool]$partialReuse
    $outputDocument['configured_target_count'] = $configuredTargetCount
    $outputDocument['active_expected_target_count'] = $sessionExpectedTargetCount
    $outputDocument['active_pair_ids'] = @($activePairIdSet)
    $outputDocument['inactive_pair_ids'] = @($inactivePairIdSet)
    $outputDocument['incomplete_pair_ids'] = @($incompletePairIdSet)
    $outputDocument['active_target_ids'] = @($activeTargetIdSet)
    $outputDocument['inactive_target_ids'] = @($inactiveTargetIdSet)
    $outputDocument['orphan_matched_target_ids'] = @($orphanMatchedTargetIdSet)
    $outputDocument['soft_findings'] = @($softFindings | Sort-Object -Unique)
    $outputDocument['configured_targets'] = @(
        $configuredTargets | ForEach-Object {
            [pscustomobject]@{
                target_id    = [string](Get-JsonValue -Object $_ -Name 'target_id' -DefaultValue '')
                pair_id      = [string](Get-JsonValue -Object $_ -Name 'pair_id' -DefaultValue '')
                role_name    = [string](Get-JsonValue -Object $_ -Name 'role_name' -DefaultValue '')
                window_title = [string](Get-JsonValue -Object $_ -Name 'window_title' -DefaultValue '')
                window_class = [string](Get-JsonValue -Object $_ -Name 'window_class' -DefaultValue '')
            }
        }
    )
    $outputDocument['windows'] = @($windowsToWrite)
    Write-JsonDocumentUtf8 -Path $BindingsPath -Document ([pscustomobject]$outputDocument)
}

$status = [pscustomobject]@{
    Success                = [bool]$success
    ConfigPath             = $resolvedConfigPath
    BindingsPath           = [string]$BindingsPath
    CheckedAt              = (Get-Date).ToString('o')
    PreviousBindingWriteAt = [string]$bindingDoc.LastWriteAt
    RefreshedAt            = if ($success) { $refreshedAt } else { '' }
    ReuseMode              = if ($partialReuse) { 'pairs' } else { 'full' }
    PartialReuse           = [bool]$partialReuse
    ConfiguredTargetCount  = $configuredTargetCount
    ExpectedTargetCount    = $sessionExpectedTargetCount
    ActiveExpectedTargetCount = $sessionExpectedTargetCount
    ReusedPairCount        = $activePairIdSet.Count
    ActivePairIds          = @($activePairIdSet)
    InactivePairIds        = @($inactivePairIdSet)
    IncompletePairIds      = @($incompletePairIdSet)
    ActiveTargetIds        = @($activeTargetIdSet)
    InactiveTargetIds      = @($inactiveTargetIdSet)
    OrphanMatchedTargetIds = @($orphanMatchedTargetIdSet)
    ReusedTargetCount      = if ($partialReuse) { $activeTargetIdSet.Count } else { @($targets | Where-Object { $_.Matched }).Count }
    VisibleWindowCount     = @($visibleWindows).Count
    FailureReasons         = @($hardFailures)
    SoftFindings           = @($softFindings | Sort-Object -Unique)
    IgnoredFailureReasons  = @($softFindings | Sort-Object -Unique)
    Targets                = @($targets | Sort-Object TargetId)
    Summary                = if ($success) {
        if ($partialReuse) { "열린 pair 재사용 준비 완료" } else { "기존 8창 재사용 준비 완료" }
    }
    else {
        if ($partialReuse) { "열린 pair 재사용 실패" } else { "기존 8창 재사용 실패" }
    }
}

if ($AsJson) {
    $status | ConvertTo-Json -Depth 8
}
else {
    $lines = New-Object System.Collections.Generic.List[string]
    $headerTitle = if ($partialReuse) { 'Reuse Active Pairs' } else { 'Reuse Existing Windows' }
    $lines.Add($headerTitle)
    $lines.Add(('Config: {0}' -f $status.ConfigPath))
    $lines.Add(('Bindings: {0}' -f $status.BindingsPath))
    if ($partialReuse) {
        $lines.Add(('ReusedPairs: {0}' -f $status.ReusedPairCount))
        $lines.Add(('ReusedTargets: {0}/{1} (configured={2})' -f $status.ReusedTargetCount, $status.ExpectedTargetCount, $status.ConfiguredTargetCount))
        if ($status.ActivePairIds.Count -gt 0) {
            $lines.Add(('ActivePairs: {0}' -f ($status.ActivePairIds -join ', ')))
        }
        if ($status.InactiveTargetIds.Count -gt 0) {
            $lines.Add(('InactiveTargets: {0}' -f ($status.InactiveTargetIds -join ', ')))
        }
    }
    else {
        $lines.Add(('ReusedTargets: {0}/{1}' -f $status.ReusedTargetCount, $status.ExpectedTargetCount))
    }
    $lines.Add(('VisibleWindows: {0}' -f $status.VisibleWindowCount))
    if (Test-NonEmptyString $status.RefreshedAt) {
        $lines.Add(('RefreshedAt: {0}' -f $status.RefreshedAt))
    }
    if ($status.FailureReasons.Count -gt 0) {
        $lines.Add(('Failures: {0}' -f ($status.FailureReasons -join ', ')))
    }
    if ($partialReuse -and $status.SoftFindings.Count -gt 0) {
        $lines.Add(('SoftFindings: {0}' -f ($status.SoftFindings -join ', ')))
    }
    $lines.Add('')
    $table = ($status.Targets | Select-Object TargetId, PairId, RoleName, Matched, CountedAsReused, InSessionScope, ScopeState, PairCompletionState, MatchMethod, Reason, ShellPid, WindowPid, Hwnd, WindowTitle | Format-Table -AutoSize | Out-String).TrimEnd()
    $lines.Add($table)
    $lines
}

if (-not $success) {
    $host.SetShouldExit(1)
    return
}

$host.SetShouldExit(0)
