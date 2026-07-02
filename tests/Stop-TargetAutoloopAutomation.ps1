[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$RunRoot = @(),
    [int]$GraceSeconds = 5,
    [switch]$InspectOnly,
    [switch]$ForceAfterGrace,
    [string]$LogPath,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred -PathType Leaf) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

function Get-NormalizedPath {
    param([string]$PathValue)

    if (-not (Test-NonEmptyString $PathValue)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    catch {
        return [string]$PathValue
    }
}

function Get-NormalizedLookupKey {
    param([string]$PathValue)

    $normalized = Get-NormalizedPath -PathValue $PathValue
    if (-not (Test-NonEmptyString $normalized)) {
        return ''
    }

    return $normalized.ToLowerInvariant()
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-JsonFileAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$PayloadJson
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $tempPath = $Path + '.tmp'
    Set-Content -LiteralPath $tempPath -Encoding UTF8 -Value $PayloadJson
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function ConvertFrom-CommandLineRunRootToken {
    param([string]$Token)

    $value = [string]$Token
    if ($value.Length -ge 2) {
        $first = $value.Substring(0, 1)
        $last = $value.Substring($value.Length - 1, 1)
        if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }

    return $value.Replace("''", "'").Trim()
}

function Resolve-TargetAutoloopProcessRunRoot {
    param([string]$CommandLine)

    $commandText = [string]$CommandLine
    if (-not (Test-NonEmptyString $commandText)) {
        return ''
    }

    $quotedMatch = [regex]::Match($commandText, "-RunRoot\s+('([^']|'')*'|""([^""]|"""")*"")")
    if ($quotedMatch.Success) {
        return (Get-NormalizedPath -PathValue (ConvertFrom-CommandLineRunRootToken -Token $quotedMatch.Groups[1].Value))
    }

    $plainMatch = [regex]::Match($commandText, '-RunRoot\s+([^\s]+)')
    if ($plainMatch.Success) {
        return (Get-NormalizedPath -PathValue (ConvertFrom-CommandLineRunRootToken -Token $plainMatch.Groups[1].Value))
    }

    $pathMatch = [regex]::Match($commandText, '([A-Za-z]:\\[^"''\r\n]*?\\target-autoloop\\run_\d+_\d+_\d+)')
    if ($pathMatch.Success) {
        return (Get-NormalizedPath -PathValue $pathMatch.Groups[1].Value)
    }

    return ''
}

function New-RunRootFilter {
    param([string[]]$Values)

    $filter = @{}
    foreach ($value in @($Values)) {
        $key = Get-NormalizedLookupKey -PathValue $value
        if (Test-NonEmptyString $key) {
            $filter[$key] = $true
        }
    }

    return $filter
}

function Get-TargetAutoloopAutomationProcessSnapshot {
    param(
        [hashtable]$RunRootFilter,
        [int]$SelfProcessId
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $processes = Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $SelfProcessId -and (
            [string]$_.CommandLine -like '*Watch-TargetAutoloop.ps1*' -or
            [string]$_.CommandLine -like '*target-autoloop-watcher.launch.ps1*' -or
            [string]$_.CommandLine -like '*Start-TargetAutoloopWorker.ps1*'
        )
    }

    foreach ($process in @($processes)) {
        $commandText = [string]$process.CommandLine
        $runRootValue = Resolve-TargetAutoloopProcessRunRoot -CommandLine $commandText
        $runRootKey = Get-NormalizedLookupKey -PathValue $runRootValue
        if (-not (Test-NonEmptyString $runRootKey)) {
            continue
        }
        if ($RunRootFilter.Count -gt 0) {
            if (-not $RunRootFilter.ContainsKey($runRootKey)) {
                continue
            }
        }

        $kind = if ($commandText -like '*Watch-TargetAutoloop.ps1*') {
            'watcher'
        }
        elseif ($commandText -like '*target-autoloop-watcher.launch.ps1*') {
            'launcher'
        }
        else {
            'worker'
        }
        [void]$rows.Add([pscustomobject][ordered]@{
            ProcessId = [int]$process.ProcessId
            ParentProcessId = [int]$process.ParentProcessId
            Name = [string]$process.Name
            Kind = $kind
            RunRoot = $runRootValue
            RunRootKey = $runRootKey
        })
    }

    return @($rows.ToArray() | Sort-Object RunRoot, Kind, ProcessId)
}

function Request-TargetAutoloopStop {
    param(
        [Parameter(Mandatory)][string]$RequestScript,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot
    )

    try {
        $raw = & pwsh -NoProfile -ExecutionPolicy Bypass -File $RequestScript `
            -ConfigPath $ConfigPath `
            -RunRoot $RunRoot `
            -Action stop `
            -RequestedBy 'relay_operator_panel_shutdown' `
            -AsJson
        $payload = $raw | ConvertFrom-Json
        return [pscustomobject][ordered]@{
            RunRoot = $RunRoot
            Ok = [bool]$payload.Ok
            Result = [string]$payload.Result
            RequestId = [string]$payload.RequestId
            Message = [string]$payload.Message
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            RunRoot = $RunRoot
            Ok = $false
            Result = 'request-failed'
            RequestId = ''
            Message = $_.Exception.Message
        }
    }
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}
$ConfigPath = Get-NormalizedPath -PathValue $ConfigPath
$requestScript = Join-Path $root 'tests\Request-TargetAutoloopControl.ps1'
$runRootFilter = New-RunRootFilter -Values $RunRoot

$initialProcesses = @(Get-TargetAutoloopAutomationProcessSnapshot -RunRootFilter $runRootFilter -SelfProcessId $PID)
$runRoots = @(
    $initialProcesses |
        Where-Object { Test-NonEmptyString $_.RunRoot } |
        ForEach-Object { [string]$_.RunRoot } |
        Sort-Object -Unique
)

$stopRequests = @()
if (-not $InspectOnly) {
    foreach ($runRootValue in @($runRoots)) {
        $stopRequests += Request-TargetAutoloopStop -RequestScript $requestScript -ConfigPath $ConfigPath -RunRoot $runRootValue
    }
}

$remainingBeforeForce = @()
$grace = [math]::Max(0, $GraceSeconds)
if ($InspectOnly) {
    $remainingBeforeForce = @($initialProcesses)
}
elseif ($grace -gt 0 -and @($initialProcesses).Count -gt 0) {
    $deadline = (Get-Date).AddSeconds($grace)
    do {
        Start-Sleep -Milliseconds 500
        $remainingBeforeForce = @(Get-TargetAutoloopAutomationProcessSnapshot -RunRootFilter $runRootFilter -SelfProcessId $PID)
        if (@($remainingBeforeForce).Count -eq 0) {
            break
        }
    } while ((Get-Date) -lt $deadline)
}
else {
    $remainingBeforeForce = @(Get-TargetAutoloopAutomationProcessSnapshot -RunRootFilter $runRootFilter -SelfProcessId $PID)
}

$forceStopped = @()
if ((-not $InspectOnly) -and $ForceAfterGrace -and @($remainingBeforeForce).Count -gt 0) {
    foreach ($process in @($remainingBeforeForce)) {
        try {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
            $forceStopped += [pscustomobject][ordered]@{
                ProcessId = [int]$process.ProcessId
                RunRoot = [string]$process.RunRoot
                Kind = [string]$process.Kind
                Stopped = $true
                Error = ''
            }
        }
        catch {
            $forceStopped += [pscustomobject][ordered]@{
                ProcessId = [int]$process.ProcessId
                RunRoot = [string]$process.RunRoot
                Kind = [string]$process.Kind
                Stopped = $false
                Error = $_.Exception.Message
            }
        }
    }

    Start-Sleep -Milliseconds 500
}

$remainingAfter = @(Get-TargetAutoloopAutomationProcessSnapshot -RunRootFilter $runRootFilter -SelfProcessId $PID)
$mode = if ($InspectOnly) { 'inspect' } else { 'stop' }
$ok = if ($InspectOnly) { $true } else { @($remainingAfter).Count -eq 0 }
$payload = [pscustomobject][ordered]@{
    SchemaVersion = '1.0.0'
    Mode = $mode
    Ok = $ok
    ConfigPath = $ConfigPath
    InitialProcessCount = @($initialProcesses).Count
    RunRoots = @($runRoots)
    StopRequests = @($stopRequests)
    GraceSeconds = $grace
    ForceAfterGrace = [bool]$ForceAfterGrace
    RemainingBeforeForce = @($remainingBeforeForce)
    ForceStopped = @($forceStopped)
    RemainingAfter = @($remainingAfter)
    RemainingAfterCount = @($remainingAfter).Count
}

$payloadJson = $payload | ConvertTo-Json -Depth 10
if (Test-NonEmptyString $LogPath) {
    Write-JsonFileAtomically -Path (Get-NormalizedPath -PathValue $LogPath) -PayloadJson $payloadJson
}

if ($AsJson) {
    $payloadJson
    return
}

$payload
