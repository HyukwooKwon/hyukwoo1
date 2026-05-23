[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')

function Get-TargetAutoloopRemainingDelayLabel {
    param([string]$EligibleAt)

    if (-not (Test-NonEmptyString $EligibleAt)) {
        return ''
    }

    $eligibleAtValue = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($EligibleAt, [ref]$eligibleAtValue)) {
        return ''
    }

    $remainingSeconds = [int][math]::Ceiling(($eligibleAtValue - [datetimeoffset]::Now).TotalSeconds)
    if ($remainingSeconds -le 0) {
        return ''
    }

    return ('remaining: {0}s' -f $remainingSeconds)
}

function Get-TargetAutoloopCompactText {
    param(
        [AllowEmptyString()][string]$Value,
        [int]$MaxChars = 96
    )

    $text = [regex]::Replace([string]$Value, '\s+', ' ').Trim()
    if ($text.Length -gt $MaxChars) {
        return ($text.Substring(0, [Math]::Max(0, $MaxChars - 3)) + '...')
    }
    return $text
}

function Get-TargetAutoloopWatcherHealthSummary {
    param(
        [string]$WatcherState,
        [string]$HeartbeatAt,
        [string]$LastUpdatedAt,
        [int]$StaleAfterSeconds = 15
    )

    $normalizedWatcherState = [string]$WatcherState
    $timestampText = if (Test-NonEmptyString $HeartbeatAt) { [string]$HeartbeatAt } else { [string]$LastUpdatedAt }
    $ageSeconds = $null
    if (Test-NonEmptyString $timestampText) {
        $timestampValue = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($timestampText, [ref]$timestampValue)) {
            $ageSeconds = [int][math]::Max([math]::Floor(([datetimeoffset]::Now - $timestampValue).TotalSeconds), 0)
        }
    }

    if ($normalizedWatcherState -in @('running', 'paused')) {
        if ($null -ne $ageSeconds -and $ageSeconds -le [math]::Max(5, $StaleAfterSeconds)) {
            return [pscustomobject]@{
                Health = 'active'
                Detail = ('{0}s' -f $ageSeconds)
                Recommendation = if ($normalizedWatcherState -eq 'paused') { 'paused 상태입니다. resume 또는 stop을 선택하세요.' } else { 'watcher가 정상 heartbeat를 보내고 있습니다.' }
            }
        }
        return [pscustomobject]@{
            Health = 'stale'
            Detail = if ($null -ne $ageSeconds) { ('{0}s' -f $ageSeconds) } else { 'unknown' }
            Recommendation = 'heartbeat가 stale입니다. watch start/restart 후 stderr 로그를 먼저 확인하세요.'
        }
    }
    if ($normalizedWatcherState -eq 'stopped') {
        return [pscustomobject]@{
            Health = 'stopped'
            Detail = 'stopped'
            Recommendation = 'watcher가 stopped입니다. watch start/restart가 필요합니다.'
        }
    }

    return [pscustomobject]@{
        Health = 'missing'
        Detail = 'status-missing'
        Recommendation = 'status가 없거나 watcher 메타데이터가 비어 있습니다. watch start로 초기화하세요.'
    }
}

function Get-TargetAutoloopRecommendationHistoryPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$RunRoot = ''
    )

    if (Test-NonEmptyString $RunRoot) {
        return (Join-Path (Join-Path $RunRoot '.state') 'target-autoloop-recommendation-history.json')
    }
    return (Join-Path (Join-Path $Root '_tmp') 'target-autoloop-recommendation-history.json')
}

function Get-TargetAutoloopRecommendationHistoryCandidatePaths {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RunRoot
    )

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
            (Get-TargetAutoloopRecommendationHistoryPath -Root $Root -RunRoot $RunRoot),
            (Get-TargetAutoloopRecommendationHistoryPath -Root $Root)
        )) {
        if (-not (Test-NonEmptyString ([string]$candidate))) {
            continue
        }
        $normalizedCandidate = Get-NormalizedFullPath -Path ([string]$candidate)
        $alreadyAdded = $false
        foreach ($existingPath in @($paths)) {
            if ((Get-NormalizedFullPath -Path ([string]$existingPath)) -eq $normalizedCandidate) {
                $alreadyAdded = $true
                break
            }
        }
        if (-not $alreadyAdded) {
            [void]$paths.Add([string]$candidate)
        }
    }
    return @($paths.ToArray())
}

function Get-TargetAutoloopRecommendationHistorySnapshot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RunRoot
    )

    $historyPath = ''
    foreach ($candidatePath in @(Get-TargetAutoloopRecommendationHistoryCandidatePaths -Root $Root -RunRoot $RunRoot)) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $historyPath = [string]$candidatePath
            break
        }
    }
    if (-not (Test-NonEmptyString $historyPath)) {
        $historyPath = [string](Get-TargetAutoloopRecommendationHistoryPath -Root $Root -RunRoot $RunRoot)
    }
    $result = [ordered]@{
        Path = [string]$historyPath
        Summary = '권장 이력: (없음)'
        Warning = ''
        Recent = $null
        History = @()
    }

    if (-not (Test-Path -LiteralPath $historyPath -PathType Leaf)) {
        return [pscustomobject]$result
    }

    try {
        $raw = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8
    }
    catch {
        $result.Warning = ('target-autoloop-history read failed: ' + $_.Exception.Message)
        return [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]$result
    }

    try {
        $payload = $raw | ConvertFrom-Json
    }
    catch {
        $result.Warning = ('target-autoloop-history parse failed: ' + $_.Exception.Message)
        return [pscustomobject]$result
    }

    $historyPayload = Get-ConfigValue -Object $payload -Name 'History' -DefaultValue $payload
    if ($historyPayload -isnot [System.Collections.IEnumerable]) {
        $result.Warning = ('target-autoloop-history payload is invalid: ' + [string]$historyPath)
        return [pscustomobject]$result
    }

    $normalizedRunRoot = Get-NormalizedFullPath -Path $RunRoot
    $history = @()
    foreach ($item in @($historyPayload)) {
        if ($null -eq $item) {
            continue
        }
        $itemRunRoot = [string](Get-ConfigValue -Object $item -Name 'run_root' -DefaultValue '')
        if (Test-NonEmptyString $normalizedRunRoot) {
            if ((Get-NormalizedFullPath -Path $itemRunRoot) -ne $normalizedRunRoot) {
                continue
            }
        }
        $history += [pscustomobject][ordered]@{
            Timestamp = [string](Get-ConfigValue -Object $item -Name 'timestamp' -DefaultValue '')
            Label = [string](Get-ConfigValue -Object $item -Name 'label' -DefaultValue '권장 조치')
            ActionKey = [string](Get-ConfigValue -Object $item -Name 'action_key' -DefaultValue '')
            Outcome = [string](Get-ConfigValue -Object $item -Name 'outcome' -DefaultValue 'requested')
            RunRoot = $itemRunRoot
            WatcherHealth = [string](Get-ConfigValue -Object $item -Name 'watcher_health' -DefaultValue '')
            WatcherHealthDetail = [string](Get-ConfigValue -Object $item -Name 'watcher_health_detail' -DefaultValue '')
            Detail = [string](Get-ConfigValue -Object $item -Name 'detail' -DefaultValue '')
        }
    }

    $history = @($history | Select-Object -Last 6)
    $result.History = $history
    if ($history.Count -gt 0) {
        $recent = $history[-1]
        $result.Recent = $recent
        $result.Summary = ('권장 이력: {0}건 (마지막={1} @ {2})' -f $history.Count, [string]$recent.Label, [string]$recent.Timestamp)
    }
    return [pscustomobject]$result
}

function Get-TargetAutoloopRecentRecommendationBadge {
    param($RecentRecommendation)

    if ($null -eq $RecentRecommendation) {
        return [pscustomobject]@{
            State = 'none'
            Tone = 'neutral'
            OutcomeLabel = '(없음)'
            Text = '최근 결과: (없음)'
        }
    }

    $label = [string](Get-ConfigValue -Object $RecentRecommendation -Name 'Label' -DefaultValue '권장 조치')
    $outcome = [string](Get-ConfigValue -Object $RecentRecommendation -Name 'Outcome' -DefaultValue 'requested')
    $detail = Get-TargetAutoloopCompactText -Value ([string](Get-ConfigValue -Object $RecentRecommendation -Name 'Detail' -DefaultValue ''))
    $state = if (Test-NonEmptyString $outcome) { $outcome.ToLowerInvariant() } else { 'none' }

    $outcomeLabel = '상태'
    $tone = 'neutral'
    switch ($state) {
        'failed' {
            $outcomeLabel = '실패'
            $tone = 'danger'
        }
        'blocked' {
            $outcomeLabel = '차단'
            $tone = 'warning'
        }
        'ack' {
            $outcomeLabel = '확인'
            $tone = 'success'
        }
        'opened' {
            $outcomeLabel = '열람'
            $tone = 'muted'
        }
        'requested' {
            $outcomeLabel = '요청'
            $tone = 'info'
        }
        default {
            $outcomeLabel = '상태'
            $tone = 'neutral'
        }
    }

    $text = ('최근 결과: {0} / {1}' -f $outcomeLabel, $label)
    if (Test-NonEmptyString $detail) {
        $text += (' / ' + $detail)
    }

    return [pscustomobject]@{
        State = $state
        Tone = $tone
        OutcomeLabel = $outcomeLabel
        Text = $text
    }
}

function Get-TargetAutoloopRetryRecommendationLabel {
    param(
        [AllowEmptyString()][string]$Label,
        [AllowEmptyString()][string]$ActionKey
    )

    $normalizedLabel = [string]$Label
    $normalizedActionKey = [string]$ActionKey
    if (-not (Test-NonEmptyString $normalizedLabel)) {
        return $normalizedLabel
    }
    if ($normalizedActionKey -eq 'open_stderr_log') {
        return 'stderr 다시 열기'
    }
    if ($normalizedLabel.EndsWith('요청')) {
        return ($normalizedLabel.Substring(0, $normalizedLabel.Length - 2) + '재요청')
    }
    if ($normalizedLabel.EndsWith('재시도') -or $normalizedLabel.EndsWith('재요청')) {
        return $normalizedLabel
    }
    return ($normalizedLabel + ' 재시도')
}

function Get-TargetAutoloopRecommendationDetailSections {
    param(
        [AllowEmptyString()][string]$BaseDetail,
        [AllowEmptyString()][string]$LatestOutcome,
        [AllowEmptyString()][string]$LatestDetail
    )

    $normalizedBaseDetail = [string]$BaseDetail
    $normalizedLatestOutcome = ([string]$LatestOutcome).ToLowerInvariant()
    $normalizedLatestDetail = [string]$LatestDetail
    if ($normalizedLatestOutcome -notin @('failed', 'blocked')) {
        if (Test-NonEmptyString $normalizedBaseDetail) {
            return @($normalizedBaseDetail)
        }
        return @()
    }

    $outcomeLabel = if ($normalizedLatestOutcome -eq 'failed') { '실패' } else { '차단' }
    $sections = @()
    if (Test-NonEmptyString $normalizedLatestDetail) {
        $sections += ('이전 {0}: {1}' -f $outcomeLabel, $normalizedLatestDetail)
    }
    else {
        $sections += ('이전 {0}' -f $outcomeLabel)
    }
    if (Test-NonEmptyString $normalizedBaseDetail) {
        $sections += ('이번 조치: ' + $normalizedBaseDetail)
    }
    return @($sections)
}

function Get-TargetAutoloopRetryReasonBadge {
    param($RecommendationSpec)

    if ($null -eq $RecommendationSpec) {
        return [pscustomobject]@{
            State = 'none'
            Tone = 'neutral'
            Text = '재시도 사유: (없음)'
        }
    }

    $retryOutcome = ([string](Get-ConfigValue -Object $RecommendationSpec -Name 'RetryOutcome' -DefaultValue '')).ToLowerInvariant()
    $retryDetail = Get-TargetAutoloopCompactText -Value ([string](Get-ConfigValue -Object $RecommendationSpec -Name 'RetryDetail' -DefaultValue '')) -MaxChars 88
    if ($retryOutcome -eq 'failed') {
        $text = '재시도 사유: 이전 실패'
        if (Test-NonEmptyString $retryDetail) {
            $text += (' / ' + $retryDetail)
        }
        return [pscustomobject]@{
            State = 'failed'
            Tone = 'danger'
            Text = $text
        }
    }
    if ($retryOutcome -eq 'blocked') {
        $text = '재시도 사유: 이전 차단'
        if (Test-NonEmptyString $retryDetail) {
            $text += (' / ' + $retryDetail)
        }
        return [pscustomobject]@{
            State = 'blocked'
            Tone = 'warning'
            Text = $text
        }
    }
    return [pscustomobject]@{
        State = 'none'
        Tone = 'neutral'
        Text = '재시도 사유: (없음)'
    }
}

function Get-TargetAutoloopRecommendationMode {
    param($RecommendationSpec)

    $actionKey = [string](Get-ConfigValue -Object $RecommendationSpec -Name 'ActionKey' -DefaultValue '')
    if (-not (Test-NonEmptyString $actionKey)) {
        return 'none'
    }
    if ([bool](Get-ConfigValue -Object $RecommendationSpec -Name 'ReadOnly' -DefaultValue $false)) {
        return 'read-only'
    }
    return 'mutating'
}

function Get-TargetAutoloopRecommendationLevel {
    param($RecommendationSpec)

    $actionKey = [string](Get-ConfigValue -Object $RecommendationSpec -Name 'ActionKey' -DefaultValue '')
    if (-not (Test-NonEmptyString $actionKey)) {
        return 'none'
    }
    if ([bool](Get-ConfigValue -Object $RecommendationSpec -Name 'ReadOnly' -DefaultValue $false)) {
        return 'safe'
    }
    if ($actionKey -in @('stop', 'force_restart', 'force_stop')) {
        return 'danger'
    }
    return 'normal'
}

function Get-TargetAutoloopControlEligibility {
    param(
        [Parameter(Mandatory)][string]$Action,
        [AllowEmptyString()][string]$ControllerState,
        [AllowEmptyString()][string]$PendingAction
    )

    if (Test-NonEmptyString $PendingAction) {
        if ($PendingAction -eq $Action) {
            return [pscustomobject]@{ Allowed = $false; Detail = ('이미 target-autoloop {0} 요청이 진행 중입니다.' -f $Action) }
        }
        return [pscustomobject]@{ Allowed = $false; Detail = ('다른 target-autoloop 제어 요청({0})이 이미 진행 중입니다.' -f $PendingAction) }
    }

    if ($Action -eq 'pause') {
        if ($ControllerState -eq 'paused') {
            return [pscustomobject]@{ Allowed = $false; Detail = '현재 target-autoloop이 이미 paused 상태입니다.' }
        }
        if ($ControllerState -eq 'stopped') {
            return [pscustomobject]@{ Allowed = $false; Detail = 'stopped 상태에서는 pause가 아니라 restart가 필요합니다.' }
        }
        if ($ControllerState -ne 'running') {
            return [pscustomobject]@{ Allowed = $false; Detail = ('현재 target-autoloop controller 상태가 running이 아닙니다: {0}' -f $(if (Test-NonEmptyString $ControllerState) { $ControllerState } else { '-' })) }
        }
    }
    elseif ($Action -eq 'resume') {
        if ($ControllerState -eq 'running') {
            return [pscustomobject]@{ Allowed = $false; Detail = '현재 target-autoloop이 이미 running 상태입니다.' }
        }
        if ($ControllerState -eq 'stopped') {
            return [pscustomobject]@{ Allowed = $false; Detail = 'stopped 상태에서는 resume이 아니라 restart가 필요합니다.' }
        }
        if ($ControllerState -ne 'paused') {
            return [pscustomobject]@{ Allowed = $false; Detail = ('현재 target-autoloop controller 상태가 paused가 아닙니다: {0}' -f $(if (Test-NonEmptyString $ControllerState) { $ControllerState } else { '-' })) }
        }
    }
    elseif ($Action -eq 'stop') {
        if ($ControllerState -eq 'stopped') {
            return [pscustomobject]@{ Allowed = $false; Detail = '현재 target-autoloop이 이미 stopped 상태입니다.' }
        }
    }

    return [pscustomobject]@{ Allowed = $true; Detail = '' }
}

function Get-TargetAutoloopStartEligibility {
    param(
        [AllowEmptyString()][string]$PendingAction,
        [AllowEmptyString()][string]$WatcherHealth,
        [AllowEmptyString()][string]$WatcherState
    )

    if (Test-NonEmptyString $PendingAction) {
        return [pscustomobject]@{ Allowed = $false; Detail = ('target-autoloop 제어 요청({0})이 처리 중이라 watcher 시작을 막았습니다.' -f $PendingAction) }
    }
    if ($WatcherHealth -eq 'active') {
        return [pscustomobject]@{ Allowed = $false; Detail = ('현재 target-autoloop watcher가 이미 active 상태입니다: {0}' -f $(if (Test-NonEmptyString $WatcherState) { $WatcherState } else { 'running' })) }
    }
    return [pscustomobject]@{ Allowed = $true; Detail = '' }
}

function Get-TargetAutoloopCurrentRecommendationSpec {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ControllerState,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WatcherState,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WatcherHealth,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WatcherHealthDetail,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WatcherRecommendation,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PendingAction,
        $RecentRecommendation
    )

    $stateRoot = Join-Path $RunRoot '.state'
    $stderrPath = Join-Path $stateRoot 'target-autoloop-watcher.stderr.log'
    $stderrExists = Test-Path -LiteralPath $stderrPath -PathType Leaf
    $startEligibility = Get-TargetAutoloopStartEligibility -PendingAction $PendingAction -WatcherHealth $WatcherHealth -WatcherState $WatcherState
    $resumeEligibility = Get-TargetAutoloopControlEligibility -Action 'resume' -ControllerState $ControllerState -PendingAction $PendingAction

    $label = '권장 조치 없음'
    $actionKey = ''
    $detail = [string]$WatcherRecommendation
    $detailSections = if (Test-NonEmptyString $detail) { @($detail) } else { @() }
    $readOnly = $false
    $retryOutcome = ''
    $retryDetail = ''

    if ($WatcherHealth -eq 'stale') {
        if ($stderrExists) {
            $label = 'stderr 우선 열기'
            $actionKey = 'open_stderr_log'
            $readOnly = $true
            $detail = ('watcher stale ({0}) 상태입니다. stderr 로그를 먼저 열어 원인을 확인한 뒤 watch restart를 진행하세요.' -f $(if (Test-NonEmptyString $WatcherHealthDetail) { $WatcherHealthDetail } else { 'unknown' }))
        }
        elseif ([bool](Get-ConfigValue -Object $startEligibility -Name 'Allowed' -DefaultValue $false)) {
            $label = 'watch restart'
            $actionKey = 'start_watch'
            $detail = ('watcher stale ({0}) 상태입니다. 로그가 없으므로 restart로 heartbeat를 다시 세우는 편이 안전합니다.' -f $(if (Test-NonEmptyString $WatcherHealthDetail) { $WatcherHealthDetail } else { 'unknown' }))
        }
    }
    elseif ($WatcherHealth -eq 'stopped') {
        if ($ControllerState -eq 'paused' -and [bool](Get-ConfigValue -Object $resumeEligibility -Name 'Allowed' -DefaultValue $false)) {
            $label = 'resume 요청'
            $actionKey = 'resume'
            $detail = 'controller는 paused이고 watcher는 stopped입니다. resume으로 queued/pending 흐름을 다시 이어보세요.'
        }
        elseif ([bool](Get-ConfigValue -Object $startEligibility -Name 'Allowed' -DefaultValue $false)) {
            $label = if ($ControllerState -eq 'stopped') { 'watch restart' } else { 'watch start' }
            $actionKey = 'start_watch'
            $detail = 'watcher가 stopped 상태입니다. '
            if ($ControllerState -eq 'stopped') {
                $detail += 'controller도 stopped라 restart가 필요합니다.'
            }
            else {
                $detail += 'watch start로 다시 올리세요.'
            }
        }
    }
    elseif ($WatcherState -eq 'paused' -and [bool](Get-ConfigValue -Object $resumeEligibility -Name 'Allowed' -DefaultValue $false)) {
        $label = 'resume 요청'
        $actionKey = 'resume'
        $detail = 'watcher가 paused 상태입니다. resume 요청으로 현재 queued/pending 흐름을 이어가세요.'
    }

    $detailSections = if (Test-NonEmptyString $detail) { @($detail) } else { @() }
    $latestOutcome = ([string](Get-ConfigValue -Object $RecentRecommendation -Name 'Outcome' -DefaultValue '')).ToLowerInvariant()
    $latestActionKey = [string](Get-ConfigValue -Object $RecentRecommendation -Name 'ActionKey' -DefaultValue '')
    $latestDetail = Get-TargetAutoloopCompactText -Value ([string](Get-ConfigValue -Object $RecentRecommendation -Name 'Detail' -DefaultValue '')) -MaxChars 120
    if ((Test-NonEmptyString $actionKey) -and ($latestActionKey -eq $actionKey) -and ($latestOutcome -in @('failed', 'blocked'))) {
        $label = Get-TargetAutoloopRetryRecommendationLabel -Label $label -ActionKey $actionKey
        $detailSections = @(Get-TargetAutoloopRecommendationDetailSections -BaseDetail $detail -LatestOutcome $latestOutcome -LatestDetail $latestDetail)
        $detail = ($detailSections -join ' / ')
        $retryOutcome = $latestOutcome
        $retryDetail = $latestDetail
    }

    return [pscustomobject]@{
        Label = $label
        ActionKey = $actionKey
        Detail = $detail
        DetailSections = @($detailSections)
        ReadOnly = [bool]$readOnly
        RetryOutcome = $retryOutcome
        RetryDetail = $retryDetail
        StderrPath = [string]$stderrPath
        StderrExists = [bool]$stderrExists
    }
}

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
$resolvedRunRoot = Resolve-TargetAutoloopRunRoot -Config $config -RequestedRunRoot $RunRoot
$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config

$stateDocument = Read-JsonObject -Path $statePaths.StatePath
$controlDocument = Read-JsonObject -Path $statePaths.ControlPath
$statusDocument = if (Test-Path -LiteralPath $statePaths.StatusPath -PathType Leaf) {
    Read-JsonObject -Path $statePaths.StatusPath
}
else {
    New-TargetAutoloopStatusDocument -Config $config -RunRoot $resolvedRunRoot -StateDocument $stateDocument -ControlDocument $controlDocument
}

$payload = [pscustomobject][ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    ConfigPath = [string]$config.ConfigPath
    RunMode = [string](Get-ConfigValue -Object $statusDocument -Name 'RunMode' -DefaultValue ([string]$config.RunMode))
    RunRoot = $resolvedRunRoot
    ControllerState = [string](Get-ConfigValue -Object $statusDocument -Name 'ControllerState' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue '')))
    ControlPendingAction = [string](Get-ConfigValue -Object $statusDocument -Name 'ControlPendingAction' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'Action' -DefaultValue '')))
    ControlPendingRequestId = [string](Get-ConfigValue -Object $statusDocument -Name 'ControlPendingRequestId' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'RequestId' -DefaultValue '')))
    ControlRequestedAt = [string](Get-ConfigValue -Object $statusDocument -Name 'ControlRequestedAt' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'RequestedAt' -DefaultValue '')))
    ControlRequestedBy = [string](Get-ConfigValue -Object $statusDocument -Name 'ControlRequestedBy' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'RequestedBy' -DefaultValue '')))
    LastHandledRequestId = [string](Get-ConfigValue -Object $statusDocument -Name 'LastHandledRequestId' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledRequestId' -DefaultValue '')))
    LastHandledAction = [string](Get-ConfigValue -Object $statusDocument -Name 'LastHandledAction' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledAction' -DefaultValue '')))
    LastHandledResult = [string](Get-ConfigValue -Object $statusDocument -Name 'LastHandledResult' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledResult' -DefaultValue '')))
    LastHandledAt = [string](Get-ConfigValue -Object $statusDocument -Name 'LastHandledAt' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledAt' -DefaultValue '')))
    WatcherState = [string](Get-ConfigValue -Object $statusDocument -Name 'WatcherState' -DefaultValue '')
    WatcherStopReason = [string](Get-ConfigValue -Object $statusDocument -Name 'WatcherStopReason' -DefaultValue '')
    WatcherMutexName = [string](Get-ConfigValue -Object $statusDocument -Name 'WatcherMutexName' -DefaultValue '')
    HeartbeatAt = [string](Get-ConfigValue -Object $statusDocument -Name 'HeartbeatAt' -DefaultValue '')
    ProcessStartedAt = [string](Get-ConfigValue -Object $statusDocument -Name 'ProcessStartedAt' -DefaultValue '')
    ConfiguredRunDurationSec = [int](Get-ConfigValue -Object $statusDocument -Name 'ConfiguredRunDurationSec' -DefaultValue 0)
    State = [string](Get-ConfigValue -Object $statusDocument -Name 'State' -DefaultValue '')
    Counts = Get-ConfigValue -Object $statusDocument -Name 'Counts' -DefaultValue @{}
    DelaySummary = Get-ConfigValue -Object $statusDocument -Name 'DelaySummary' -DefaultValue $null
    Targets = @(Get-ConfigValue -Object $statusDocument -Name 'Targets' -DefaultValue @())
    ModeCapabilities = Get-ConfigValue -Object $statusDocument -Name 'ModeCapabilities' -DefaultValue @{}
    StatePath = [string]$statePaths.StatePath
    StatusPath = [string]$statePaths.StatusPath
    ControlPath = [string]$statePaths.ControlPath
    EventsPath = [string]$statePaths.EventsPath
}

$delaySummary = Get-TargetAutoloopDelaySummary -TargetRows @($payload.Targets)
$payload.DelaySummary = $delaySummary
if (-not (Test-NonEmptyString ([string]$payload.ControlPendingAction))) {
    $payload.ControlPendingAction = [string](Get-ConfigValue -Object $controlDocument -Name 'Action' -DefaultValue '')
}
if (-not (Test-NonEmptyString ([string]$payload.ControlPendingRequestId))) {
    $payload.ControlPendingRequestId = [string](Get-ConfigValue -Object $controlDocument -Name 'RequestId' -DefaultValue '')
}
if (-not (Test-NonEmptyString ([string]$payload.ControlRequestedAt))) {
    $payload.ControlRequestedAt = [string](Get-ConfigValue -Object $controlDocument -Name 'RequestedAt' -DefaultValue '')
}
if (-not (Test-NonEmptyString ([string]$payload.ControlRequestedBy))) {
    $payload.ControlRequestedBy = [string](Get-ConfigValue -Object $controlDocument -Name 'RequestedBy' -DefaultValue '')
}
if (-not (Test-NonEmptyString ([string]$payload.LastHandledRequestId))) {
    $payload.LastHandledRequestId = [string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledRequestId' -DefaultValue '')
}
if (-not (Test-NonEmptyString ([string]$payload.LastHandledAction))) {
    $payload.LastHandledAction = [string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledAction' -DefaultValue '')
}
if (-not (Test-NonEmptyString ([string]$payload.LastHandledResult))) {
    $payload.LastHandledResult = [string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledResult' -DefaultValue '')
}
if (-not (Test-NonEmptyString ([string]$payload.LastHandledAt))) {
    $payload.LastHandledAt = [string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledAt' -DefaultValue '')
}
$delayState = [string](Get-ConfigValue -Object $delaySummary -Name 'State' -DefaultValue 'none')
$minimumRemainingSeconds = Get-ConfigValue -Object $delaySummary -Name 'MinRemainingSeconds' -DefaultValue $null
$minimumRemainingTargetId = [string](Get-ConfigValue -Object $delaySummary -Name 'TargetId' -DefaultValue '')
$minimumRemainingDelayRangeLabel = [string](Get-ConfigValue -Object $delaySummary -Name 'DelayRange' -DefaultValue '')
$minimumRemainingEligibleAt = [string](Get-ConfigValue -Object $delaySummary -Name 'DueAt' -DefaultValue '')
$controlPendingAction = [string]$payload.ControlPendingAction
$controlPendingRequestId = [string]$payload.ControlPendingRequestId
$lastHandledAction = [string]$payload.LastHandledAction
$lastHandledResult = [string]$payload.LastHandledResult
$lastHandledRequestId = [string]$payload.LastHandledRequestId
$watcherState = [string](Get-ConfigValue -Object $payload -Name 'WatcherState' -DefaultValue '')
$watcherStopReason = [string](Get-ConfigValue -Object $payload -Name 'WatcherStopReason' -DefaultValue '')
$modeCapabilities = Get-ConfigValue -Object $payload -Name 'ModeCapabilities' -DefaultValue @{}
$maxConcurrentTargets = [int](Get-ConfigValue -Object $modeCapabilities -Name 'MaxConcurrentTargets' -DefaultValue ([int]$config.MaxConcurrentTargets))
$maxConcurrentSubmits = [int](Get-ConfigValue -Object $modeCapabilities -Name 'MaxConcurrentSubmits' -DefaultValue ([int]$config.MaxConcurrentSubmits))
$typedWindowDispatch = [bool](Get-ConfigValue -Object $modeCapabilities -Name 'TypedWindowDispatch' -DefaultValue $false)
$routerReadyDispatch = [bool](Get-ConfigValue -Object $modeCapabilities -Name 'RouterReadyDispatch' -DefaultValue ([bool]$config.DispatchQueuedCommandsInline))
$watcherHealthSummary = Get-TargetAutoloopWatcherHealthSummary `
    -WatcherState $watcherState `
    -HeartbeatAt ([string](Get-ConfigValue -Object $payload -Name 'HeartbeatAt' -DefaultValue '')) `
    -LastUpdatedAt ([string](Get-ConfigValue -Object $payload -Name 'LastUpdatedAt' -DefaultValue ''))
$watcherHealth = [string](Get-ConfigValue -Object $watcherHealthSummary -Name 'Health' -DefaultValue 'missing')
$watcherHealthDetail = [string](Get-ConfigValue -Object $watcherHealthSummary -Name 'Detail' -DefaultValue '')
$watcherRecommendation = [string](Get-ConfigValue -Object $watcherHealthSummary -Name 'Recommendation' -DefaultValue '')
$recommendationHistorySnapshot = Get-TargetAutoloopRecommendationHistorySnapshot -Root $root -RunRoot $resolvedRunRoot
$recentRecommendation = Get-ConfigValue -Object $recommendationHistorySnapshot -Name 'Recent' -DefaultValue $null
$recentRecommendationAction = [string](Get-ConfigValue -Object $recentRecommendation -Name 'ActionKey' -DefaultValue 'none')
$recentRecommendationOutcome = [string](Get-ConfigValue -Object $recentRecommendation -Name 'Outcome' -DefaultValue 'none')
$recommendationHistorySummary = [string](Get-ConfigValue -Object $recommendationHistorySnapshot -Name 'Summary' -DefaultValue '권장 이력: (없음)')
$recommendationHistoryWarning = [string](Get-ConfigValue -Object $recommendationHistorySnapshot -Name 'Warning' -DefaultValue '')
$recentRecommendationBadge = Get-TargetAutoloopRecentRecommendationBadge -RecentRecommendation $recentRecommendation
$recommendationSpec = Get-TargetAutoloopCurrentRecommendationSpec `
    -RunRoot $resolvedRunRoot `
    -ControllerState ([string]$payload.ControllerState) `
    -WatcherState $watcherState `
    -WatcherHealth $watcherHealth `
    -WatcherHealthDetail $watcherHealthDetail `
    -WatcherRecommendation $watcherRecommendation `
    -PendingAction $controlPendingAction `
    -RecentRecommendation $recentRecommendation
$recommendationRetryBadge = Get-TargetAutoloopRetryReasonBadge -RecommendationSpec $recommendationSpec
$recommendationMode = Get-TargetAutoloopRecommendationMode -RecommendationSpec $recommendationSpec
$recommendationLevel = Get-TargetAutoloopRecommendationLevel -RecommendationSpec $recommendationSpec
$recommendationActionKey = [string](Get-ConfigValue -Object $recommendationSpec -Name 'ActionKey' -DefaultValue '')
$smokeReceipt = Get-TargetAutoloopProofReceiptSummary `
    -SmokeReceiptPath $statePaths.SmokeReceiptPath `
    -AcceptanceReceiptPath $statePaths.AcceptanceReceiptPath `
    -TargetRows @($payload.Targets)
$smokeResult = [string](Get-ConfigValue -Object $smokeReceipt -Name 'Result' -DefaultValue 'none')
$smokeSource = [string](Get-ConfigValue -Object $smokeReceipt -Name 'Source' -DefaultValue '')
$smokeProofLevel = [string](Get-ConfigValue -Object $smokeReceipt -Name 'ProofLevel' -DefaultValue '')
$smokeTargetId = [string](Get-ConfigValue -Object $smokeReceipt -Name 'TargetId' -DefaultValue '')
$smokeAcceptanceState = [string](Get-ConfigValue -Object $smokeReceipt -Name 'AcceptanceState' -DefaultValue '')
$smokeAcceptanceReason = [string](Get-ConfigValue -Object $smokeReceipt -Name 'AcceptanceReason' -DefaultValue '')
$smokeCycleCount = [int](Get-ConfigValue -Object $smokeReceipt -Name 'CycleCount' -DefaultValue 0)
$smokeMaxCycleCount = [int](Get-ConfigValue -Object $smokeReceipt -Name 'MaxCycleCount' -DefaultValue 0)
$smokeWatcherStopReason = [string](Get-ConfigValue -Object $smokeReceipt -Name 'WatcherStopReason' -DefaultValue '')
$smokeSummaryText = [string](Get-ConfigValue -Object $smokeReceipt -Name 'Summary' -DefaultValue 'smoke: (없음)')
$smokeReceiptError = [string](Get-ConfigValue -Object $smokeReceipt -Name 'Error' -DefaultValue '')
$proofCloseout = Get-TargetAutoloopProofCloseoutSummary -ProofReceipt $smokeReceipt
$closeoutState = [string](Get-ConfigValue -Object $proofCloseout -Name 'State' -DefaultValue 'pending-proof')
$closeoutMode = [string](Get-ConfigValue -Object $proofCloseout -Name 'Mode' -DefaultValue 'not-ready')
$closeoutReason = [string](Get-ConfigValue -Object $proofCloseout -Name 'Reason' -DefaultValue 'no-proof')
$closeoutSummaryText = [string](Get-ConfigValue -Object $proofCloseout -Name 'Summary' -DefaultValue 'closeout: pending-proof / mode=not-ready / reason=no-proof')
$closeoutNextStep = [string](Get-ConfigValue -Object $proofCloseout -Name 'RecommendedNextStep' -DefaultValue '')

if ($AsJson) {
    $payload | Add-Member -NotePropertyName WatcherHealth -NotePropertyValue $watcherHealth -Force
    $payload | Add-Member -NotePropertyName WatcherHealthDetail -NotePropertyValue $watcherHealthDetail -Force
    $payload | Add-Member -NotePropertyName WatcherRecommendation -NotePropertyValue $watcherRecommendation -Force
    $payload | Add-Member -NotePropertyName RecommendationActionKey -NotePropertyValue $recommendationActionKey -Force
    $payload | Add-Member -NotePropertyName RecommendationMode -NotePropertyValue $recommendationMode -Force
    $payload | Add-Member -NotePropertyName RecommendationLevel -NotePropertyValue $recommendationLevel -Force
    $payload | Add-Member -NotePropertyName RecommendationLabel -NotePropertyValue ([string](Get-ConfigValue -Object $recommendationSpec -Name 'Label' -DefaultValue '권장 조치 없음')) -Force
    $payload | Add-Member -NotePropertyName RecommendationDetail -NotePropertyValue ([string](Get-ConfigValue -Object $recommendationSpec -Name 'Detail' -DefaultValue '')) -Force
    $payload | Add-Member -NotePropertyName RecommendationDetailSections -NotePropertyValue @(Get-ConfigValue -Object $recommendationSpec -Name 'DetailSections' -DefaultValue @()) -Force
    $payload | Add-Member -NotePropertyName RecommendationReadOnly -NotePropertyValue ([bool](Get-ConfigValue -Object $recommendationSpec -Name 'ReadOnly' -DefaultValue $false)) -Force
    $payload | Add-Member -NotePropertyName RecommendationRetryBadge -NotePropertyValue $recommendationRetryBadge -Force
    $payload | Add-Member -NotePropertyName RecentRecommendationAction -NotePropertyValue $recentRecommendationAction -Force
    $payload | Add-Member -NotePropertyName RecentRecommendationOutcome -NotePropertyValue $recentRecommendationOutcome -Force
    $payload | Add-Member -NotePropertyName RecentRecommendation -NotePropertyValue $recentRecommendation -Force
    $payload | Add-Member -NotePropertyName RecentRecommendationBadge -NotePropertyValue $recentRecommendationBadge -Force
    $payload | Add-Member -NotePropertyName RecommendationHistory -NotePropertyValue @(Get-ConfigValue -Object $recommendationHistorySnapshot -Name 'History' -DefaultValue @()) -Force
    $payload | Add-Member -NotePropertyName RecommendationHistorySummary -NotePropertyValue $recommendationHistorySummary -Force
    $payload | Add-Member -NotePropertyName RecommendationHistoryWarning -NotePropertyValue $recommendationHistoryWarning -Force
    $payload | Add-Member -NotePropertyName SmokeReceipt -NotePropertyValue $smokeReceipt -Force
    $payload | Add-Member -NotePropertyName SmokeSummary -NotePropertyValue $smokeSummaryText -Force
    $payload | Add-Member -NotePropertyName ProofCloseout -NotePropertyValue $proofCloseout -Force
    $payload | Add-Member -NotePropertyName CloseoutSummary -NotePropertyValue $closeoutSummaryText -Force
    $payload | ConvertTo-Json -Depth 10
    return
}

$lines = @(
    'Target Autoloop Status'
    ('RunMode: ' + [string]$payload.RunMode)
    ('RunRoot: ' + [string]$payload.RunRoot)
    ('ControllerState: ' + [string]$payload.ControllerState)
    ('ControlPendingAction: ' + $(if (Test-NonEmptyString $controlPendingAction) { $controlPendingAction } else { '(none)' }))
    ('ControlPendingRequestId: ' + $(if (Test-NonEmptyString $controlPendingRequestId) { $controlPendingRequestId } else { '(none)' }))
    ('LastHandledAction: ' + $(if (Test-NonEmptyString $lastHandledAction) { $lastHandledAction } else { '(none)' }))
    ('LastHandledRequestId: ' + $(if (Test-NonEmptyString $lastHandledRequestId) { $lastHandledRequestId } else { '(none)' }))
    ('LastHandledResult: ' + $(if (Test-NonEmptyString $lastHandledResult) { $lastHandledResult } else { '(none)' }))
    ('WatcherState: ' + $(if (Test-NonEmptyString $watcherState) { $watcherState } else { '(none)' }))
    ('WatcherHealth: ' + $watcherHealth)
    ('WatcherHealthDetail: ' + $(if (Test-NonEmptyString $watcherHealthDetail) { $watcherHealthDetail } else { '(none)' }))
    ('WatcherStopReason: ' + $(if (Test-NonEmptyString $watcherStopReason) { $watcherStopReason } else { '(none)' }))
    ('HeartbeatAt: ' + $(if (Test-NonEmptyString ([string]$payload.HeartbeatAt)) { [string]$payload.HeartbeatAt } else { '(none)' }))
    ('ProcessStartedAt: ' + $(if (Test-NonEmptyString ([string]$payload.ProcessStartedAt)) { [string]$payload.ProcessStartedAt } else { '(none)' }))
    ('ConfiguredRunDurationSec: ' + [string]$payload.ConfiguredRunDurationSec)
    ('ModeCapabilities: commandQueue=True typedWindowDispatch={0} routerReadyDispatch={1} maxConcurrentTargets={2} maxConcurrentSubmits={3}' -f $typedWindowDispatch, $routerReadyDispatch, $maxConcurrentTargets, $maxConcurrentSubmits)
    ('PauseSemantics: detect-and-queue=true dispatch-submit-blocked=true resume-drains-queue=true')
    ('WatcherRecommendation: ' + $watcherRecommendation)
    ('RecommendationAction: ' + $(if (Test-NonEmptyString $recommendationActionKey) { $recommendationActionKey } else { '(none)' }))
    ('RecommendationMode: ' + $recommendationMode)
    ('RecommendationLevel: ' + $recommendationLevel)
    ('RecommendationLabel: ' + [string](Get-ConfigValue -Object $recommendationSpec -Name 'Label' -DefaultValue '권장 조치 없음'))
    ('RecommendationDetail: ' + $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $recommendationSpec -Name 'Detail' -DefaultValue ''))) { [string](Get-ConfigValue -Object $recommendationSpec -Name 'Detail' -DefaultValue '') } else { '(none)' }))
    ('RecommendationRetryBadge: ' + [string](Get-ConfigValue -Object $recommendationRetryBadge -Name 'Text' -DefaultValue '재시도 사유: (없음)'))
    ('SmokeSummary: ' + $smokeSummaryText)
    ('CloseoutSummary: ' + $closeoutSummaryText)
    ('CloseoutNextStep: ' + $(if (Test-NonEmptyString $closeoutNextStep) { $closeoutNextStep } else { '(none)' }))
    ('SmokeReceiptPath: ' + [string](Get-ConfigValue -Object $smokeReceipt -Name 'Path' -DefaultValue [string]$statePaths.SmokeReceiptPath))
    ('State: ' + [string]$payload.State)
    ((
        'Counts: total={0} enabled={1} watcher={2} watchHealth={3} delay={4} delayState={5} controlAction={6} queued={7} waiting={8} failed={9} limit={10} recAction={11} recOutcome={12} recMode={13} recLevel={14} recKey={15}' -f
            [int](Get-ConfigValue -Object $payload.Counts -Name 'TotalTargets' -DefaultValue 0),
            [int](Get-ConfigValue -Object $payload.Counts -Name 'EnabledTargets' -DefaultValue 0),
            $(if (Test-NonEmptyString $watcherState) { $watcherState } else { 'none' }),
            $watcherHealth,
            [int](Get-ConfigValue -Object $payload.Counts -Name 'DispatchDelayTargets' -DefaultValue 0),
            $delayState,
            $(if (Test-NonEmptyString $controlPendingAction) { $controlPendingAction } else { 'none' }),
            [int](Get-ConfigValue -Object $payload.Counts -Name 'QueuedTargets' -DefaultValue 0),
            [int](Get-ConfigValue -Object $payload.Counts -Name 'WaitingOutputTargets' -DefaultValue 0),
            [int](Get-ConfigValue -Object $payload.Counts -Name 'FailedTargets' -DefaultValue 0),
            [int](Get-ConfigValue -Object $payload.Counts -Name 'LimitReachedTargets' -DefaultValue 0),
            $(if (Test-NonEmptyString $recentRecommendationAction) { $recentRecommendationAction } else { 'none' }),
            $(if (Test-NonEmptyString $recentRecommendationOutcome) { $recentRecommendationOutcome } else { 'none' }),
            $recommendationMode,
            $recommendationLevel,
            $(if (Test-NonEmptyString $recommendationActionKey) { $recommendationActionKey } else { 'none' })
        ) + $(if (Test-NonEmptyString $watcherHealthDetail) { ' watchAge={0}' -f $watcherHealthDetail } else { '' }) + $(if (Test-NonEmptyString $watcherStopReason) { ' watchStop={0}' -f $watcherStopReason } else { '' }) + $(if (Test-NonEmptyString $lastHandledAction) { ' lastHandled={0}:{1}' -f $lastHandledAction, $(if (Test-NonEmptyString $lastHandledResult) { $lastHandledResult } else { 'none' }) } else { '' }) + $(if ($null -ne $minimumRemainingSeconds) { ' minRemaining={0}s' -f [int]$minimumRemainingSeconds } else { '' }) + $(if (Test-NonEmptyString $minimumRemainingTargetId) { ' delayTarget={0}' -f $minimumRemainingTargetId } else { '' }) + $(if (Test-NonEmptyString $minimumRemainingDelayRangeLabel) { ' delayRange={0}' -f $minimumRemainingDelayRangeLabel } else { '' }) + $(if (Test-NonEmptyString $minimumRemainingEligibleAt) { ' delayDueAt={0}' -f $minimumRemainingEligibleAt } else { '' }) + $(if (Test-NonEmptyString $smokeResult) { ' smoke={0}' -f $smokeResult } else { '' }) + $(if (Test-NonEmptyString $smokeProofLevel) { ' smokeProof={0}' -f $smokeProofLevel } else { '' }) + $(if (Test-NonEmptyString $smokeSource) { ' smokeSource={0}' -f $smokeSource } else { '' }) + $(if (Test-NonEmptyString $smokeTargetId) { ' smokeTarget={0}' -f $smokeTargetId } else { '' }) + $(if (Test-NonEmptyString $smokeAcceptanceState) { ' smokeAcceptance={0}' -f $smokeAcceptanceState } else { '' }) + $(if ($smokeMaxCycleCount -gt 0) { ' smokeCycle={0}/{1}' -f $smokeCycleCount, $smokeMaxCycleCount } else { '' }) + $(if (Test-NonEmptyString $smokeWatcherStopReason) { ' smokeStop={0}' -f $smokeWatcherStopReason } else { '' }) + $(if (Test-NonEmptyString $smokeAcceptanceReason) { ' smokeReason={0}' -f $smokeAcceptanceReason } else { '' }) + $(if (Test-NonEmptyString $closeoutState) { ' closeout={0}' -f $closeoutState } else { '' }) + $(if (Test-NonEmptyString $closeoutMode) { ' closeoutMode={0}' -f $closeoutMode } else { '' }) + $(if (Test-NonEmptyString $closeoutReason) { ' closeoutReason={0}' -f $closeoutReason } else { '' }))
    ('RecommendationHistorySummary: ' + $recommendationHistorySummary)
)
if (Test-NonEmptyString $recommendationHistoryWarning) {
    $lines += ('RecommendationHistoryWarning: ' + $recommendationHistoryWarning)
}
if (Test-NonEmptyString $smokeReceiptError) {
    $lines += ('SmokeWarning: ' + $smokeReceiptError)
}
$lines += ''

foreach ($targetRow in @($payload.Targets)) {
    $delayMode = [string](Get-ConfigValue -Object $targetRow -Name 'PublishReadyDispatchDelayMode' -DefaultValue 'fixed')
    $delayMinSeconds = [int](Get-ConfigValue -Object $targetRow -Name 'PublishReadyDispatchMinDelaySeconds' -DefaultValue ([int](Get-ConfigValue -Object $targetRow -Name 'PublishReadyDispatchDelaySeconds' -DefaultValue 0)))
    $delayMaxSeconds = [int](Get-ConfigValue -Object $targetRow -Name 'PublishReadyDispatchMaxDelaySeconds' -DefaultValue $delayMinSeconds)
    $delayLabel = if (($delayMaxSeconds -gt $delayMinSeconds -or $delayMode -eq 'range') -and ($delayMaxSeconds -gt 0 -or $delayMinSeconds -gt 0)) {
        ('delay: {0}-{1}s' -f $delayMinSeconds, $delayMaxSeconds)
    }
    elseif ($delayMinSeconds -gt 0) {
        ('delay: {0}s' -f $delayMinSeconds)
    }
    else {
        ''
    }
    $cycleCount = [int](Get-ConfigValue -Object $targetRow -Name 'CycleCount' -DefaultValue 0)
    $maxCycleCount = [int](Get-ConfigValue -Object $targetRow -Name 'MaxCycleCount' -DefaultValue 0)
    $cycleLabel = if ($maxCycleCount -gt 0) { ('cycle {0}/{1}' -f $cycleCount, $maxCycleCount) } else { ('cycle {0}' -f $cycleCount) }
    $dispatchState = [string](Get-ConfigValue -Object $targetRow -Name 'LastDispatchState' -DefaultValue '')
    $isDispatchDelayRow = Test-TargetAutoloopDispatchDelayRow -TargetRow $targetRow
    $line = ('{0} | {1} | {2} | next: {3} | trigger: {4} | dispatch: {5}' -f
        [string](Get-ConfigValue -Object $targetRow -Name 'TargetId' -DefaultValue ''),
        [string](Get-ConfigValue -Object $targetRow -Name 'Phase' -DefaultValue ''),
        $cycleLabel,
        [string](Get-ConfigValue -Object $targetRow -Name 'NextAction' -DefaultValue ''),
        [string](Get-ConfigValue -Object $targetRow -Name 'LastTriggerKind' -DefaultValue ''),
        $dispatchState)
    if ($isDispatchDelayRow -and (Test-NonEmptyString $delayLabel)) {
        $line += (' | {0}' -f $delayLabel)
    }
    $relayTargetFolderState = [string](Get-ConfigValue -Object $targetRow -Name 'RelayTargetFolderState' -DefaultValue '')
    if (Test-NonEmptyString $relayTargetFolderState) {
        $line += (' | relay: {0}' -f $relayTargetFolderState)
    }
    $pendingDelaySeconds = [int](Get-ConfigValue -Object $targetRow -Name 'PendingDispatchDelaySeconds' -DefaultValue 0)
    if ($isDispatchDelayRow -and $pendingDelaySeconds -gt 0) {
        $line += (' | pendingDelay: {0}s' -f $pendingDelaySeconds)
    }
    $pendingEligibleAt = [string](Get-ConfigValue -Object $targetRow -Name 'PendingDispatchEligibleAt' -DefaultValue '')
    if ($isDispatchDelayRow -and (Test-NonEmptyString $pendingEligibleAt)) {
        $line += (' | eligibleAt: {0}' -f $pendingEligibleAt)
    }
    $remainingDelayLabel = if ($isDispatchDelayRow) { Get-TargetAutoloopRemainingDelayLabel -EligibleAt $pendingEligibleAt } else { '' }
    if (Test-NonEmptyString $remainingDelayLabel) {
        $line += (' | {0}' -f $remainingDelayLabel)
    }
    $lastFailureReason = [string](Get-ConfigValue -Object $targetRow -Name 'LastFailureReason' -DefaultValue '')
    if (Test-NonEmptyString $lastFailureReason) {
        $line += (' | fail: {0}' -f $lastFailureReason)
    }
    $lines += $line
}

$lines
