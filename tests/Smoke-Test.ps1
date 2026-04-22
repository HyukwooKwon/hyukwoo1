[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$RunLauncher,
    [switch]$RunRouter,
    [switch]$UseTempRoot,
    [string]$TestRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Assert-RuntimeMapTargetIds {
    param(
        [Parameter(Mandatory)]$RuntimeItems,
        [Parameter(Mandatory)]$ConfigTargets
    )

    $expectedIds = @($ConfigTargets | ForEach-Object { [string]$_.Id } | Sort-Object -Unique)
    $runtimeById = @{}

    foreach ($item in $RuntimeItems) {
        $targetId = if ($null -ne $item.TargetId) { [string]$item.TargetId } else { '' }
        Assert-True -Condition (Test-NonEmptyString $targetId) -Message 'runtime map contains blank target id'
        Assert-True -Condition (-not $runtimeById.ContainsKey($targetId)) -Message ("runtime map contains duplicate target id: {0}" -f $targetId)
        $runtimeById[$targetId] = $item
    }

    $actualIds = @($runtimeById.Keys | Sort-Object)
    $missingIds = @($expectedIds | Where-Object { $_ -notin $actualIds })
    $extraIds = @($actualIds | Where-Object { $_ -notin $expectedIds })

    Assert-True -Condition ($missingIds.Count -eq 0) -Message ("runtime map missing target ids: {0}" -f ($missingIds -join ', '))
    Assert-True -Condition ($extraIds.Count -eq 0) -Message ("runtime map has extra target ids: {0}" -f ($extraIds -join ', '))
    Assert-True -Condition ($runtimeById.Count -eq $expectedIds.Count) -Message 'runtime map unique target count mismatch'
}

function Assert-SingleLauncherSession {
    param([Parameter(Mandatory)]$RuntimeItems)

    $sessionIds = @(
        $RuntimeItems |
            ForEach-Object { [string]$_.LauncherSessionId } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    Assert-True -Condition ($sessionIds.Count -eq 1) -Message ("runtime map must contain exactly one LauncherSessionId: {0}" -f ($sessionIds -join ', '))
}

$root = Split-Path -Parent $PSScriptRoot

if ($UseTempRoot -or -not [string]::IsNullOrWhiteSpace($TestRoot)) {
    if ([string]::IsNullOrWhiteSpace($TestRoot)) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $TestRoot = Join-Path $root ('.tmp-smoke\smoke_' + $stamp + '_' + $suffix)
    }

    $ConfigPath = Join-Path $TestRoot 'config\settings.psd1'
}
elseif ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

$isIsolatedRoot = -not [string]::IsNullOrWhiteSpace($TestRoot)
$setupRoot = if ([string]::IsNullOrWhiteSpace($TestRoot)) { $root } else { $TestRoot }
& (Join-Path $root 'setup-relay.ps1') -Root $setupRoot

if (-not [string]::IsNullOrWhiteSpace($TestRoot)) {
    $senderRoot = Join-Path $setupRoot 'sender'
    if (-not (Test-Path -LiteralPath $senderRoot)) {
        New-Item -ItemType Directory -Path $senderRoot | Out-Null
    }

    foreach ($fileName in @('SendToWindow.ahk', 'Resolve-SendTarget.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "sender\$fileName") -Destination (Join-Path $senderRoot $fileName) -Force
    }
}

$config = Import-PowerShellDataFile -Path $ConfigPath
Write-Host ("smoke root: {0}" -f $config.Root)

. (Join-Path $root 'router\RuntimeMap.ps1')
. (Join-Path $root 'router\FileQueue.ps1')

foreach ($path in @(
    $config.InboxRoot, $config.ProcessedRoot, $config.FailedRoot,
    $config.RetryPendingRoot, $config.RuntimeRoot, $config.LogsRoot
)) {
    Assert-True -Condition (Test-Path -LiteralPath ([string]$path)) -Message "missing folder: $path"
}

Assert-True -Condition ($config.Targets.Count -eq 8) -Message 'target count must be 8'

$messageId = [guid]::NewGuid().ToString('N')
& (Join-Path $root 'producer-example.ps1') -ConfigPath $ConfigPath -TargetId 'target01' -Text ("smoke-" + $messageId) | Out-Null

$readyFiles = @(Get-ChildItem -LiteralPath ([string]$config.Targets[0].Folder) -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue)
Assert-True -Condition ($readyFiles.Count -ge 1) -Message 'ready file was not created'

$routerStateProbePath = Join-Path ([string]$config.RuntimeRoot) 'router-state-probe.json'
if (Test-Path -LiteralPath $routerStateProbePath) {
    Remove-Item -LiteralPath $routerStateProbePath -Force -ErrorAction SilentlyContinue
}

$probeQueue = [System.Collections.Generic.Queue[object]]::new()
$probeStateMap = @{}
$probeStateCache = @{}
$probeLauncherTime = (Get-Date).ToString('o')
$firstProbeWrite = Write-RouterState `
    -Path $routerStateProbePath `
    -Queue $probeQueue `
    -StateMap $probeStateMap `
    -Status 'running' `
    -RouterPid $PID `
    -RouterMutexName 'probe-mutex' `
    -LauncherSessionId 'probe-session' `
    -LauncherLaunchedAt $probeLauncherTime `
    -LauncherPid $PID `
    -HostKinds @('probe') `
    -StateCache $probeStateCache

Assert-True -Condition $firstProbeWrite -Message 'first router state probe write must succeed'
$firstProbeWriteTime = (Get-Item -LiteralPath $routerStateProbePath).LastWriteTimeUtc
Start-Sleep -Milliseconds 250
$secondProbeWrite = Write-RouterState `
    -Path $routerStateProbePath `
    -Queue $probeQueue `
    -StateMap $probeStateMap `
    -Status 'running' `
    -RouterPid $PID `
    -RouterMutexName 'probe-mutex' `
    -LauncherSessionId 'probe-session' `
    -LauncherLaunchedAt $probeLauncherTime `
    -LauncherPid $PID `
    -HostKinds @('probe') `
    -StateCache $probeStateCache

Assert-True -Condition (-not $secondProbeWrite) -Message 'unchanged router state must not be rewritten'
$secondProbeWriteTime = (Get-Item -LiteralPath $routerStateProbePath).LastWriteTimeUtc
Assert-True -Condition ($firstProbeWriteTime -eq $secondProbeWriteTime) -Message 'router state probe file should keep the same write timestamp when unchanged'
Remove-Item -LiteralPath $routerStateProbePath -Force -ErrorAction SilentlyContinue

if ($RunLauncher) {
    & (Join-Path $root 'launcher\Start-Targets.ps1') -ConfigPath $ConfigPath
    Start-Sleep -Seconds 1

    Assert-True -Condition (Test-Path -LiteralPath ([string]$config.RuntimeMapPath)) -Message 'runtime map not found'
    $runtimeParsed = Get-Content -LiteralPath ([string]$config.RuntimeMapPath) -Raw -Encoding UTF8 | ConvertFrom-Json
    $runtime = if ($null -eq $runtimeParsed) {
        @()
    }
    elseif ($runtimeParsed -is [System.Array]) {
        $runtimeParsed
    }
    else {
        ,$runtimeParsed
    }
    Assert-True -Condition ($runtime.Count -eq 8) -Message 'runtime map target count mismatch'
    Assert-RuntimeMapTargetIds -RuntimeItems $runtime -ConfigTargets $config.Targets
    Assert-SingleLauncherSession -RuntimeItems $runtime
}

if ($RunRouter) {
    $needsRuntimeSeed = $true
    if (Test-Path -LiteralPath ([string]$config.RuntimeMapPath)) {
        $rawRuntime = Get-Content -LiteralPath ([string]$config.RuntimeMapPath) -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($rawRuntime)) {
            $existingRuntimeParsed = $rawRuntime | ConvertFrom-Json
            $existingRuntime = if ($null -eq $existingRuntimeParsed) {
                @()
            }
            elseif ($existingRuntimeParsed -is [System.Array]) {
                $existingRuntimeParsed
            }
            else {
                ,$existingRuntimeParsed
            }
            if ($existingRuntime.Count -eq $config.Targets.Count) {
                $needsRuntimeSeed = $false
            }
        }
    }

    if ($needsRuntimeSeed) {
        $runtimeSeed = foreach ($target in $config.Targets) {
            [pscustomobject]@{
                TargetId  = [string]$target.Id
                ShellPid  = 0
                WindowPid = 0
                Hwnd      = ''
                Title     = [string]$target.WindowTitle
                StartedAt = (Get-Date).ToString('o')
                ShellPath = [string]$config.ShellPath
                Available = $false
                ResolvedBy = ''
                LookupSucceededAt = ''
                LauncherSessionId = 'smoke-session'
                LaunchedAt = (Get-Date).ToString('o')
                LauncherPid = $PID
                ProcessName = 'pwsh'
                WindowClass = 'ConsoleWindowClass'
                HostKind = 'smoke'
            }
        }

        $json = $runtimeSeed | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText([string]$config.RuntimeMapPath, $json, [System.Text.UTF8Encoding]::new($false))
    }

    & (Join-Path $root 'router\Start-Router.ps1') -ConfigPath $ConfigPath -RunDurationMs 1000
    Assert-True -Condition (Test-Path -LiteralPath ([string]$config.RouterLogPath)) -Message 'router log not found'
    $routerState = Get-Content -LiteralPath ([string]$config.RouterStatePath) -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($routerState.Status -eq 'stopped') -Message 'router state status must be stopped after timed run'
    Assert-True -Condition (Test-NonEmptyString ([string]$routerState.RouterMutexName)) -Message 'router mutex name must be written'
    Assert-True -Condition (Test-NonEmptyString ([string]$routerState.LauncherSessionId)) -Message 'launcher session id must be written'
    Assert-True -Condition ($null -ne $routerState.RouterPid -and [int]$routerState.RouterPid -gt 0) -Message 'router pid must be written'
    Assert-True -Condition ($null -ne $routerState.HostKinds -and @($routerState.HostKinds).Count -ge 1) -Message 'router host kinds must be written'

    $statusJson = & (Join-Path $root 'show-relay-status.ps1') -ConfigPath $ConfigPath -RecentCount 2 -AsJson
    $status = $statusJson | ConvertFrom-Json
    Assert-True -Condition ([string]$status.Router.Status -eq 'stopped') -Message 'show-relay-status router status must be stopped after timed run'
    Assert-True -Condition ($null -ne $status.Counts -and [int]$status.Counts.RetryPending -ge 1) -Message 'show-relay-status must report retry-pending count'
    Assert-True -Condition (@($status.NextActions | Where-Object { $_ -like '*Requeue-RetryPending.ps1*' }).Count -ge 1) -Message 'show-relay-status must suggest retry-pending requeue command'
    Assert-True -Condition (@($status.Targets).Count -eq $config.Targets.Count) -Message 'show-relay-status must include all configured targets'

    if ($isIsolatedRoot) {
        $mixedRuntimeSeed = foreach ($index in 0..($config.Targets.Count - 1)) {
            $target = $config.Targets[$index]
            [pscustomobject]@{
                TargetId          = [string]$target.Id
                ShellPid          = 0
                WindowPid         = 0
                Hwnd              = ''
                Title             = [string]$target.WindowTitle
                StartedAt         = (Get-Date).ToString('o')
                ShellPath         = [string]$config.ShellPath
                Available         = $false
                ResolvedBy        = ''
                LookupSucceededAt = ''
                LauncherSessionId = if (($index % 2) -eq 0) { 'smoke-session-a' } else { 'smoke-session-b' }
                LaunchedAt        = (Get-Date).ToString('o')
                LauncherPid       = $PID
                ProcessName       = 'pwsh'
                WindowClass       = 'ConsoleWindowClass'
                HostKind          = 'smoke'
            }
        }

        $mixedRuntimeJson = $mixedRuntimeSeed | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText([string]$config.RuntimeMapPath, $mixedRuntimeJson, [System.Text.UTF8Encoding]::new($false))
        $routerShell = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $mixedRun = Start-Process -FilePath $routerShell -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $root 'router\Start-Router.ps1'),
            '-ConfigPath', $ConfigPath,
            '-RunDurationMs', '250'
        ) -Wait -PassThru -WindowStyle Hidden

        Assert-True -Condition ($mixedRun.ExitCode -ne 0) -Message 'router must fail when runtime map contains mixed LauncherSessionId values'
        $mixedRouterState = Get-Content -LiteralPath ([string]$config.RouterStatePath) -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Condition ($mixedRouterState.Status -eq 'failed') -Message 'router state must be failed after mixed LauncherSessionId rejection'
        Assert-True -Condition ([string]$mixedRouterState.LastError -like '*LauncherSessionId*') -Message 'router state must record mixed LauncherSessionId failure'
    }
}

Write-Host 'Smoke-Test completed'
