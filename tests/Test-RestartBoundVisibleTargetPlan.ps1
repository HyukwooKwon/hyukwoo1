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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('restart-bound-visible-target-' + [guid]::NewGuid().ToString('N'))
$workRepoRoot = Join-Path $tempRoot 'external-workrepo'
$bindingPath = Join-Path $tempRoot 'runtime\window-bindings\bottest-live-visible.json'
$configPath = Join-Path $tempRoot 'settings.bottest-live-visible.psd1'

try {
    New-Item -ItemType Directory -Path $workRepoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $bindingPath) -Force | Out-Null

    $bindingPayload = [ordered]@{
        profile_name = 'bottest-live-visible'
        target_dir = 'C:\old-root'
        launch_command = 'codex -a never -s danger-full-access'
        launcher_session_id = 'session-old'
        updated_at = '2026-06-29T00:00:00+09:00'
        windows = @(
            [ordered]@{
                target_id = 'target01'
                pair_id = 'pair01'
                role_name = 'top'
                base_title = 'BotTestLive-Window-01 | target01 | pair01-top'
                window_title = 'old-root'
                shell_pid = 1001
                window_pid = 2001
                hwnd = '3001'
                rect = @(0, 0, 640, 696)
                window_class = 'CASCADIA_HOSTING_WINDOW_CLASS'
                target_dir = 'C:\old-root'
            },
            [ordered]@{
                target_id = 'target02'
                pair_id = 'pair02'
                role_name = 'top'
                base_title = 'BotTestLive-Window-02 | target02 | pair02-top'
                window_title = 'old-root'
                shell_pid = 1002
                window_pid = 2002
                hwnd = '3002'
                rect = @(640, 0, 1280, 696)
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

    $configText = @"
@{
    LaneName = 'bottest-live-visible'
    WindowTitlePrefix = 'BotTestLive-Window'
    BindingProfilePath = $(Quote-Psd1String $bindingPath)
    Targets = @(
        @{
            Id = 'target01'
            WindowTitle = 'BotTestLive-Window-01'
        }
        @{
            Id = 'target02'
            WindowTitle = 'BotTestLive-Window-02'
        }
    )
}
"@
    [System.IO.File]::WriteAllText($configPath, $configText, [System.Text.UTF8Encoding]::new($false))

    $json = & $scriptPath -ConfigPath $configPath -TargetId 'target02' -WorkRepoRoot $workRepoRoot -AsJson
    $payload = $json | ConvertFrom-Json

    Assert-True $payload.Success 'plan should succeed'
    Assert-True (-not [bool]$payload.Apply) 'plan should not apply without -Apply'
    Assert-True ([bool]$payload.PlannedOnly) 'plan should mark PlannedOnly'
    Assert-Equal 'target02' $payload.TargetId 'target id mismatch'
    Assert-Equal 'pair02' $payload.PairId 'pair id mismatch'
    Assert-Equal 'top' $payload.RoleName 'role mismatch'
    Assert-Equal 'C:\old-root' $payload.OldTargetDir 'old target dir mismatch'
    Assert-Equal 'C:\old-root' $payload.OldTargetDirNormalized 'old target dir normalized mismatch'
    Assert-Equal ([System.IO.Path]::GetFullPath($workRepoRoot)) $payload.NewTargetDir 'new target dir mismatch'
    Assert-Equal ([System.IO.Path]::GetFullPath($workRepoRoot).TrimEnd('\', '/')) $payload.NewTargetDirNormalized 'new target dir normalized mismatch'
    Assert-True ([bool]$payload.TargetDirChanging) 'plan should mark target dir changing'
    Assert-Equal 'codex -a never -s danger-full-access' $payload.LaunchCommand 'launch command mismatch'
    Assert-Equal 'C:\old-root' $payload.TargetDirsBefore.target01 'target01 before dir mismatch'
    Assert-Equal 'C:\old-root' $payload.TargetDirsBefore.target02 'target02 before dir mismatch'
    Assert-True (-not [bool]$payload.MixedTargetDirsBefore) 'before dirs should not be mixed'
    Assert-Equal 'C:\old-root' $payload.TargetDirsAfter.target01 'target01 after dir mismatch'
    Assert-Equal ([System.IO.Path]::GetFullPath($workRepoRoot)) $payload.TargetDirsAfter.target02 'target02 after dir mismatch'
    Assert-True ([bool]$payload.MixedTargetDirsAfter) 'after dirs should be mixed'
    Assert-True (-not [bool]$payload.BindingUpdated) 'dry-run should not update binding'
    Assert-True (-not [bool]$payload.CloseRequested) 'dry-run should not request close'
    Assert-True (-not [bool]$payload.RuntimeAttachRequiredAfterApply) 'dry-run should not require runtime attach yet'
    Assert-Equal 'launcher/Attach-TargetsFromBindings.ps1 -TargetId target02' $payload.FollowUpAttachCommand 'follow-up attach command mismatch'
    Assert-True (-not [bool]$payload.AutoloopSafetyChecked) 'dry-run without status path should not check autoloop status'
    Assert-True ([bool]$payload.AutoloopSafetyAllowed) 'dry-run without status path should allow autoloop safety'
    Assert-Equal 'status-path-not-resolved' $payload.AutoloopSafetyReason 'autoloop safety reason mismatch'

    $afterBinding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $target02 = @($afterBinding.windows | Where-Object { [string]$_.target_id -eq 'target02' })[0]
    Assert-Equal 'C:\old-root' $target02.target_dir 'dry-run should preserve target02 target_dir'

    $blocked = $false
    try {
        & $scriptPath -ConfigPath $configPath -TargetId 'target02' -WorkRepoRoot $root -AsJson | Out-Null
    }
    catch {
        $blocked = $true
        Assert-True ($_.Exception.Message -like '*WorkRepoRoot must be outside automation repo*') 'automation repo block message mismatch'
    }
    Assert-True $blocked 'automation repo WorkRepoRoot should be blocked'

    Write-Host 'restart bound visible target plan ok'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
