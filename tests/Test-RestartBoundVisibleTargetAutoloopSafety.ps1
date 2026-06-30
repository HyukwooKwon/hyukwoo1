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
$scriptPath = Join-Path $root 'launcher\Restart-BoundVisibleTarget.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('restart-bound-visible-target-safety-' + [guid]::NewGuid().ToString('N'))
$workRepoRoot = Join-Path $tempRoot 'external-workrepo'
$bindingPath = Join-Path $tempRoot 'runtime\window-bindings\bottest-live-visible.json'
$statusPath = Join-Path $tempRoot 'run\.state\target-autoloop-status.json'
$configPath = Join-Path $tempRoot 'settings.bottest-live-visible.psd1'

try {
    New-Item -ItemType Directory -Path $workRepoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $bindingPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $statusPath) -Force | Out-Null

    $bindingPayload = [ordered]@{
        profile_name = 'bottest-live-visible'
        target_dir = 'C:\old-root'
        launch_command = 'codex -a never -s danger-full-access'
        windows = @(
            [ordered]@{
                target_id = 'target02'
                pair_id = 'pair01'
                role_name = 'bottom'
                base_title = 'BotTestLive-Window-02 | target02 | pair01-bottom'
                window_title = 'old-root'
                shell_pid = 1002
                window_pid = 2002
                hwnd = '3002'
                rect = @(0, 0, 640, 696)
                window_class = 'CASCADIA_HOSTING_WINDOW_CLASS'
                target_dir = 'C:\old-root'
            }
        )
    }
    [System.IO.File]::WriteAllText(
        $bindingPath,
        ($bindingPayload | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )

    $statusPayload = [ordered]@{
        WatcherState = 'running'
        ControllerState = 'running'
        WatcherTargetIds = @()
        Targets = @(
            [ordered]@{
                TargetId = 'target02'
                Phase = 'idle'
                LastDispatchState = ''
            }
        )
    }
    [System.IO.File]::WriteAllText(
        $statusPath,
        ($statusPayload | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )

    $configText = @"
@{
    LaneName = 'bottest-live-visible'
    WindowTitlePrefix = 'BotTestLive-Window'
    BindingProfilePath = $(Quote-Psd1String $bindingPath)
    Targets = @(
        @{
            Id = 'target02'
            WindowTitle = 'BotTestLive-Window-02'
        }
    )
}
"@
    [System.IO.File]::WriteAllText($configPath, $configText, [System.Text.UTF8Encoding]::new($false))

    $planJson = & $scriptPath `
        -ConfigPath $configPath `
        -TargetId 'target02' `
        -WorkRepoRoot $workRepoRoot `
        -AutoloopStatusPath $statusPath `
        -AsJson
    $plan = $planJson | ConvertFrom-Json
    Assert-True ([bool]$plan.PlannedOnly) 'dry-run should plan only'
    Assert-True ([bool]$plan.AutoloopSafetyChecked) 'dry-run should check provided status path'
    Assert-True (-not [bool]$plan.AutoloopSafetyAllowed) 'dry-run should report safety block'
    Assert-Equal 'fresh-running-watcher-scope-unknown' $plan.AutoloopSafetyReason 'safety reason mismatch'
    Assert-True (-not [bool]$plan.CloseRequested) 'dry-run should not close anything'
    Assert-True (-not [bool]$plan.BindingUpdated) 'dry-run should not update binding'

    $blocked = $false
    try {
        & $scriptPath `
            -ConfigPath $configPath `
            -TargetId 'target02' `
            -WorkRepoRoot $workRepoRoot `
            -AutoloopStatusPath $statusPath `
            -Apply `
            -AsJson | Out-Null
    }
    catch {
        $blocked = $true
        Assert-True ($_.Exception.Message -like '*Autoloop safety check blocked target restart*') 'apply safety block message mismatch'
        Assert-True ($_.Exception.Message -like '*fresh-running-watcher-scope-unknown*') 'apply safety reason missing'
    }
    Assert-True $blocked 'apply should be blocked before close/relaunch'

    Write-Host 'restart bound visible target autoloop safety ok'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
