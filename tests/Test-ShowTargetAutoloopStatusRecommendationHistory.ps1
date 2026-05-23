[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopStatusRecommendationHistory'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_status_recommendation_history'
$historyPath = Join-Path $runRoot '.state\target-autoloop-recommendation-history.json'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$false
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('publish-ready'); PublishReadyDispatchDelaySeconds = 15 }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

try {
    $startJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -Targets target01 `
        -RunMode target-autoloop `
        -AsJson
    $start = $startJson | ConvertFrom-Json

    $status = Get-Content -LiteralPath $start.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $status.ControllerState = 'paused'
    $status.WatcherState = 'stopped'
    $status.WatcherStopReason = 'watcher-exited'
    $status.State = 'paused'
    $status.Targets[0].Phase = 'paused'
    $status.Targets[0].CycleCount = 3
    $status.Targets[0].MaxCycleCount = 10
    $status.Targets[0].NextAction = 'resume'
    $status.Targets[0].LastTriggerKind = 'publish-ready'
    $status.Targets[0].LastDispatchState = 'dispatch-delay-waiting'
    $status.LastUpdatedAt = (Get-Date).ToString('o')
    $status | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatusPath -Encoding UTF8

    $historyDocument = [ordered]@{
        History = @(
            [ordered]@{
                timestamp = '2026-05-11T12:00:00+09:00'
                label = 'watch restart 실패'
                action_key = 'start_watch'
                outcome = 'failed'
                run_root = 'C:\runs\other'
                watcher_health = 'stale'
                watcher_health_detail = '99s'
                detail = 'failed: watcher heartbeat timeout'
            }
            [ordered]@{
                timestamp = '2026-05-11T12:01:00+09:00'
                label = 'resume 요청'
                action_key = 'resume'
                outcome = 'requested'
                run_root = $runRoot
                watcher_health = 'stopped'
                watcher_health_detail = 'paused'
                detail = 'paused controller'
            }
            [ordered]@{
                timestamp = '2026-05-11T12:02:00+09:00'
                label = 'resume 요청 실패'
                action_key = 'resume'
                outcome = 'failed'
                run_root = $runRoot
                watcher_health = 'stopped'
                watcher_health_detail = 'paused'
                detail = 'failed: resume ack timeout'
            }
        )
    }
    [System.IO.File]::WriteAllText(
        $historyPath,
        ($historyDocument | ConvertTo-Json -Depth 8),
        (New-Utf8NoBomEncoding)
    )

    $statusJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -AsJson | ConvertFrom-Json

    Assert-True ([string]$statusJson.RecentRecommendationAction -eq 'resume') 'status json should surface latest recommendation action.'
    Assert-True ([string]$statusJson.RecentRecommendationOutcome -eq 'failed') 'status json should surface latest recommendation outcome.'
    Assert-True ([string]$statusJson.RecentRecommendation.Label -eq 'resume 요청 실패') 'status json should surface latest recommendation label.'
    Assert-True ([string]$statusJson.RecommendationActionKey -eq 'resume') 'status json should surface the current recommendation action key.'
    Assert-True ([string]$statusJson.RecommendationMode -eq 'mutating') 'status json should surface the current recommendation mode.'
    Assert-True ([string]$statusJson.RecommendationLevel -eq 'normal') 'status json should surface the current recommendation level.'
    Assert-True ([string]$statusJson.RecommendationLabel -eq 'resume 재요청') 'status json should surface the retry-aware recommendation label.'
    Assert-True ([string]$statusJson.RecommendationDetail -match '이전 실패: failed: resume ack timeout') 'status json should surface the retry-aware recommendation detail.'
    Assert-True ((@($statusJson.RecommendationDetailSections)).Count -eq 2) 'status json should surface structured recommendation detail sections.'
    Assert-True ([string]$statusJson.RecommendationDetailSections[1] -match '^이번 조치: controller는 paused이고 watcher는 stopped입니다\.') 'status json should preserve the current recommendation meaning separately.'
    Assert-True ([bool]$statusJson.RecommendationReadOnly -eq $false) 'status json should indicate that retrying resume is not read-only.'
    Assert-True ([string]$statusJson.RecommendationRetryBadge.State -eq 'failed') 'status json should surface the retry reason badge state.'
    Assert-True ([string]$statusJson.RecommendationRetryBadge.Tone -eq 'danger') 'status json should surface the retry reason badge tone.'
    Assert-True ([string]$statusJson.RecommendationRetryBadge.Text -match '재시도 사유: 이전 실패 / failed: resume ack timeout') 'status json should surface the retry reason badge text.'
    Assert-True ([string]$statusJson.RecentRecommendationBadge.State -eq 'failed') 'status json should surface the recent result badge state.'
    Assert-True ([string]$statusJson.RecentRecommendationBadge.Tone -eq 'danger') 'status json should surface the recent result badge tone.'
    Assert-True ([string]$statusJson.RecentRecommendationBadge.Text -match '최근 결과: 실패 / resume 요청 실패') 'status json should surface badge-friendly recent result text.'
    Assert-True ((@($statusJson.RecommendationHistory)).Count -eq 2) 'status json should filter recommendation history to the current runroot.'
    Assert-True ([string]$statusJson.RecommendationHistory[0].RunRoot -eq $runRoot) 'status json should keep only matching runroot records.'
    Assert-True ([string]$statusJson.RecommendationHistory[1].Outcome -eq 'failed') 'status json should preserve the latest recommendation outcome.'
    Assert-True ([string]$statusJson.RecommendationHistorySummary -eq '권장 이력: 2건 (마지막=resume 요청 실패 @ 2026-05-11T12:02:00+09:00)') 'status json should surface the filtered recommendation history summary.'
    Assert-True ([string]$statusJson.RecommendationHistoryWarning -eq '') 'status json should not emit a warning for a valid recommendation history file.'

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot
    $joined = (@($output) -join "`n")

    Assert-True ($joined -match 'Counts: .*recAction=resume .*recOutcome=failed') 'status text should surface latest recommendation action and outcome.'
    Assert-True ($joined -match 'Counts: .*recMode=mutating .*recKey=resume') 'status text should surface current recommendation mode and key.'
    Assert-True ($joined -match 'Counts: .*recLevel=normal .*recKey=resume') 'status text should surface current recommendation level and key.'
    Assert-True ($joined -match 'RecommendationAction: resume') 'status text should surface the current recommendation action.'
    Assert-True ($joined -match 'RecommendationMode: mutating') 'status text should surface the current recommendation mode.'
    Assert-True ($joined -match 'RecommendationLevel: normal') 'status text should surface the current recommendation level.'
    Assert-True ($joined -match 'RecommendationLabel: resume 재요청') 'status text should surface the retry-aware recommendation label.'
    Assert-True ($joined -match 'RecommendationDetail: 이전 실패: failed: resume ack timeout / 이번 조치: controller는 paused이고 watcher는 stopped입니다\.') 'status text should surface the retry-aware recommendation detail.'
    Assert-True ($joined -match 'RecommendationRetryBadge: 재시도 사유: 이전 실패 / failed: resume ack timeout') 'status text should surface the retry reason badge text.'
    Assert-True ($joined -match 'RecommendationHistorySummary: 권장 이력: 2건 \(마지막=resume 요청 실패 @ 2026-05-11T12:02:00\+09:00\)') 'status text should surface the filtered recommendation history summary.'
    Assert-True ($joined -notmatch 'watch restart 실패') 'status text should not include recommendation history from another runroot.'
}
finally {
    if (Test-Path -LiteralPath $historyPath -PathType Leaf) {
        Remove-Item -LiteralPath $historyPath -Force
    }
}

Write-Host 'show target autoloop status recommendation history ok'
