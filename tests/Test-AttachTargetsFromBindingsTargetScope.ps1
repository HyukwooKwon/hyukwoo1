[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} expected=[{1}] actual=[{2}]" -f $Message, $Expected, $Actual)
    }
}

function Quote-Psd1String {
    param([AllowNull()][string]$Value)
    return "'" + ([string]($Value ?? '')).Replace("'", "''") + "'"
}

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'launcher\Attach-TargetsFromBindings.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('attach-target-scope-' + [guid]::NewGuid().ToString('N'))
$bindingPath = Join-Path $tempRoot 'runtime\window-bindings\bottest-live-visible.json'
$runtimeMapPath = Join-Path $tempRoot 'runtime\target-runtime.json'
$configPath = Join-Path $tempRoot 'settings.bottest-live-visible.psd1'
$runtimeRoot = Join-Path $tempRoot 'runtime'
$logsRoot = Join-Path $tempRoot 'logs'

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $bindingPath) -Force | Out-Null
    New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null

    $bindingPayload = [ordered]@{
        profile_name = 'bottest-live-visible'
        windows = @(
            [ordered]@{
                target_id = 'target01'
                pair_id = 'pair01'
                role_name = 'top'
                window_title = 'target01 title'
                shell_pid = $PID
                window_pid = 101
                hwnd = '1001'
                window_class = 'CASCADIA_HOSTING_WINDOW_CLASS'
            },
            [ordered]@{
                target_id = 'target02'
                pair_id = 'pair01'
                role_name = 'bottom'
                window_title = 'target02 title'
                shell_pid = $PID
                window_pid = 102
                hwnd = '1002'
                window_class = 'CASCADIA_HOSTING_WINDOW_CLASS'
            }
        )
    }
    [System.IO.File]::WriteAllText(
        $bindingPath,
        ($bindingPayload | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )

    $runtimePayload = @(
        [ordered]@{
            TargetId = 'target01'
            ShellPid = 111
            WindowPid = 211
            Hwnd = 'old-1001'
            Title = 'old target01 title'
            StartedAt = '2026-06-29T00:00:00+09:00'
            ShellPath = 'pwsh.exe'
            Available = $true
            ResolvedBy = 'existing'
            LookupSucceededAt = '2026-06-29T00:00:00+09:00'
            LauncherSessionId = 'session-keep'
            LaunchedAt = '2026-06-29T00:00:00+09:00'
            LauncherPid = 9001
            ProcessName = 'pwsh'
            WindowClass = 'CASCADIA_HOSTING_WINDOW_CLASS'
            HostKind = 'terminal-hosted'
            RegistrationMode = 'attached'
            ShellStartTimeUtc = '2026-06-28T15:00:00Z'
            ManagedMarker = ''
        },
        [ordered]@{
            TargetId = 'target02'
            ShellPid = 222
            WindowPid = 222
            Hwnd = 'old-1002'
            Title = 'old target02 title'
            StartedAt = '2026-06-29T00:00:00+09:00'
            ShellPath = 'pwsh.exe'
            Available = $true
            ResolvedBy = 'existing'
            LookupSucceededAt = '2026-06-29T00:00:00+09:00'
            LauncherSessionId = 'session-stale-target'
            LaunchedAt = '2026-06-29T00:00:00+09:00'
            LauncherPid = 9002
            ProcessName = 'pwsh'
            WindowClass = 'CASCADIA_HOSTING_WINDOW_CLASS'
            HostKind = 'terminal-hosted'
            RegistrationMode = 'attached'
            ShellStartTimeUtc = '2026-06-28T15:00:00Z'
            ManagedMarker = ''
        }
    )
    [System.IO.File]::WriteAllText(
        $runtimeMapPath,
        ($runtimePayload | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )

    $configText = @"
@{
    BindingProfilePath = $(Quote-Psd1String $bindingPath)
    RuntimeRoot = $(Quote-Psd1String $runtimeRoot)
    LogsRoot = $(Quote-Psd1String $logsRoot)
    RuntimeMapPath = $(Quote-Psd1String $runtimeMapPath)
    ShellPath = 'pwsh.exe'
    Targets = @(
        @{
            Id = 'target01'
            WindowTitle = 'target01 title'
        }
        @{
            Id = 'target02'
            WindowTitle = 'target02 title'
        }
    )
}
"@
    [System.IO.File]::WriteAllText($configPath, $configText, [System.Text.UTF8Encoding]::new($false))

    & $scriptPath -ConfigPath $configPath -TargetId 'target02' | Out-Null

    $after = @(Get-Content -LiteralPath $runtimeMapPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    $target01 = @($after | Where-Object { [string]$_.TargetId -eq 'target01' })[0]
    $target02 = @($after | Where-Object { [string]$_.TargetId -eq 'target02' })[0]
    $sessions = @(
        $after |
            ForEach-Object { [string]$_.LauncherSessionId } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    Assert-Equal 2 $after.Count 'runtime map count mismatch'
    Assert-Equal 'old-1001' $target01.Hwnd 'target01 row should be preserved'
    Assert-Equal 111 $target01.ShellPid 'target01 shell pid should be preserved'
    Assert-Equal 'session-keep' $target01.LauncherSessionId 'target01 session should be preserved'
    Assert-Equal ([string]$PID) $target02.ShellPid 'target02 shell pid should be refreshed from binding'
    Assert-Equal '1002' $target02.Hwnd 'target02 hwnd should be refreshed from binding'
    Assert-Equal 'session-keep' $target02.LauncherSessionId 'target02 should inherit preserved runtime session'
    Assert-Equal 1 $sessions.Count 'runtime map should keep one launcher session id'

    Write-Host 'attach targets from bindings target scope ok'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
