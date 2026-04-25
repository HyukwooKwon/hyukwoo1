[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DiagnosticOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

. (Join-Path $PSScriptRoot '..\router\RuntimeMap.ps1')
. (Join-Path $PSScriptRoot 'WindowDiscovery.ps1')

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

$config = Import-PowerShellDataFile -Path $ConfigPath
$launcherSessionId = [guid]::NewGuid().ToString('N')
$attachedAt = (Get-Date).ToString('o')
$launcherPid = $PID
$visibleWindows = Get-VisibleWindows
$runtimeEntries = @()
$failures = @()
$matchedCount = 0
$missingCount = 0
$duplicateCount = 0

foreach ($path in @($config.RuntimeRoot, $config.LogsRoot)) {
    Ensure-Directory -Path ([string]$path)
}

foreach ($target in $config.Targets | Sort-Object Id) {
    $targetId = [string]$target.Id
    $title = [string]$target.WindowTitle
    $matches = @($visibleWindows | Where-Object { $_.Title -eq $title })

    if ($matches.Count -eq 0) {
        $missingCount++
        $failures += ("missing:{0}" -f $title)
        if ($DiagnosticOnly) {
            Write-Host ("diagnostic target={0} title={1} matches=0 status=missing" -f $targetId, $title)
        }
        else {
            Write-Host "attach missing title=$title"
        }
        continue
    }

    if ($matches.Count -gt 1) {
        $duplicateCount++
        $failures += ("duplicate:{0}" -f $title)
        if ($DiagnosticOnly) {
            Write-Host ("diagnostic target={0} title={1} matches={2} status=duplicate" -f $targetId, $title, $matches.Count)
        }
        else {
            Write-Host ("attach duplicate title={0} count={1}" -f $title, $matches.Count)
        }
        continue
    }

    $window = $matches[0]
    $processName = Get-WindowProcessName -ProcessId ([int]$window.ProcessId)
    $windowClass = [string]$window.ClassName
    $hostKind = Get-HostKind -ProcessName $processName -WindowClass $windowClass
    $shellPid = [int]$window.ProcessId
    $shellStartTimeUtc = Get-ProcessStartTimeUtcString -ProcessId $shellPid

    $runtimeEntries += New-RuntimeMapEntry `
        -TargetId $targetId `
        -ShellPid $shellPid `
        -Title $title `
        -ShellPath ([string]$config.ShellPath) `
        -Window $window `
        -ResolvedBy 'attach-title' `
        -LookupSucceededAt ((Get-Date).ToString('o')) `
        -LauncherSessionId $launcherSessionId `
        -LaunchedAt $attachedAt `
        -LauncherPid $launcherPid `
        -ProcessName $processName `
        -WindowClass $windowClass `
        -HostKind $hostKind `
        -RegistrationMode 'attached' `
        -ShellStartTimeUtc $shellStartTimeUtc `
        -ManagedMarker ''

    $matchedCount++
    if ($DiagnosticOnly) {
        Write-Host ("diagnostic target={0} title={1} matches=1 hwnd={2} windowPid={3} shellPid={4} hostKind={5} class={6}" -f `
            $targetId,
            $title,
            $window.Hwnd,
            $window.ProcessId,
            $shellPid,
            $hostKind,
            $windowClass)
    }
    else {
        Write-Host ("attached: {0} windowPid={1} hwnd={2} hostKind={3}" -f $title, $window.ProcessId, $window.Hwnd, $hostKind)
    }
}

if ($DiagnosticOnly) {
    Write-Host ("attach diagnostic summary matched={0} missing={1} duplicate={2} runtimeWrite=skipped" -f $matchedCount, $missingCount, $duplicateCount)
}
else {
    Write-RuntimeMap -Path ([string]$config.RuntimeMapPath) -Items $runtimeEntries
}

if ($failures.Count -gt 0) {
    if ($DiagnosticOnly) {
        throw ("Attach-Targets diagnostic found issues: " + ($failures -join ', '))
    }

    throw ("Attach-Targets failed: " + ($failures -join ', '))
}
