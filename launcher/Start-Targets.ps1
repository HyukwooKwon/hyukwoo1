[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ReplaceExisting,
    [switch]$UnsafeForceKillManagedTargets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

. (Join-Path $PSScriptRoot '..\router\RuntimeMap.ps1')

function ConvertTo-EncodedCommand {
    param([Parameter(Mandatory)][string]$CommandText)

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($CommandText)
    return [Convert]::ToBase64String($bytes)
}

function ConvertTo-SingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return ($Value -replace "'", "''")
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

        $sb = [System.Text.StringBuilder]::new(1024)
        [Relay.WindowApi]::GetWindowText($hWnd, $sb, $sb.Capacity) | Out-Null
        $title = $sb.ToString()

        if ([string]::IsNullOrWhiteSpace($title)) {
            return $true
        }

        $classNameSb = [System.Text.StringBuilder]::new(256)
        [Relay.WindowApi]::GetClassName($hWnd, $classNameSb, $classNameSb.Capacity) | Out-Null

        $windows.Add([pscustomobject]@{
            Hwnd      = $hWnd.ToInt64()
            ProcessId = [int]$windowProcessId
            Title     = $title
            ClassName = $classNameSb.ToString()
        })

        return $true
    }, [IntPtr]::Zero) | Out-Null

    return $windows
}

function Wait-ForWindowByTitle {
    param(
        [Parameter(Mandatory)][string]$Title,
        [long[]]$IgnoreHwnds = @(),
        [int]$TimeoutMs = 12000
    )

    $ignoreMap = @{}
    foreach ($hwnd in $IgnoreHwnds) {
        $ignoreMap[[string]$hwnd] = $true
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $match = Get-VisibleWindows |
            Where-Object { $_.Title -eq $Title -and -not $ignoreMap.ContainsKey([string]$_.Hwnd) } |
            Select-Object -First 1

        if ($null -ne $match) {
            return $match
        }

        Start-Sleep -Milliseconds 200
    }

    return $null
}

function Get-WindowProcessName {
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName
    }
    catch {
        return ''
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

function Get-ProcessCommandLine {
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        $process = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop
        return [string]$process.CommandLine
    }
    catch {
        return ''
    }
}

function Get-EnvironmentFlagValue {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($scope in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [string]$value
        }
    }

    return ''
}

function Write-UnsafeRelaunchAuditLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$LauncherSessionId,
        [Parameter(Mandatory)][int]$LauncherPid,
        [Parameter(Mandatory)]$Targets,
        [Parameter(Mandatory)][string]$EnvironmentFlagName
    )

    $record = [ordered]@{
        TimestampUtc         = (Get-Date).ToUniversalTime().ToString('o')
        Operation            = 'replace-existing'
        Root                 = $Root
        ConfigPath           = $ConfigPath
        LauncherSessionId    = $LauncherSessionId
        LauncherPid          = $LauncherPid
        SourceScript         = $PSCommandPath
        UserName             = [Environment]::UserName
        MachineName          = [Environment]::MachineName
        EnvironmentFlagName  = $EnvironmentFlagName
        EnvironmentFlagValue = '1'
        TargetIds            = @($Targets | ForEach-Object { [string]$_.Id })
        WindowTitles         = @($Targets | ForEach-Object { [string]$_.WindowTitle })
    }

    $line = (($record | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine)
    [System.IO.File]::AppendAllText($Path, $line, (New-Utf8NoBomEncoding))
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

function Resolve-WindowForTarget {
    param(
        [Parameter(Mandatory)][string]$Title,
        [long[]]$IgnoreHwnds = @(),
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Parameter(Mandatory)][int]$RetryCount,
        [Parameter(Mandatory)][int]$RetryDelayMs
    )

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        $window = Wait-ForWindowByTitle -Title $Title -IgnoreHwnds $IgnoreHwnds -TimeoutMs $TimeoutMs
        if ($null -ne $window) {
            return [pscustomobject]@{
                Window            = $window
                ResolvedBy        = 'title'
                LookupSucceededAt = (Get-Date).ToString('o')
                Attempt           = $attempt + 1
            }
        }

        if ($attempt -lt $RetryCount) {
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }

    return $null
}

function Stop-TargetProcessSet {
    param(
        [Parameter(Mandatory)]$Targets,
        [Parameter(Mandatory)][string]$RuntimeMapPath,
        [Parameter(Mandatory)][string]$DefaultShellPath
    )

    $runtimeById = @{}
    if (Test-Path -LiteralPath $RuntimeMapPath) {
        try {
            $runtimeItems = Read-RuntimeMap -Path $RuntimeMapPath
            $runtimeById = Get-RuntimeMapByTargetId -Items $runtimeItems
        }
        catch {
        }
    }

    $visibleWindows = Get-VisibleWindows
    $processIds = New-Object System.Collections.Generic.HashSet[int]
    $blockingTitles = New-Object System.Collections.Generic.List[string]
    $defaultShellName = [System.IO.Path]::GetFileNameWithoutExtension($DefaultShellPath)
    $launcherScriptPath = Join-Path $PSScriptRoot 'Start-TargetShell.ps1'

    foreach ($target in $Targets) {
        $targetId = [string]$target.Id
        $title = [string]$target.WindowTitle
        $safeManagedShellPid = 0
        $safeManagedReason = ''

        if ($runtimeById.ContainsKey($targetId)) {
            $runtime = $runtimeById[$targetId]
            $registrationMode = [string]$runtime.RegistrationMode
            $shellPid = if ($null -ne $runtime.ShellPid) { [int]$runtime.ShellPid } else { 0 }
            $shellStartTimeUtc = [string]$runtime.ShellStartTimeUtc
            $managedMarker = [string]$runtime.ManagedMarker

            if ($registrationMode -eq 'launched' -and $shellPid -gt 0 -and (Test-NonEmptyString $shellStartTimeUtc) -and (Test-NonEmptyString $managedMarker)) {
                try {
                    $process = Get-Process -Id $shellPid -ErrorAction Stop
                    $currentStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
                    $expectedShellName = if (Test-NonEmptyString ([string]$runtime.ShellPath)) {
                        [System.IO.Path]::GetFileNameWithoutExtension([string]$runtime.ShellPath)
                    }
                    else {
                        $defaultShellName
                    }

                    $commandLine = Get-ProcessCommandLine -ProcessId $shellPid
                    $hasLauncherScript = (Test-NonEmptyString $commandLine -and $commandLine.Contains($launcherScriptPath))
                    $hasManagedMarker = (Test-NonEmptyString $commandLine -and $commandLine.Contains($managedMarker))

                    if ($currentStartTimeUtc -eq $shellStartTimeUtc -and $process.ProcessName -eq $expectedShellName -and $hasLauncherScript -and $hasManagedMarker) {
                        $safeManagedShellPid = $shellPid
                        [void]$processIds.Add($shellPid)
                    }
                    else {
                        $safeManagedReason = 'managed-shell-marker-mismatch'
                    }
                }
                catch {
                    $safeManagedReason = 'managed-shell-missing'
                }
            }
            elseif ($shellPid -gt 0) {
                $safeManagedReason = 'unmanaged-runtime-entry'
            }
        }

        $visibleMatches = @($visibleWindows | Where-Object { $_.Title -eq $title })
        if ($visibleMatches.Count -gt 1) {
            $blockingTitles.Add($title)
            Write-Host ("replace blocked target={0} title={1} reason=duplicate-visible-windows count={2}" -f $targetId, $title, $visibleMatches.Count)
            continue
        }

        if ($visibleMatches.Count -gt 0 -and $safeManagedShellPid -le 0) {
            $blockingTitles.Add($title)
            $reasonText = if (Test-NonEmptyString $safeManagedReason) { $safeManagedReason } else { 'visible-window-present' }
            Write-Host ("replace blocked target={0} title={1} reason={2}" -f $targetId, $title, $reasonText)
        }
    }

    if ($blockingTitles.Count -gt 0) {
        $titles = @($blockingTitles | Sort-Object -Unique)
        throw ("ReplaceExisting refused because unmanaged or attached target windows are present: {0}. Use attach-targets.ps1 to register existing windows, or close those windows manually before relaunch." -f ($titles -join ', '))
    }

    foreach ($processId in $processIds) {
        if ($processId -eq $PID) {
            continue
        }

        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
            Write-Host "stopped existing pid=$processId"
        }
        catch {
            Write-Host "failed to stop existing pid=$processId"
        }
    }

    if ($processIds.Count -gt 0) {
        Start-Sleep -Seconds 1
    }
}

$config = Import-PowerShellDataFile -Path $ConfigPath
$launcherSessionId = [guid]::NewGuid().ToString('N')
$launchedAt = (Get-Date).ToString('o')
$launcherPid = $PID

foreach ($path in @($config.RuntimeRoot, $config.LogsRoot)) {
    Ensure-Directory -Path ([string]$path)
}

if ($ReplaceExisting) {
    if (-not $UnsafeForceKillManagedTargets) {
        throw 'ReplaceExisting requires -UnsafeForceKillManagedTargets. Prefer ensure-targets.ps1 or attach-targets.ps1 on shared machines.'
    }

    $unsafeForceKillFlagName = 'RELAY_ALLOW_UNSAFE_FORCE_KILL'
    $unsafeForceKillFlagValue = Get-EnvironmentFlagValue -Name $unsafeForceKillFlagName
    if ($unsafeForceKillFlagValue -ne '1') {
        throw ("ReplaceExisting requires {0}=1 in the environment as an additional safety check." -f $unsafeForceKillFlagName)
    }

    $unsafeForceKillAuditLogPath = Join-Path ([string]$config.LogsRoot) 'unsafe-force-kill.log'
    Write-UnsafeRelaunchAuditLog `
        -Path $unsafeForceKillAuditLogPath `
        -Root ([string]$config.Root) `
        -ConfigPath $ConfigPath `
        -LauncherSessionId $launcherSessionId `
        -LauncherPid $launcherPid `
        -Targets $config.Targets `
        -EnvironmentFlagName $unsafeForceKillFlagName

    Stop-TargetProcessSet -Targets $config.Targets -RuntimeMapPath ([string]$config.RuntimeMapPath) -DefaultShellPath ([string]$config.ShellPath)
}

$runtimeEntries = @()
$failures = @()

foreach ($target in $config.Targets) {
    $title = [string]$target.WindowTitle
    $shellPath = [string]$config.ShellPath
    $targetId = [string]$target.Id

    if (-not (Get-Command $shellPath -ErrorAction SilentlyContinue)) {
        throw "ShellPath not found: $shellPath"
    }

    $existingHwnds = @(Get-VisibleWindows | Where-Object { $_.Title -eq $title } | Select-Object -ExpandProperty Hwnd)
    $managedMarker = [guid]::NewGuid().ToString('N')
    $launcherScriptPath = Join-Path $PSScriptRoot 'Start-TargetShell.ps1'

    $process = Start-Process -FilePath $shellPath -ArgumentList @(
        '-NoProfile',
        '-NoExit',
        '-File',
        $launcherScriptPath,
        '-TargetId',
        $targetId,
        '-WindowTitle',
        $title,
        '-RootPath',
        ([string]$config.Root),
        '-ManagedMarker',
        $managedMarker
    ) -PassThru

    $resolution = Resolve-WindowForTarget `
        -Title $title `
        -IgnoreHwnds $existingHwnds `
        -TimeoutMs ([int]$config.WindowLookupTimeoutMs) `
        -RetryCount ([int]$config.WindowLookupRetryCount) `
        -RetryDelayMs ([int]$config.WindowLookupRetryDelayMs)

    $window = if ($null -ne $resolution) { $resolution.Window } else { $null }
    $processName = if ($null -ne $window) { Get-WindowProcessName -ProcessId ([int]$window.ProcessId) } else { Get-WindowProcessName -ProcessId ([int]$process.Id) }
    $windowClass = if ($null -ne $window) { [string]$window.ClassName } else { '' }
    $hostKind = Get-HostKind -ProcessName $processName -WindowClass $windowClass
    $resolvedBy = if ($null -ne $resolution) { [string]$resolution.ResolvedBy } else { '' }
    $lookupSucceededAt = if ($null -ne $resolution) { [string]$resolution.LookupSucceededAt } else { '' }
    $shellStartTimeUtc = Get-ProcessStartTimeUtcString -ProcessId ([int]$process.Id)

    $runtimeEntries += New-RuntimeMapEntry `
        -TargetId $targetId `
        -ShellPid ([int]$process.Id) `
        -Title $title `
        -ShellPath $shellPath `
        -Window $window `
        -ResolvedBy $resolvedBy `
        -LookupSucceededAt $lookupSucceededAt `
        -LauncherSessionId $launcherSessionId `
        -LaunchedAt $launchedAt `
        -LauncherPid $launcherPid `
        -ProcessName $processName `
        -WindowClass $windowClass `
        -HostKind $hostKind `
        -RegistrationMode 'launched' `
        -ShellStartTimeUtc $shellStartTimeUtc `
        -ManagedMarker $managedMarker

    if ($null -eq $window) {
        $failures += $title
        Write-Host "failed to locate window: $title"
        continue
    }

    Write-Host ("started: {0} pid={1} hwnd={2} resolvedBy={3} attempt={4} class={5}" -f $title, $process.Id, $window.Hwnd, $resolution.ResolvedBy, $resolution.Attempt, $window.ClassName)
}

Write-RuntimeMap -Path ([string]$config.RuntimeMapPath) -Items $runtimeEntries

if ($failures.Count -gt 0) {
    throw ("Failed to resolve HWND for: " + ($failures -join ', '))
}
