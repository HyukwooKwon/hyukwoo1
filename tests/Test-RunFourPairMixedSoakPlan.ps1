[CmdletBinding()]
param(
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    $result = if ($Condition -is [System.Array]) {
        ($Condition.Count -gt 0)
    }
    else {
        [bool]$Condition
    }

    if (-not $result) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$plannedRunRoot = Join-Path $root ('_tmp\four-pair-soak-plan_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$powershellPath = (Get-Command -Name 'powershell.exe' -ErrorAction Stop | Select-Object -First 1).Source
$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\Run-FourPairMixedSoak.ps1'),
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $plannedRunRoot,
    '-AsJson'
)

$raw = & $powershellPath @arguments
if ($LASTEXITCODE -ne 0) {
    throw ("Run-FourPairMixedSoak.ps1 failed: " + (($raw | Out-String).Trim()))
}

$plan = ($raw | ConvertFrom-Json)
$stepIds = @($plan.PlanSteps | ForEach-Object { [string]$_.Id })

Assert-True ($plan.SchemaVersion -eq '1.0.0') 'SchemaVersion mismatch.'
Assert-True ($plan.ExecutionMode -eq 'plan') 'Expected default execution mode to be plan.'
Assert-True (-not [bool]$plan.AutoCloseoutConfirm) 'Expected auto closeout confirm to be disabled by default.'
Assert-True (-not [bool]$plan.KnownLimitationsReviewed) 'Expected known limitations reviewed flag to be false by default.'
Assert-True ([string]$plan.RunRoot -eq $plannedRunRoot) 'Expected planned run root to match requested run root.'
Assert-True (@($plan.SelectedPairs).Count -eq 4) 'Expected 4 selected pairs.'
Assert-True ($plan.PSObject.Properties['CloseoutThresholds'] -ne $null) 'Expected closeout thresholds in the wrapper plan.'
Assert-True ([int]$plan.CloseoutThresholds.MinRequiredSnapshotCount -eq 3) 'Expected minimum snapshot threshold.'
Assert-True ([int]$plan.CloseoutThresholds.MaxAllowedManualAttentionCount -eq 4) 'Expected default manual attention threshold.'
Assert-True ([string]$plan.CloseoutThresholds.RequiredFinalWatcherStatus -eq 'stopped') 'Expected required final watcher status threshold.'
Assert-True ([bool]$plan.SharedVisiblePolicy.ExecuteRequiresOfficialWindowsOnly) 'Expected official window requirement.'
Assert-True ([bool]$plan.SharedVisiblePolicy.OfficialWindowValidation.Passed) 'Expected official window validation to pass.'
Assert-True (@($plan.SharedVisiblePolicy.OfficialWindowValidation.OfficialWindowTitles).Count -eq 8) 'Expected 8 official shared visible windows.'
Assert-True ('BotTestLive-Window-01' -in @($plan.SharedVisiblePolicy.OfficialWindowValidation.OfficialWindowTitles)) 'Expected official window 01 in plan.'
Assert-True ('BotTestLive-Window-08' -in @($plan.SharedVisiblePolicy.OfficialWindowValidation.OfficialWindowTitles)) 'Expected official window 08 in plan.'
Assert-True ('BotTestLive-Fresh-*' -in @($plan.SharedVisiblePolicy.OfficialWindowValidation.ForbiddenWindowPatterns)) 'Expected forbidden ad-hoc window patterns.'
Assert-True ('cleanup-visible-queue' -in $stepIds) 'Expected cleanup step.'
Assert-True ('start-paired-exchange' -in $stepIds) 'Expected start paired exchange step.'
Assert-True ('preflight-pair01' -in $stepIds) 'Expected preflight for pair01.'
Assert-True ('preflight-pair04' -in $stepIds) 'Expected preflight for pair04.'
Assert-True ('seed-pair01' -in $stepIds) 'Expected seed for pair01.'
Assert-True ('seed-pair04' -in $stepIds) 'Expected seed for pair04.'
Assert-True ('start-watcher' -in $stepIds) 'Expected watcher start step.'
Assert-True ('watcher-pause' -in $stepIds) 'Expected pause step in default soak scenario.'
Assert-True ('watcher-resume' -in $stepIds) 'Expected resume step in default soak scenario.'
Assert-True ('watcher-restart' -in $stepIds) 'Expected restart step in default soak scenario.'
Assert-True ('snapshot-final' -in $stepIds) 'Expected final status snapshot step.'
Assert-True ('stop-watcher' -in $stepIds) 'Expected final watcher stop step.'
Assert-True ('post-cleanup-visible-queue' -in $stepIds) 'Expected post-cleanup step.'
Assert-True ([string]$plan.SoakProfile.PauseAfterMinutes -eq '15') 'Expected default pause timing.'
Assert-True ([string]$plan.SoakProfile.ResumeAfterMinutes -eq '18') 'Expected default resume timing.'
Assert-True ([string]$plan.SoakProfile.RestartAfterMinutes -eq '30') 'Expected default restart timing.'
Assert-True (($plan.RecommendedCommands.PlanOnly -like '*Run-FourPairMixedSoak.ps1*')) 'Expected plan command suggestion.'
Assert-True (($plan.RecommendedCommands.Execute -like '*-Execute*')) 'Expected execute command suggestion.'
Assert-True (($plan.RecommendedCommands.Closeout -like '*Confirm-FourPairMixedSoakCloseout.ps1*')) 'Expected closeout confirmation command suggestion.'
Assert-True (($plan.RecommendedCommands.ExecuteWithAutoCloseout -like '*-AutoCloseoutConfirm*')) 'Expected execute-with-auto-closeout command suggestion.'
Assert-True (@($plan.Execution.Records).Count -eq 0) 'Plan mode should not execute any steps.'
Assert-True (@($plan.Execution.Snapshots).Count -eq 0) 'Plan mode should not capture live snapshots.'

Write-Host ('run-four-pair-mixed-soak plan contract ok: runRoot=' + $plannedRunRoot)
