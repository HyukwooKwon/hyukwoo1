[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$WaitForReleaseSeconds = 15,
    [int]$WaitForStartupSeconds = 20,
    [int]$RunDurationMs = 0,
    [switch]$Force,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$PathValue)

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PathValue))
}

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }

        if ($command.Source) {
            return [string]$command.Source
        }
        if ($command.Path) {
            return [string]$command.Path
        }
        return [string]$name
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
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

function Get-MatchingRouterProcesses {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath
    )

    $routerWrapperPath = [regex]::Escape((Join-Path $Root 'router.ps1'))
    $routerStartPath = [regex]::Escape((Join-Path $Root 'router\Start-Router.ps1'))
    $configRegex = [regex]::Escape($ResolvedConfigPath)

    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Name -match '^(pwsh|powershell)(\.exe)?$') -and
                (Test-NonEmptyString $_.CommandLine) -and
                $_.CommandLine -match $configRegex -and
                ($_.CommandLine -match $routerWrapperPath -or $_.CommandLine -match $routerStartPath)
            } |
            Sort-Object ProcessId
    )
}

function Wait-ForMutexReleased {
    param(
        [Parameter(Mandatory)][string]$MutexName,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-MutexHeld -Name $MutexName)) {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "router mutex release timeout: $MutexName"
}

function Wait-ForRouterStarted {
    param(
        [Parameter(Mandatory)][string]$MutexName,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        if (Test-MutexHeld -Name $MutexName) {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "router startup timeout: $MutexName"
}

$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$routerStatePath = [string]$config.RouterStatePath
$routerState = Read-JsonObject -Path $routerStatePath
$routerMutexName = [string]$config.RouterMutexName

$processingPath = ''
$queueCount = 0
$pendingQueueCount = 0
if ($null -ne $routerState) {
    $queueCount = [int]($routerState.QueueCount | ForEach-Object { $_ })
    $pendingQueueCount = [int]($routerState.PendingQueueCount | ForEach-Object { $_ })
    if ($null -ne $routerState.Processing) {
        $processingPath = [string]$routerState.Processing.Path
    }
}

if (-not $Force) {
    if (Test-NonEmptyString $processingPath) {
        throw "router is actively processing a message. processing=$processingPath"
    }
    if ($queueCount -gt 0 -or $pendingQueueCount -gt 0) {
        throw "router queue is not idle. queueCount=$queueCount pendingQueueCount=$pendingQueueCount"
    }
}

$matchingProcesses = Get-MatchingRouterProcesses -Root $root -ResolvedConfigPath $resolvedConfigPath
$matchedProcessIds = @($matchingProcesses | ForEach-Object { [int]$_.ProcessId })
$stoppedProcessIds = New-Object System.Collections.Generic.List[int]

foreach ($process in $matchingProcesses) {
    $processId = [int]$process.ProcessId
    try {
        Stop-Process -Id $processId -Force -ErrorAction Stop
        $stoppedProcessIds.Add($processId)
    }
    catch {
        if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            continue
        }

        throw
    }
}

if (Test-MutexHeld -Name $routerMutexName) {
    Wait-ForMutexReleased -MutexName $routerMutexName -TimeoutSeconds $WaitForReleaseSeconds
}

$tmpRoot = Join-Path $root '_tmp'
if (-not (Test-Path -LiteralPath $tmpRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$stdoutPath = Join-Path $tmpRoot ('router-restart-' + $timestamp + '.stdout.log')
$stderrPath = ($stdoutPath + '.stderr')

$powershellPath = Resolve-PowerShellExecutable
$argumentList = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'router.ps1'),
    '-ConfigPath', $resolvedConfigPath
)
if ($RunDurationMs -gt 0) {
    $argumentList += @('-RunDurationMs', [string]$RunDurationMs)
}

$startedProcess = Start-Process -FilePath $powershellPath -ArgumentList $argumentList -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

Wait-ForRouterStarted -MutexName $routerMutexName -TimeoutSeconds $WaitForStartupSeconds
$finalRouterState = Read-JsonObject -Path $routerStatePath
$effectiveRouterPid = 0
if ($null -ne $finalRouterState -and $null -ne $finalRouterState.RouterPid) {
    $effectiveRouterPid = [int]$finalRouterState.RouterPid
}

$result = [pscustomobject]@{
    RestartedAt = (Get-Date).ToString('o')
    ConfigPath = $resolvedConfigPath
    RouterMutexName = $routerMutexName
    MatchedProcessIds = @($matchedProcessIds)
    StoppedProcessIds = @($stoppedProcessIds)
    StartedProcessId = [int]$startedProcess.Id
    EffectiveRouterPid = $effectiveRouterPid
    StdoutLogPath = $stdoutPath
    StderrLogPath = $stderrPath
    MutexHeld = (Test-MutexHeld -Name $routerMutexName)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
}
else {
    $result
}
