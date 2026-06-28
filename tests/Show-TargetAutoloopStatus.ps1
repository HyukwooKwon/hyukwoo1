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
        [AllowEmptyString()][string]$WatcherState,
        [bool]$ManifestExists = $false,
        [AllowEmptyString()][string]$ManifestRunMode = '',
        [string[]]$ManifestEnabledTargetIds = @(),
        [string[]]$ManifestPublishReadyMissingTargetIds = @(),
        [AllowEmptyString()][string]$RouterSessionState = '',
        [bool]$RouterSessionMismatch = $false,
        [AllowEmptyString()][string]$RouterLauncherSessionId = '',
        [AllowEmptyString()][string]$RuntimeLauncherSessionId = ''
    )

    if ($ManifestExists -and (Test-NonEmptyString $ManifestRunMode) -and $ManifestRunMode -ne 'target-autoloop') {
        return [pscustomobject]@{ Allowed = $false; Detail = ('현재 RunRoot는 target-autoloop용 run이 아닙니다 (manifest RunMode={0}). 새 RunRoot를 준비하세요.' -f $ManifestRunMode) }
    }
    if ($ManifestExists -and @($ManifestEnabledTargetIds).Count -eq 0) {
        return [pscustomobject]@{ Allowed = $false; Detail = '현재 RunRoot manifest에 enabled target이 없어 watcher 시작을 막았습니다. 새 RunRoot를 준비하세요.' }
    }
    if ($ManifestExists -and @($ManifestPublishReadyMissingTargetIds).Count -gt 0) {
        return [pscustomobject]@{ Allowed = $false; Detail = ('publish-ready 트리거가 꺼진 enabled target이 있어 watcher 시작을 막았습니다: {0}. publish-ready를 켜고 새 RunRoot를 준비하세요.' -f (@($ManifestPublishReadyMissingTargetIds) -join ', ')) }
    }
    if ($RouterSessionMismatch) {
        return [pscustomobject]@{
            Allowed = $false
            Detail = ('router/runtime LauncherSessionId가 달라 ready 파일이 ignored 될 수 있습니다. router만 현재 8창 세션에 맞춘 뒤 감지를 시작하세요. router={0} runtime={1}' -f $(if (Test-NonEmptyString $RouterLauncherSessionId) { $RouterLauncherSessionId } else { '-' }), $(if (Test-NonEmptyString $RuntimeLauncherSessionId) { $RuntimeLauncherSessionId } else { '-' }))
        }
    }
    if ($RouterSessionState -ne 'ok') {
        return [pscustomobject]@{
            Allowed = $false
            Detail = ('router/runtime 세션이 아직 watcher 시작 조건을 만족하지 않습니다. 8 Cell Autoloop 탭에서 8창 재사용+router 동기화 후 감지를 시작하세요. state={0} router={1} runtime={2}' -f $(if (Test-NonEmptyString $RouterSessionState) { $RouterSessionState } else { '-' }), $(if (Test-NonEmptyString $RouterLauncherSessionId) { $RouterLauncherSessionId } else { '-' }), $(if (Test-NonEmptyString $RuntimeLauncherSessionId) { $RuntimeLauncherSessionId } else { '-' }))
        }
    }
    if (Test-NonEmptyString $PendingAction) {
        return [pscustomobject]@{ Allowed = $false; Detail = ('target-autoloop 제어 요청({0})이 처리 중이라 watcher 시작을 막았습니다.' -f $PendingAction) }
    }
    if ($WatcherHealth -eq 'active') {
        return [pscustomobject]@{ Allowed = $false; Detail = ('현재 target-autoloop watcher가 이미 active 상태입니다: {0}' -f $(if (Test-NonEmptyString $WatcherState) { $WatcherState } else { 'running' })) }
    }
    return [pscustomobject]@{ Allowed = $true; Detail = '' }
}

function Get-TargetAutoloopRetryPendingSummary {
    param(
        $Config,
        [string[]]$TargetIds = @()
    )

    $retryPendingRoot = [string](Get-ConfigValue -Object $Config -Name 'RetryPendingRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $retryPendingRoot)) {
        $configPath = [string](Get-ConfigValue -Object $Config -Name 'ConfigPath' -DefaultValue '')
        if ((Test-NonEmptyString $configPath) -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            try {
                $rawConfigText = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
                $match = [regex]::Match($rawConfigText, "(?m)^\s*RetryPendingRoot\s*=\s*'((?:''|[^'])*)'")
                if ($match.Success) {
                    $retryPendingRoot = ([string]$match.Groups[1].Value).Replace("''", "'").Trim()
                }
            }
            catch {
                $retryPendingRoot = ''
            }
        }
    }
    $allowedTargets = @{}
    foreach ($targetId in @($TargetIds)) {
        $normalizedTargetId = [string]$targetId
        if (Test-NonEmptyString $normalizedTargetId) {
            $allowedTargets[$normalizedTargetId] = $true
        }
    }

    $items = @()
    if ((Test-NonEmptyString $retryPendingRoot) -and (Test-Path -LiteralPath $retryPendingRoot -PathType Container)) {
        $files = @(Get-ChildItem -LiteralPath $retryPendingRoot -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc, Name)
        foreach ($file in $files) {
            $segments = $file.Name -split '__', 3
            if ($segments.Count -lt 3) {
                continue
            }
            $targetId = [string]$segments[0]
            if ($allowedTargets.Count -gt 0 -and -not $allowedTargets.ContainsKey($targetId)) {
                continue
            }

            $metadataPath = ($file.FullName + '.meta.json')
            $metadata = $null
            if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
                try {
                    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
                }
                catch {
                    $metadata = $null
                }
            }

            $items += [pscustomobject][ordered]@{
                TargetId = $targetId
                Path = [string]$file.FullName
                LastWriteTime = $file.LastWriteTime.ToString('o')
                FailureCategory = [string](Get-ConfigValue -Object $metadata -Name 'FailureCategory' -DefaultValue '')
                FailureMessage = [string](Get-ConfigValue -Object $metadata -Name 'FailureMessage' -DefaultValue '')
                DebugLogPath = [string](Get-ConfigValue -Object $metadata -Name 'DebugLogPath' -DefaultValue '')
            }
        }
    }

    $latest = $null
    if (@($items).Count -gt 0) {
        $latest = @($items | Sort-Object LastWriteTime | Select-Object -Last 1)[0]
    }

    return [pscustomobject][ordered]@{
        Root = [string]$retryPendingRoot
        Count = [int](@($items).Count)
        TargetIds = @($items | ForEach-Object { [string]$_.TargetId } | Where-Object { Test-NonEmptyString $_ } | Select-Object -Unique)
        LatestPath = [string](Get-ConfigValue -Object $latest -Name 'Path' -DefaultValue '')
        LatestTargetId = [string](Get-ConfigValue -Object $latest -Name 'TargetId' -DefaultValue '')
        LatestFailureCategory = [string](Get-ConfigValue -Object $latest -Name 'FailureCategory' -DefaultValue '')
        LatestFailureMessage = [string](Get-ConfigValue -Object $latest -Name 'FailureMessage' -DefaultValue '')
        LatestDebugLogPath = [string](Get-ConfigValue -Object $latest -Name 'DebugLogPath' -DefaultValue '')
        Items = @($items)
    }
}

function Get-TargetAutoloopRouterInboxReadySummary {
    param(
        $Config,
        [string[]]$TargetIds = @()
    )

    $allowedTargets = @{}
    foreach ($targetId in @($TargetIds)) {
        $normalizedTargetId = [string]$targetId
        if (Test-NonEmptyString $normalizedTargetId) {
            $allowedTargets[$normalizedTargetId] = $true
        }
    }

    $items = @()
    $targetFolders = @()
    foreach ($target in @($Config.Targets)) {
        $targetId = [string](Get-ConfigValue -Object $target -Name 'TargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $targetId)) {
            continue
        }
        if ($allowedTargets.Count -gt 0 -and -not $allowedTargets.ContainsKey($targetId)) {
            continue
        }

        $folder = [string](Get-ConfigValue -Object $target -Name 'GlobalFolder' -DefaultValue '')
        if (-not (Test-NonEmptyString $folder)) {
            continue
        }
        $targetFolders += [pscustomobject][ordered]@{
            TargetId = $targetId
            Folder = $folder
            Exists = (Test-Path -LiteralPath $folder -PathType Container)
        }
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            continue
        }

        $files = @(Get-ChildItem -LiteralPath $folder -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc, Name)
        foreach ($file in $files) {
            $deliveryPath = ($file.FullName + '.delivery.json')
            $delivery = $null
            if (Test-Path -LiteralPath $deliveryPath -PathType Leaf) {
                try {
                    $delivery = Get-Content -LiteralPath $deliveryPath -Raw -Encoding UTF8 | ConvertFrom-Json
                }
                catch {
                    $delivery = $null
                }
            }

            $items += [pscustomobject][ordered]@{
                TargetId = $targetId
                Folder = $folder
                Path = [string]$file.FullName
                LastWriteTime = $file.LastWriteTime.ToString('o')
                DeliveryPath = $deliveryPath
                DeliveryExists = (Test-Path -LiteralPath $deliveryPath -PathType Leaf)
                DeliveryTargetId = [string](Get-ConfigValue -Object $delivery -Name 'TargetId' -DefaultValue '')
                LauncherSessionId = [string](Get-ConfigValue -Object $delivery -Name 'LauncherSessionId' -DefaultValue '')
                MessageType = [string](Get-ConfigValue -Object $delivery -Name 'MessageType' -DefaultValue '')
                CreatedAt = [string](Get-ConfigValue -Object $delivery -Name 'CreatedAt' -DefaultValue '')
            }
        }
    }

    $latest = $null
    if (@($items).Count -gt 0) {
        $latest = @($items | Sort-Object LastWriteTime | Select-Object -Last 1)[0]
    }

    return [pscustomobject][ordered]@{
        Count = [int](@($items).Count)
        TargetIds = @($items | ForEach-Object { [string]$_.TargetId } | Where-Object { Test-NonEmptyString $_ } | Select-Object -Unique)
        LatestPath = [string](Get-ConfigValue -Object $latest -Name 'Path' -DefaultValue '')
        LatestTargetId = [string](Get-ConfigValue -Object $latest -Name 'TargetId' -DefaultValue '')
        LatestLauncherSessionId = [string](Get-ConfigValue -Object $latest -Name 'LauncherSessionId' -DefaultValue '')
        LatestMessageType = [string](Get-ConfigValue -Object $latest -Name 'MessageType' -DefaultValue '')
        LatestCreatedAt = [string](Get-ConfigValue -Object $latest -Name 'CreatedAt' -DefaultValue '')
        LatestLastWriteTime = [string](Get-ConfigValue -Object $latest -Name 'LastWriteTime' -DefaultValue '')
        TargetFolders = @($targetFolders)
        Items = @($items)
    }
}

function Get-TargetAutoloopStatusPathState {
    param([Parameter(Mandatory)][string]$Path)

    return [pscustomobject]@{
        Path = [string]$Path
        Exists = [bool](Test-Path -LiteralPath $Path -PathType Leaf)
    }
}

function Get-TargetAutoloopStatusContractSnapshot {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$TargetId
    )

    $summaryState = Get-TargetAutoloopStatusPathState -Path ([string]$Paths.SourceSummaryPath)
    $reviewState = Get-TargetAutoloopStatusPathState -Path ([string]$Paths.SourceReviewZipPath)
    $publishState = Get-TargetAutoloopStatusPathState -Path ([string]$Paths.PublishReadyPath)
    $core = Get-TargetAutoloopContractSnapshotCore -Paths $Paths -TargetId $TargetId -SummaryState $summaryState -ReviewZipState $reviewState -PublishReadyState $publishState

    return [pscustomobject]@{
        State = [string]$core.State
        Reason = [string]$core.Reason
        PublishReadyValid = [bool]$core.PublishReadyValid
        SummaryExists = [bool]$core.SummaryExists
        ReviewZipExists = [bool]$core.ReviewZipExists
        PublishReadyExists = [bool]$core.PublishReadyExists
        OutputFingerprint = [string]$core.OutputFingerprint
        PublishedAt = [string]$core.PublishedAt
    }
}

function Get-TargetAutoloopStatusOutputBlockSummary {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$ManifestTargetMap,
        [Parameter(Mandatory)]$StateDocument,
        [object[]]$StatusRows = @(),
        $RouterSessionState = $null
    )

    $stateTargetMap = Get-TargetAutoloopTargetStateMap -StateDocument $StateDocument
    $statusRowMap = @{}
    foreach ($row in @($StatusRows)) {
        $targetId = [string](Get-ConfigValue -Object $row -Name 'TargetId' -DefaultValue '')
        if (Test-NonEmptyString $targetId) {
            $statusRowMap[$targetId] = $row
        }
    }

    $items = @()
    foreach ($target in @($Config.Targets)) {
        $targetId = [string](Get-ConfigValue -Object $target -Name 'TargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $targetId)) {
            continue
        }

        $inManifest = $false
        $manifestTarget = $null
        if ($null -ne $ManifestTargetMap -and $ManifestTargetMap.ContainsKey($targetId)) {
            $inManifest = $true
            $manifestTarget = $ManifestTargetMap[$targetId]
        }

        $enabled = if ($inManifest) {
            [bool](Get-ConfigValue -Object $manifestTarget -Name 'Enabled' -DefaultValue $false)
        }
        else {
            [bool](Get-ConfigValue -Object $target -Name 'Enabled' -DefaultValue $false)
        }
        if (-not $enabled) {
            continue
        }

        $triggerKinds = if ($inManifest) {
            @(Get-StringArray (Get-ConfigValue -Object $manifestTarget -Name 'TriggerKinds' -DefaultValue @()))
        }
        else {
            @(Get-StringArray (Get-ConfigValue -Object $target -Name 'TriggerKinds' -DefaultValue @()))
        }
        if ($triggerKinds -notcontains 'publish-ready') {
            continue
        }

        $stateRecord = if ($stateTargetMap.Contains($targetId)) { $stateTargetMap[$targetId] } else { $null }
        $statusRow = if ($statusRowMap.ContainsKey($targetId)) { $statusRowMap[$targetId] } else { $null }
        $paths = Get-TargetAutoloopTargetPaths -RunRoot $RunRoot -TargetId $targetId -Target $target -Config $Config
        if ($inManifest) {
            $paths = Use-TargetAutoloopManifestTargetPaths -Paths $paths -ManifestTarget $manifestTarget
        }
        $contract = Get-TargetAutoloopStatusContractSnapshot -Paths $paths -TargetId $targetId
        $delivery = Get-TargetAutoloopDeliverySnapshot -Contract $contract -StateRecord $stateRecord -StatusRow $statusRow -RouterSessionState $RouterSessionState -UseRouterSessionFallback

        $phase = [string](Get-ConfigValue -Object $stateRecord -Name 'Phase' -DefaultValue ([string](Get-ConfigValue -Object $statusRow -Name 'Phase' -DefaultValue '')))
        $nextAction = [string](Get-ConfigValue -Object $stateRecord -Name 'NextAction' -DefaultValue ([string](Get-ConfigValue -Object $statusRow -Name 'NextAction' -DefaultValue '')))
        $cycleCount = [int](Get-ConfigValue -Object $stateRecord -Name 'CycleCount' -DefaultValue ([int](Get-ConfigValue -Object $statusRow -Name 'CycleCount' -DefaultValue 0)))
        $maxCycleCount = [int](Get-ConfigValue -Object $stateRecord -Name 'MaxCycleCount' -DefaultValue ([int](Get-ConfigValue -Object $statusRow -Name 'MaxCycleCount' -DefaultValue 0)))
        $limitReached = ($phase -eq 'limit-reached') -or ($nextAction -eq 'limit-reached') -or ($maxCycleCount -gt 0 -and $cycleCount -ge $maxCycleCount)
        $readyUnaccepted = ([string](Get-ConfigValue -Object $delivery -Name 'Artifact' -DefaultValue '') -eq 'created' -and [string](Get-ConfigValue -Object $delivery -Name 'Watcher' -DefaultValue '') -eq 'not-yet-accepted-current-marker')
        $lastDispatchState = [string](Get-ConfigValue -Object $delivery -Name 'LastDispatchState' -DefaultValue '')
        $routerBlocked = $lastDispatchState -in @('router-session-not-ready', 'router-session-mismatch')

        $items += [pscustomobject][ordered]@{
            TargetId = $targetId
            Phase = $phase
            NextAction = $nextAction
            CycleCount = $cycleCount
            MaxCycleCount = $maxCycleCount
            LimitReached = [bool]$limitReached
            ReadyUnaccepted = [bool]$readyUnaccepted
            RouterBlocked = [bool]$routerBlocked
            DeliverySummary = [string](Get-ConfigValue -Object $delivery -Name 'Summary' -DefaultValue '')
            DeliveryNextActionCode = [string](Get-ConfigValue -Object $delivery -Name 'NextActionCode' -DefaultValue '')
            CurrentMarkerFingerprint = [string](Get-ConfigValue -Object $delivery -Name 'CurrentMarkerFingerprint' -DefaultValue '')
            LastHandledOutputFingerprint = [string](Get-ConfigValue -Object $delivery -Name 'LastHandledOutputFingerprint' -DefaultValue '')
            LastDispatchState = $lastDispatchState
            PublishReadyPath = [string]$paths.PublishReadyPath
            SourceOutboxPath = [string]$paths.SourceOutboxRoot
        }
    }

    $limitReachedItems = @($items | Where-Object { [bool]$_.LimitReached })
    $readyUnacceptedItems = @($items | Where-Object { [bool]$_.ReadyUnaccepted })
    $limitReadyItems = @($items | Where-Object { [bool]$_.LimitReached -and [bool]$_.ReadyUnaccepted })
    $routerBlockedItems = @($items | Where-Object { [bool]$_.RouterBlocked })
    $latest = if (@($limitReadyItems).Count -gt 0) {
        @($limitReadyItems)[0]
    }
    elseif (@($readyUnacceptedItems).Count -gt 0) {
        @($readyUnacceptedItems)[0]
    }
    elseif (@($routerBlockedItems).Count -gt 0) {
        @($routerBlockedItems)[0]
    }
    elseif (@($limitReachedItems).Count -gt 0) {
        @($limitReachedItems)[0]
    }
    else {
        $null
    }

    return [pscustomobject][ordered]@{
        Count = [int](@($items).Count)
        LimitReachedCount = [int](@($limitReachedItems).Count)
        ReadyUnacceptedCount = [int](@($readyUnacceptedItems).Count)
        LimitReachedReadyUnacceptedCount = [int](@($limitReadyItems).Count)
        RouterBlockedCount = [int](@($routerBlockedItems).Count)
        TargetIds = @($items | ForEach-Object { [string]$_.TargetId })
        LimitReachedTargetIds = @($limitReachedItems | ForEach-Object { [string]$_.TargetId })
        ReadyUnacceptedTargetIds = @($readyUnacceptedItems | ForEach-Object { [string]$_.TargetId })
        LimitReachedReadyUnacceptedTargetIds = @($limitReadyItems | ForEach-Object { [string]$_.TargetId })
        RouterBlockedTargetIds = @($routerBlockedItems | ForEach-Object { [string]$_.TargetId })
        LatestTargetId = [string](Get-ConfigValue -Object $latest -Name 'TargetId' -DefaultValue '')
        LatestCycleCount = [int](Get-ConfigValue -Object $latest -Name 'CycleCount' -DefaultValue 0)
        LatestMaxCycleCount = [int](Get-ConfigValue -Object $latest -Name 'MaxCycleCount' -DefaultValue 0)
        LatestDeliverySummary = [string](Get-ConfigValue -Object $latest -Name 'DeliverySummary' -DefaultValue '')
        LatestLastDispatchState = [string](Get-ConfigValue -Object $latest -Name 'LastDispatchState' -DefaultValue '')
        LatestPublishReadyPath = [string](Get-ConfigValue -Object $latest -Name 'PublishReadyPath' -DefaultValue '')
        Items = @($items)
    }
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
        [bool]$ManifestExists = $false,
        [AllowEmptyString()][string]$ManifestRunMode = '',
        [string[]]$ManifestEnabledTargetIds = @(),
        [string[]]$ManifestPublishReadyMissingTargetIds = @(),
        [AllowEmptyString()][string]$RouterSessionState = '',
        [bool]$RouterSessionMismatch = $false,
        [AllowEmptyString()][string]$RouterLauncherSessionId = '',
        [AllowEmptyString()][string]$RuntimeLauncherSessionId = '',
        $RetryPendingSummary,
        $OutputBlockSummary,
        $RecentRecommendation
    )

    $stateRoot = Join-Path $RunRoot '.state'
    $stderrPath = Join-Path $stateRoot 'target-autoloop-watcher.stderr.log'
    $stderrExists = Test-Path -LiteralPath $stderrPath -PathType Leaf
    $startEligibility = Get-TargetAutoloopStartEligibility `
        -PendingAction $PendingAction `
        -WatcherHealth $WatcherHealth `
        -WatcherState $WatcherState `
        -ManifestExists:$ManifestExists `
        -ManifestRunMode $ManifestRunMode `
        -ManifestEnabledTargetIds @($ManifestEnabledTargetIds) `
        -ManifestPublishReadyMissingTargetIds @($ManifestPublishReadyMissingTargetIds) `
        -RouterSessionState $RouterSessionState `
        -RouterSessionMismatch:$RouterSessionMismatch `
        -RouterLauncherSessionId $RouterLauncherSessionId `
        -RuntimeLauncherSessionId $RuntimeLauncherSessionId
    $resumeEligibility = Get-TargetAutoloopControlEligibility -Action 'resume' -ControllerState $ControllerState -PendingAction $PendingAction

    $label = '권장 조치 없음'
    $actionKey = ''
    $detail = [string]$WatcherRecommendation
    $detailSections = if (Test-NonEmptyString $detail) { @($detail) } else { @() }
    $readOnly = $false
    $retryOutcome = ''
    $retryDetail = ''
    $limitReadyCount = [int](Get-ConfigValue -Object $OutputBlockSummary -Name 'LimitReachedReadyUnacceptedCount' -DefaultValue 0)

    if ($limitReadyCount -gt 0) {
        $targetIds = @(Get-ConfigValue -Object $OutputBlockSummary -Name 'LimitReachedReadyUnacceptedTargetIds' -DefaultValue @())
        $targetText = if (@($targetIds).Count -gt 0) { @($targetIds) -join ',' } else { '(none)' }
        $cycleCount = [int](Get-ConfigValue -Object $OutputBlockSummary -Name 'LatestCycleCount' -DefaultValue 0)
        $maxCycleCount = [int](Get-ConfigValue -Object $OutputBlockSummary -Name 'LatestMaxCycleCount' -DefaultValue 0)
        $deliverySummary = [string](Get-ConfigValue -Object $OutputBlockSummary -Name 'LatestDeliverySummary' -DefaultValue '')
        $lastDispatchState = [string](Get-ConfigValue -Object $OutputBlockSummary -Name 'LatestLastDispatchState' -DefaultValue '')
        $label = '새 RunRoot 준비'
        $actionKey = 'prepare_autoloop_runroot'
        $detail = ('현재 RunRoot에서 target이 MaxCycleCount에 도달했고 새 publish.ready marker가 watcher accepted 되지 않았습니다. targets={0}, cycle={1}/{2}, delivery={3}. 같은 RunRoot에 summary.txt/review.zip/publish.ready.json만 다시 만들어도 다음 action은 생성되지 않습니다. 새 RunRoot를 준비하거나 MaxCycleCount를 늘린 뒤 감지를 다시 시작하세요.' -f
            $targetText,
            $cycleCount,
            $maxCycleCount,
            $(if (Test-NonEmptyString $deliverySummary) { $deliverySummary } else { '-' }))
        if (Test-NonEmptyString $lastDispatchState) {
            $detail += (' lastDispatch={0}' -f $lastDispatchState)
        }
    }
    elseif (($RouterSessionMismatch -or $RouterSessionState -ne 'ok') -and $ManifestExists -and $ManifestRunMode -eq 'target-autoloop' -and @($ManifestEnabledTargetIds).Count -gt 0 -and @($ManifestPublishReadyMissingTargetIds).Count -eq 0) {
        $label = if ($RouterSessionMismatch) { 'router만 세션 맞추기' } else { '8창 재사용+router 동기화' }
        $actionKey = 'restart_router_for_autoloop'
        $detail = [string](Get-ConfigValue -Object $startEligibility -Name 'Detail' -DefaultValue '')
    }
    elseif ([int](Get-ConfigValue -Object $RetryPendingSummary -Name 'Count' -DefaultValue 0) -gt 0) {
        $retryPendingTargetIds = @(Get-ConfigValue -Object $RetryPendingSummary -Name 'TargetIds' -DefaultValue @())
        $retryPendingCount = [int](Get-ConfigValue -Object $RetryPendingSummary -Name 'Count' -DefaultValue 0)
        $latestFailureCategory = [string](Get-ConfigValue -Object $RetryPendingSummary -Name 'LatestFailureCategory' -DefaultValue '')
        $latestFailureMessage = [string](Get-ConfigValue -Object $RetryPendingSummary -Name 'LatestFailureMessage' -DefaultValue '')
        $latestDebugLogPath = [string](Get-ConfigValue -Object $RetryPendingSummary -Name 'LatestDebugLogPath' -DefaultValue '')
        $label = 'retry-pending 재큐잉'
        $actionKey = 'requeue_retry_pending'
        $detail = ('router retry-pending에 target-autoloop ready 파일 {0}개가 있습니다. metadata 포함 재큐잉 후 watcher/router가 다시 처리하게 하세요. targets={1}' -f $retryPendingCount, $(if ($retryPendingTargetIds.Count -gt 0) { $retryPendingTargetIds -join ',' } else { '(none)' }))
        if (Test-NonEmptyString $latestFailureCategory) {
            $detail += (' latestFailure={0}' -f $latestFailureCategory)
        }
        if (Test-NonEmptyString $latestFailureMessage) {
            $detail += (' latestMessage={0}' -f (Get-TargetAutoloopCompactText -Value $latestFailureMessage -MaxChars 120))
        }
        if (Test-NonEmptyString $latestDebugLogPath) {
            $detail += (' debugLog={0}' -f $latestDebugLogPath)
        }
    }
    elseif ($WatcherHealth -eq 'stale') {
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
        else {
            $startDetail = [string](Get-ConfigValue -Object $startEligibility -Name 'Detail' -DefaultValue '')
            if ($startDetail -match 'target-autoloop용 run이 아닙니다') {
                $label = '새 RunRoot 준비'
                $actionKey = 'prepare_autoloop_runroot'
                $detail = $startDetail
            }
            elseif ($startDetail -match 'enabled target이 없어') {
                $label = '새 RunRoot 준비'
                $actionKey = 'prepare_autoloop_runroot'
                $detail = $startDetail
            }
            elseif ($startDetail -match 'publish-ready') {
                $label = 'publish-ready 켜고 새 RunRoot 준비'
                $actionKey = 'fix_publish_ready_prepare_autoloop_runroot'
                $detail = $startDetail
            }
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
        else {
            $startDetail = [string](Get-ConfigValue -Object $startEligibility -Name 'Detail' -DefaultValue '')
            if ($startDetail -match 'target-autoloop용 run이 아닙니다') {
                $label = '새 RunRoot 준비'
                $actionKey = 'prepare_autoloop_runroot'
                $detail = $startDetail
            }
            elseif ($startDetail -match 'enabled target이 없어') {
                $label = '새 RunRoot 준비'
                $actionKey = 'prepare_autoloop_runroot'
                $detail = $startDetail
            }
            elseif ($startDetail -match 'publish-ready') {
                $label = 'publish-ready 켜고 새 RunRoot 준비'
                $actionKey = 'fix_publish_ready_prepare_autoloop_runroot'
                $detail = $startDetail
            }
        }
    }
    elseif ($WatcherState -eq 'paused' -and [bool](Get-ConfigValue -Object $resumeEligibility -Name 'Allowed' -DefaultValue $false)) {
        $label = 'resume 요청'
        $actionKey = 'resume'
        $detail = 'watcher가 paused 상태입니다. resume 요청으로 현재 queued/pending 흐름을 이어가세요.'
    }
    elseif ([bool](Get-ConfigValue -Object $startEligibility -Name 'Allowed' -DefaultValue $false)) {
        $label = 'watch start'
        $actionKey = 'start_watch'
        $detail = 'RunRoot 준비가 끝났고 watcher를 시작할 수 있습니다.'
    }
    else {
        $startDetail = [string](Get-ConfigValue -Object $startEligibility -Name 'Detail' -DefaultValue '')
        if ($startDetail -match 'target-autoloop용 run이 아닙니다') {
            $label = '새 RunRoot 준비'
            $actionKey = 'prepare_autoloop_runroot'
            $detail = $startDetail
        }
        elseif ($startDetail -match 'enabled target이 없어') {
            $label = '새 RunRoot 준비'
            $actionKey = 'prepare_autoloop_runroot'
            $detail = $startDetail
        }
        elseif ($startDetail -match 'publish-ready') {
            $label = 'publish-ready 켜고 새 RunRoot 준비'
            $actionKey = 'fix_publish_ready_prepare_autoloop_runroot'
            $detail = $startDetail
        }
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
$routerSessionState = Get-TargetAutoloopRouterSessionState -Config $config
$routerSessionMismatch = [bool](Get-ConfigValue -Object $routerSessionState -Name 'Mismatch' -DefaultValue $false)
$routerLauncherSessionId = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterLauncherSessionId' -DefaultValue '')
$runtimeLauncherSessionId = [string](Get-ConfigValue -Object $routerSessionState -Name 'RuntimeLauncherSessionId' -DefaultValue '')
$manifestSummary = Get-TargetAutoloopManifestRouteSummary -Config $config -RunRoot $resolvedRunRoot -Mode Status
$manifestPath = [string]$manifestSummary.ManifestPath
$manifestExists = [bool]$manifestSummary.ManifestExists
$manifestRunMode = [string]$manifestSummary.ManifestRunMode
$manifestTargetIds = @($manifestSummary.ManifestTargetIds)
$manifestEnabledTargetIds = @($manifestSummary.ManifestEnabledTargetIds)
$manifestPublishReadyTargetIds = @($manifestSummary.ManifestPublishReadyTargetIds)
$manifestPublishReadyMissingTargetIds = @($manifestSummary.ManifestPublishReadyMissingTargetIds)
$retryPendingSummary = Get-TargetAutoloopRetryPendingSummary -Config $config -TargetIds @($manifestEnabledTargetIds)
$routerInboxReadySummary = Get-TargetAutoloopRouterInboxReadySummary -Config $config -TargetIds @($manifestEnabledTargetIds)

$stateDocument = Read-JsonObject -Path $statePaths.StatePath
$controlDocument = Read-JsonObject -Path $statePaths.ControlPath
$statusDocument = if (Test-Path -LiteralPath $statePaths.StatusPath -PathType Leaf) {
    Read-JsonObject -Path $statePaths.StatusPath
}
else {
    New-TargetAutoloopStatusDocument -Config $config -RunRoot $resolvedRunRoot -StateDocument $stateDocument -ControlDocument $controlDocument
}
$statusRows = @(Get-ConfigValue -Object $statusDocument -Name 'Targets' -DefaultValue @())
$outputBlockSummary = Get-TargetAutoloopStatusOutputBlockSummary `
    -Config $config `
    -RunRoot $resolvedRunRoot `
    -ManifestTargetMap $manifestSummary.ManifestTargetMap `
    -StateDocument $stateDocument `
    -StatusRows @($statusRows) `
    -RouterSessionState $routerSessionState

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
    ManifestPath = [string]$manifestPath
    ManifestExists = [bool]$manifestExists
    ManifestRunMode = [string]$manifestRunMode
    ManifestTargetIds = @($manifestTargetIds)
    ManifestEnabledTargetIds = @($manifestEnabledTargetIds)
    ManifestPublishReadyTargetIds = @($manifestPublishReadyTargetIds)
    ManifestPublishReadyMissingTargetIds = @($manifestPublishReadyMissingTargetIds)
    RouterSessionState = [string](Get-ConfigValue -Object $routerSessionState -Name 'State' -DefaultValue '')
    RouterSessionMismatch = [bool]$routerSessionMismatch
    RouterLauncherSessionId = [string]$routerLauncherSessionId
    RuntimeLauncherSessionId = [string]$runtimeLauncherSessionId
    RuntimeLauncherSessionIds = @(Get-ConfigValue -Object $routerSessionState -Name 'RuntimeLauncherSessionIds' -DefaultValue @())
    RuntimeMapPath = [string](Get-ConfigValue -Object $routerSessionState -Name 'RuntimeMapPath' -DefaultValue '')
    RuntimeMapExists = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RuntimeMapExists' -DefaultValue $false)
    RouterStatePath = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterStatePath' -DefaultValue '')
    RouterStateExists = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterStateExists' -DefaultValue $false)
    RouterStateAgeSeconds = [int](Get-ConfigValue -Object $routerSessionState -Name 'RouterStateAgeSeconds' -DefaultValue -1)
    RouterStateUpdatedAt = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterStateUpdatedAt' -DefaultValue '')
    RouterStatus = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterStatus' -DefaultValue '')
    RouterPid = [int](Get-ConfigValue -Object $routerSessionState -Name 'RouterPid' -DefaultValue 0)
    RouterPidExists = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterPidExists' -DefaultValue $false)
    RouterMutexName = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterMutexName' -DefaultValue '')
    RouterMutexHeld = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterMutexHeld' -DefaultValue $false)
    RouterRetryPendingSummary = $retryPendingSummary
    RouterInboxReadySummary = $routerInboxReadySummary
    OutputBlockSummary = $outputBlockSummary
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
    -ManifestExists:$manifestExists `
    -ManifestRunMode $manifestRunMode `
    -ManifestEnabledTargetIds @($manifestEnabledTargetIds) `
    -ManifestPublishReadyMissingTargetIds @($manifestPublishReadyMissingTargetIds) `
    -RouterSessionState ([string](Get-ConfigValue -Object $routerSessionState -Name 'State' -DefaultValue '')) `
    -RouterSessionMismatch:$routerSessionMismatch `
    -RouterLauncherSessionId $routerLauncherSessionId `
    -RuntimeLauncherSessionId $runtimeLauncherSessionId `
    -RetryPendingSummary $retryPendingSummary `
    -OutputBlockSummary $outputBlockSummary `
    -RecentRecommendation $recentRecommendation
$recommendationRetryBadge = Get-TargetAutoloopRetryReasonBadge -RecommendationSpec $recommendationSpec
$recommendationMode = Get-TargetAutoloopRecommendationMode -RecommendationSpec $recommendationSpec
$recommendationLevel = Get-TargetAutoloopRecommendationLevel -RecommendationSpec $recommendationSpec
$recommendationActionKey = [string](Get-ConfigValue -Object $recommendationSpec -Name 'ActionKey' -DefaultValue '')
$recommendationLabel = [string](Get-ConfigValue -Object $recommendationSpec -Name 'Label' -DefaultValue '권장 조치 없음')
$nextOperatorAction = if (Test-NonEmptyString $recommendationActionKey) {
    '{0} ({1})' -f $recommendationLabel, $recommendationActionKey
} else {
    $recommendationLabel
}
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
    $payload | Add-Member -NotePropertyName RecommendationLabel -NotePropertyValue $recommendationLabel -Force
    $payload | Add-Member -NotePropertyName NextOperatorAction -NotePropertyValue $nextOperatorAction -Force
    $payload | Add-Member -NotePropertyName NextOperatorActionKey -NotePropertyValue $recommendationActionKey -Force
    $payload | Add-Member -NotePropertyName NextOperatorActionLabel -NotePropertyValue $recommendationLabel -Force
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
    ('Manifest: exists={0} runMode={1} targets={2} enabled={3} publishReadyMissing={4}' -f
        [bool]$payload.ManifestExists,
        $(if (Test-NonEmptyString ([string]$payload.ManifestRunMode)) { [string]$payload.ManifestRunMode } else { '(none)' }),
        $(if (@($payload.ManifestTargetIds).Count -gt 0) { @($payload.ManifestTargetIds) -join ',' } else { '(none)' }),
        $(if (@($payload.ManifestEnabledTargetIds).Count -gt 0) { @($payload.ManifestEnabledTargetIds) -join ',' } else { '(none)' }),
        $(if (@($payload.ManifestPublishReadyMissingTargetIds).Count -gt 0) { @($payload.ManifestPublishReadyMissingTargetIds) -join ',' } else { '(none)' }))
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
    ('RouterSession: state={0} mismatch={1} router={2} runtime={3} routerStatus={4} routerPid={5} pidExists={6} mutexHeld={7} stateAgeSec={8}' -f `
        $(if (Test-NonEmptyString ([string]$payload.RouterSessionState)) { [string]$payload.RouterSessionState } else { '(none)' }),
        [bool]$payload.RouterSessionMismatch,
        $(if (Test-NonEmptyString ([string]$payload.RouterLauncherSessionId)) { [string]$payload.RouterLauncherSessionId } else { '(none)' }),
        $(if (Test-NonEmptyString ([string]$payload.RuntimeLauncherSessionId)) { [string]$payload.RuntimeLauncherSessionId } else { '(none)' }),
        $(if (Test-NonEmptyString ([string]$payload.RouterStatus)) { [string]$payload.RouterStatus } else { '(none)' }),
        [int]$payload.RouterPid,
        [bool]$payload.RouterPidExists,
        [bool]$payload.RouterMutexHeld,
        [int]$payload.RouterStateAgeSeconds)
    ('RouterRetryPending: count={0} targets={1} latestTarget={2} latestFailure={3} latestDebugLog={4}' -f `
        [int](Get-ConfigValue -Object $retryPendingSummary -Name 'Count' -DefaultValue 0),
        $(if (@(Get-ConfigValue -Object $retryPendingSummary -Name 'TargetIds' -DefaultValue @()).Count -gt 0) { @(Get-ConfigValue -Object $retryPendingSummary -Name 'TargetIds' -DefaultValue @()) -join ',' } else { '(none)' }),
        $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $retryPendingSummary -Name 'LatestTargetId' -DefaultValue ''))) { [string](Get-ConfigValue -Object $retryPendingSummary -Name 'LatestTargetId' -DefaultValue '') } else { '(none)' }),
        $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $retryPendingSummary -Name 'LatestFailureCategory' -DefaultValue ''))) { [string](Get-ConfigValue -Object $retryPendingSummary -Name 'LatestFailureCategory' -DefaultValue '') } else { '(none)' }),
        $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $retryPendingSummary -Name 'LatestDebugLogPath' -DefaultValue ''))) { [string](Get-ConfigValue -Object $retryPendingSummary -Name 'LatestDebugLogPath' -DefaultValue '') } else { '(none)' }))
    ('RouterInboxReady: count={0} targets={1} latestTarget={2} latestSession={3} latestCreatedAt={4} latestPath={5}' -f `
        [int](Get-ConfigValue -Object $routerInboxReadySummary -Name 'Count' -DefaultValue 0),
        $(if (@(Get-ConfigValue -Object $routerInboxReadySummary -Name 'TargetIds' -DefaultValue @()).Count -gt 0) { @(Get-ConfigValue -Object $routerInboxReadySummary -Name 'TargetIds' -DefaultValue @()) -join ',' } else { '(none)' }),
        $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $routerInboxReadySummary -Name 'LatestTargetId' -DefaultValue ''))) { [string](Get-ConfigValue -Object $routerInboxReadySummary -Name 'LatestTargetId' -DefaultValue '') } else { '(none)' }),
        $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $routerInboxReadySummary -Name 'LatestLauncherSessionId' -DefaultValue ''))) { [string](Get-ConfigValue -Object $routerInboxReadySummary -Name 'LatestLauncherSessionId' -DefaultValue '') } else { '(none)' }),
        $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $routerInboxReadySummary -Name 'LatestCreatedAt' -DefaultValue ''))) { [string](Get-ConfigValue -Object $routerInboxReadySummary -Name 'LatestCreatedAt' -DefaultValue '') } else { '(none)' }),
        $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $routerInboxReadySummary -Name 'LatestPath' -DefaultValue ''))) { [string](Get-ConfigValue -Object $routerInboxReadySummary -Name 'LatestPath' -DefaultValue '') } else { '(none)' }))
    ('OutputBlockSummary: checked={0} limit={1} readyUnaccepted={2} limitReady={3} routerBlocked={4} latestTarget={5} latestDispatch={6}' -f `
        [int](Get-ConfigValue -Object $outputBlockSummary -Name 'Count' -DefaultValue 0),
        [int](Get-ConfigValue -Object $outputBlockSummary -Name 'LimitReachedCount' -DefaultValue 0),
        [int](Get-ConfigValue -Object $outputBlockSummary -Name 'ReadyUnacceptedCount' -DefaultValue 0),
        [int](Get-ConfigValue -Object $outputBlockSummary -Name 'LimitReachedReadyUnacceptedCount' -DefaultValue 0),
        [int](Get-ConfigValue -Object $outputBlockSummary -Name 'RouterBlockedCount' -DefaultValue 0),
        $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $outputBlockSummary -Name 'LatestTargetId' -DefaultValue ''))) { [string](Get-ConfigValue -Object $outputBlockSummary -Name 'LatestTargetId' -DefaultValue '') } else { '(none)' }),
        $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $outputBlockSummary -Name 'LatestLastDispatchState' -DefaultValue ''))) { [string](Get-ConfigValue -Object $outputBlockSummary -Name 'LatestLastDispatchState' -DefaultValue '') } else { '(none)' }))
    ('ModeCapabilities: commandQueue=True typedWindowDispatch={0} routerReadyDispatch={1} maxConcurrentTargets={2} maxConcurrentSubmits={3}' -f $typedWindowDispatch, $routerReadyDispatch, $maxConcurrentTargets, $maxConcurrentSubmits)
    ('PauseSemantics: detect-and-queue=true dispatch-submit-blocked=true resume-drains-queue=true')
    ('WatcherRecommendation: ' + $watcherRecommendation)
    ('RecommendationAction: ' + $(if (Test-NonEmptyString $recommendationActionKey) { $recommendationActionKey } else { '(none)' }))
    ('RecommendationMode: ' + $recommendationMode)
    ('RecommendationLevel: ' + $recommendationLevel)
    ('RecommendationLabel: ' + $recommendationLabel)
    ('NextOperatorAction: ' + $nextOperatorAction)
    ('RecommendationDetail: ' + $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $recommendationSpec -Name 'Detail' -DefaultValue ''))) { [string](Get-ConfigValue -Object $recommendationSpec -Name 'Detail' -DefaultValue '') } else { '(none)' }))
    ('RecommendationRetryBadge: ' + [string](Get-ConfigValue -Object $recommendationRetryBadge -Name 'Text' -DefaultValue '재시도 사유: (없음)'))
    ('SmokeSummary: ' + $smokeSummaryText)
    ('CloseoutSummary: ' + $closeoutSummaryText)
    ('CloseoutNextStep: ' + $(if (Test-NonEmptyString $closeoutNextStep) { $closeoutNextStep } else { '(none)' }))
    ('SmokeReceiptPath: ' + [string](Get-ConfigValue -Object $smokeReceipt -Name 'Path' -DefaultValue [string]$statePaths.SmokeReceiptPath))
    ('State: ' + [string]$payload.State)
    ((
        'Counts: total={0} enabled={1} watcher={2} watchHealth={3} delay={4} delayState={5} controlAction={6} queued={7} waiting={8} failed={9} limit={10} retryPending={11} routerInboxReady={12} recAction={13} recOutcome={14} recMode={15} recLevel={16} recKey={17}' -f
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
            [int](Get-ConfigValue -Object $retryPendingSummary -Name 'Count' -DefaultValue 0),
            [int](Get-ConfigValue -Object $routerInboxReadySummary -Name 'Count' -DefaultValue 0),
            $(if (Test-NonEmptyString $recentRecommendationAction) { $recentRecommendationAction } else { 'none' }),
            $(if (Test-NonEmptyString $recentRecommendationOutcome) { $recentRecommendationOutcome } else { 'none' }),
            $recommendationMode,
            $recommendationLevel,
            $(if (Test-NonEmptyString $recommendationActionKey) { $recommendationActionKey } else { 'none' })
        ) + (' outputBlock={0}/{1}' -f [int](Get-ConfigValue -Object $outputBlockSummary -Name 'LimitReachedReadyUnacceptedCount' -DefaultValue 0), [int](Get-ConfigValue -Object $outputBlockSummary -Name 'ReadyUnacceptedCount' -DefaultValue 0)) + $(if (Test-NonEmptyString $watcherHealthDetail) { ' watchAge={0}' -f $watcherHealthDetail } else { '' }) + $(if (Test-NonEmptyString $watcherStopReason) { ' watchStop={0}' -f $watcherStopReason } else { '' }) + $(if (Test-NonEmptyString $lastHandledAction) { ' lastHandled={0}:{1}' -f $lastHandledAction, $(if (Test-NonEmptyString $lastHandledResult) { $lastHandledResult } else { 'none' }) } else { '' }) + $(if ($null -ne $minimumRemainingSeconds) { ' minRemaining={0}s' -f [int]$minimumRemainingSeconds } else { '' }) + $(if (Test-NonEmptyString $minimumRemainingTargetId) { ' delayTarget={0}' -f $minimumRemainingTargetId } else { '' }) + $(if (Test-NonEmptyString $minimumRemainingDelayRangeLabel) { ' delayRange={0}' -f $minimumRemainingDelayRangeLabel } else { '' }) + $(if (Test-NonEmptyString $minimumRemainingEligibleAt) { ' delayDueAt={0}' -f $minimumRemainingEligibleAt } else { '' }) + $(if (Test-NonEmptyString $smokeResult) { ' smoke={0}' -f $smokeResult } else { '' }) + $(if (Test-NonEmptyString $smokeProofLevel) { ' smokeProof={0}' -f $smokeProofLevel } else { '' }) + $(if (Test-NonEmptyString $smokeSource) { ' smokeSource={0}' -f $smokeSource } else { '' }) + $(if (Test-NonEmptyString $smokeTargetId) { ' smokeTarget={0}' -f $smokeTargetId } else { '' }) + $(if (Test-NonEmptyString $smokeAcceptanceState) { ' smokeAcceptance={0}' -f $smokeAcceptanceState } else { '' }) + $(if ($smokeMaxCycleCount -gt 0) { ' smokeCycle={0}/{1}' -f $smokeCycleCount, $smokeMaxCycleCount } else { '' }) + $(if (Test-NonEmptyString $smokeWatcherStopReason) { ' smokeStop={0}' -f $smokeWatcherStopReason } else { '' }) + $(if (Test-NonEmptyString $smokeAcceptanceReason) { ' smokeReason={0}' -f $smokeAcceptanceReason } else { '' }) + $(if (Test-NonEmptyString $closeoutState) { ' closeout={0}' -f $closeoutState } else { '' }) + $(if (Test-NonEmptyString $closeoutMode) { ' closeoutMode={0}' -f $closeoutMode } else { '' }) + $(if (Test-NonEmptyString $closeoutReason) { ' closeoutReason={0}' -f $closeoutReason } else { '' }))
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
