[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Nullable[double]]$MinRequiredSoakDurationMinutes = $null,
    [Nullable[int]]$MaxAllowedManualAttentionCount = $null,
    [Nullable[int]]$MaxAllowedWatcherRestartCount = $null,
    [Nullable[int]]$MaxAllowedPauseRequestCount = $null,
    [Nullable[int]]$MaxAllowedResumeRequestCount = $null,
    [Nullable[int]]$MinRequiredSnapshotCount = $null,
    [string]$RequiredFinalWatcherStatus = '',
    [Nullable[int]]$ExpectedPairCount = $null,
    [switch]$KnownLimitationsReviewed,
    [string]$KnownLimitationsReviewNote = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')

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

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not (Test-NonEmptyString $raw)) {
        return $null
    }

    if (Get-Command -Name 'ConvertFrom-RelayJsonText' -ErrorAction SilentlyContinue) {
        return (ConvertFrom-RelayJsonText -Json $raw)
    }

    return ($raw | ConvertFrom-Json)
}

function Invoke-PairedStatus {
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$ResolvedRunRoot
    )

    $output = @(
        & $PowerShellPath `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') `
            -ConfigPath $ResolvedConfigPath `
            -RunRoot $ResolvedRunRoot `
            -AsJson 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw ("Show-PairedExchangeStatus.ps1 failed: " + (($output | Out-String).Trim()))
    }

    $raw = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if (-not (Test-NonEmptyString $raw)) {
        throw 'Show-PairedExchangeStatus.ps1 returned no output.'
    }

    return ($raw | ConvertFrom-Json)
}

function Resolve-EffectiveThresholdValue {
    param(
        $ExplicitValue,
        $ReceiptThresholds,
        [Parameter(Mandatory)][string]$FieldName,
        $DefaultValue
    )

    if ($null -ne $ExplicitValue) {
        if ($ExplicitValue -is [string]) {
            if (Test-NonEmptyString $ExplicitValue) {
                return $ExplicitValue
            }
        }
        else {
            return $ExplicitValue
        }
    }

    $receiptValue = Get-ConfigValue -Object $ReceiptThresholds -Name $FieldName -DefaultValue $null
    if ($null -ne $receiptValue) {
        $text = [string]$receiptValue
        if (Test-NonEmptyString $text) {
            return $receiptValue
        }
    }

    return $DefaultValue
}

function ConvertTo-CanonicalPairPhase {
    param([string]$Phase)

    $value = ([string]$Phase).Trim().ToLowerInvariant()
    switch ($value) {
        '' { return '' }
        'waiting-handoff' { return 'waiting-partner-handoff' }
        'waiting-partner-handoff' { return 'waiting-partner-handoff' }
        'manual-review' { return 'manual-attention' }
        default { return $value }
    }
}

function New-CheckRow {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        $Expected = $null,
        $Observed = $null,
        [string]$Detail = ''
    )

    return [pscustomobject]@{
        Name     = $Name
        Passed   = $Passed
        Expected = $Expected
        Observed = $Observed
        Detail   = $Detail
    }
}

function Write-CloseoutSummaryText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Closeout,
        [Parameter(Mandatory)]$PairAgreements
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Four Pair Mixed Soak Closeout Summary')
    $lines.Add(('GeneratedAt: {0}' -f [string]$Closeout.GeneratedAt))
    $lines.Add(('RunRoot: {0}' -f [string]$Closeout.RunRoot))
    $lines.Add(('Passed: {0}' -f [bool]$Closeout.Passed))
    $lines.Add(('ReceiptPath: {0}' -f [string]$Closeout.ReceiptPath))
    $lines.Add(('DurationMinutes: {0}' -f [string](Get-ConfigValue -Object $Closeout.ReceiptSummary -Name 'ActualDurationMinutes' -DefaultValue 0)))
    $lines.Add(('SnapshotCount: {0}' -f [int](Get-ConfigValue -Object $Closeout.ReceiptSummary -Name 'SnapshotCount' -DefaultValue 0)))
    $lines.Add(('WatcherRestartCount: {0}' -f [int](Get-ConfigValue -Object $Closeout.ReceiptSummary -Name 'WatcherRestartCount' -DefaultValue 0)))
    $lines.Add(('PauseRequestCount: {0}' -f [int](Get-ConfigValue -Object $Closeout.ReceiptSummary -Name 'PauseRequestCount' -DefaultValue 0)))
    $lines.Add(('ResumeRequestCount: {0}' -f [int](Get-ConfigValue -Object $Closeout.ReceiptSummary -Name 'ResumeRequestCount' -DefaultValue 0)))
    $lines.Add(('ManualAttentionCount: {0}' -f [int](Get-ConfigValue -Object $Closeout.ReceiptSummary -Name 'MaxManualAttentionCount' -DefaultValue 0)))
    $lines.Add(('FinalWatcherStatus: {0}' -f [string](Get-ConfigValue -Object $Closeout.ReceiptSummary -Name 'FinalWatcherStatus' -DefaultValue '')))
    $lines.Add(('KnownLimitationsReviewed: {0}' -f [bool](Get-ConfigValue -Object $Closeout -Name 'KnownLimitationsReviewed' -DefaultValue $false)))
    if (Test-NonEmptyString ([string](Get-ConfigValue -Object $Closeout -Name 'KnownLimitationsReviewNote' -DefaultValue ''))) {
        $lines.Add(('KnownLimitationsReviewNote: {0}' -f [string](Get-ConfigValue -Object $Closeout -Name 'KnownLimitationsReviewNote' -DefaultValue '')))
    }

    $lines.Add('')
    $lines.Add('Pairs')
    foreach ($row in @($PairAgreements)) {
        $lines.Add((
                '{0}: phase={1} roundtrip={2} next={3} statusAgree={4}' -f
                [string]$row.PairId,
                [string]$row.StatusPhase,
                [int]$row.StatusRoundtrip,
                [string]$row.StatusNextHandoff,
                [bool]([bool]$row.ExistsInStatus -and [bool]$row.PhaseMatch -and [bool]$row.RoundtripMatch -and [bool]$row.NextHandoffMatch)
            ))
    }

    $lines.Add('')
    $lines.Add('Checks')
    foreach ($check in @(Get-ConfigValue -Object $Closeout -Name 'Checks' -DefaultValue @())) {
        $lines.Add((
                '{0}: passed={1} expected={2} observed={3}' -f
                [string](Get-ConfigValue -Object $check -Name 'Name' -DefaultValue ''),
                [bool](Get-ConfigValue -Object $check -Name 'Passed' -DefaultValue $false),
                [string](Get-ConfigValue -Object $check -Name 'Expected' -DefaultValue ''),
                [string](Get-ConfigValue -Object $check -Name 'Observed' -DefaultValue '')
            ))
    }

    Ensure-Directory -Path (Split-Path -Parent $Path)
    [System.IO.File]::WriteAllLines($Path, @($lines), [System.Text.UTF8Encoding]::new($false))
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$resolvedRunRoot = Resolve-PairRunRootPath -Root $root -RunRoot $RunRoot -PairTest $pairTest
$stateRoot = Join-Path $resolvedRunRoot '.state'
$receiptPath = Join-Path $stateRoot 'four-pair-soak-receipt.json'
$closeoutPath = Join-Path $stateRoot 'four-pair-soak-closeout.json'
$summaryPath = Join-Path $stateRoot 'four-pair-soak-summary.txt'
$receipt = Read-JsonObject -Path $receiptPath
if ($null -eq $receipt) {
    throw "soak receipt not found or empty: $receiptPath"
}

$receiptSummary = Get-ConfigValue -Object (Get-ConfigValue -Object $receipt -Name 'Execution' -DefaultValue $null) -Name 'Summary' -DefaultValue $null
if ($null -eq $receiptSummary) {
    throw "receipt summary missing: $receiptPath"
}

$receiptThresholds = Get-ConfigValue -Object $receipt -Name 'CloseoutThresholds' -DefaultValue $null
$effectiveThresholds = [pscustomobject]@{
    MinRequiredSoakDurationMinutes = [double](Resolve-EffectiveThresholdValue -ExplicitValue $MinRequiredSoakDurationMinutes -ReceiptThresholds $receiptThresholds -FieldName 'MinRequiredSoakDurationMinutes' -DefaultValue 60)
    MaxAllowedManualAttentionCount = [int](Resolve-EffectiveThresholdValue -ExplicitValue $MaxAllowedManualAttentionCount -ReceiptThresholds $receiptThresholds -FieldName 'MaxAllowedManualAttentionCount' -DefaultValue 4)
    MaxAllowedWatcherRestartCount  = [int](Resolve-EffectiveThresholdValue -ExplicitValue $MaxAllowedWatcherRestartCount -ReceiptThresholds $receiptThresholds -FieldName 'MaxAllowedWatcherRestartCount' -DefaultValue 1)
    MaxAllowedPauseRequestCount    = [int](Resolve-EffectiveThresholdValue -ExplicitValue $MaxAllowedPauseRequestCount -ReceiptThresholds $receiptThresholds -FieldName 'MaxAllowedPauseRequestCount' -DefaultValue 1)
    MaxAllowedResumeRequestCount   = [int](Resolve-EffectiveThresholdValue -ExplicitValue $MaxAllowedResumeRequestCount -ReceiptThresholds $receiptThresholds -FieldName 'MaxAllowedResumeRequestCount' -DefaultValue 1)
    MinRequiredSnapshotCount       = [int](Resolve-EffectiveThresholdValue -ExplicitValue $MinRequiredSnapshotCount -ReceiptThresholds $receiptThresholds -FieldName 'MinRequiredSnapshotCount' -DefaultValue 3)
    RequiredFinalWatcherStatus     = [string](Resolve-EffectiveThresholdValue -ExplicitValue $RequiredFinalWatcherStatus -ReceiptThresholds $receiptThresholds -FieldName 'RequiredFinalWatcherStatus' -DefaultValue 'stopped')
    ExpectedPairCount              = [int](Resolve-EffectiveThresholdValue -ExplicitValue $ExpectedPairCount -ReceiptThresholds $receiptThresholds -FieldName 'ExpectedPairCount' -DefaultValue 4)
}

$checks = New-Object System.Collections.Generic.List[object]
$checks.Add((New-CheckRow -Name 'receipt-execution-mode' -Passed ([string](Get-ConfigValue -Object $receipt -Name 'ExecutionMode' -DefaultValue '') -eq 'execute') -Expected 'execute' -Observed ([string](Get-ConfigValue -Object $receipt -Name 'ExecutionMode' -DefaultValue '')))) | Out-Null
$checks.Add((New-CheckRow -Name 'minimum-duration-minutes' -Passed ([double](Get-ConfigValue -Object $receiptSummary -Name 'ActualDurationMinutes' -DefaultValue 0.0) -ge [double]$effectiveThresholds.MinRequiredSoakDurationMinutes) -Expected ([double]$effectiveThresholds.MinRequiredSoakDurationMinutes) -Observed ([double](Get-ConfigValue -Object $receiptSummary -Name 'ActualDurationMinutes' -DefaultValue 0.0)))) | Out-Null
$checks.Add((New-CheckRow -Name 'maximum-manual-attention-count' -Passed ([int](Get-ConfigValue -Object $receiptSummary -Name 'MaxManualAttentionCount' -DefaultValue 0) -le [int]$effectiveThresholds.MaxAllowedManualAttentionCount) -Expected ([int]$effectiveThresholds.MaxAllowedManualAttentionCount) -Observed ([int](Get-ConfigValue -Object $receiptSummary -Name 'MaxManualAttentionCount' -DefaultValue 0)))) | Out-Null
$checks.Add((New-CheckRow -Name 'maximum-watcher-restart-count' -Passed ([int](Get-ConfigValue -Object $receiptSummary -Name 'WatcherRestartCount' -DefaultValue 0) -le [int]$effectiveThresholds.MaxAllowedWatcherRestartCount) -Expected ([int]$effectiveThresholds.MaxAllowedWatcherRestartCount) -Observed ([int](Get-ConfigValue -Object $receiptSummary -Name 'WatcherRestartCount' -DefaultValue 0)))) | Out-Null
$checks.Add((New-CheckRow -Name 'maximum-pause-request-count' -Passed ([int](Get-ConfigValue -Object $receiptSummary -Name 'PauseRequestCount' -DefaultValue 0) -le [int]$effectiveThresholds.MaxAllowedPauseRequestCount) -Expected ([int]$effectiveThresholds.MaxAllowedPauseRequestCount) -Observed ([int](Get-ConfigValue -Object $receiptSummary -Name 'PauseRequestCount' -DefaultValue 0)))) | Out-Null
$checks.Add((New-CheckRow -Name 'maximum-resume-request-count' -Passed ([int](Get-ConfigValue -Object $receiptSummary -Name 'ResumeRequestCount' -DefaultValue 0) -le [int]$effectiveThresholds.MaxAllowedResumeRequestCount) -Expected ([int]$effectiveThresholds.MaxAllowedResumeRequestCount) -Observed ([int](Get-ConfigValue -Object $receiptSummary -Name 'ResumeRequestCount' -DefaultValue 0)))) | Out-Null
$checks.Add((New-CheckRow -Name 'minimum-snapshot-count' -Passed ([int](Get-ConfigValue -Object $receiptSummary -Name 'SnapshotCount' -DefaultValue 0) -ge [int]$effectiveThresholds.MinRequiredSnapshotCount) -Expected ([int]$effectiveThresholds.MinRequiredSnapshotCount) -Observed ([int](Get-ConfigValue -Object $receiptSummary -Name 'SnapshotCount' -DefaultValue 0)))) | Out-Null
$checks.Add((New-CheckRow -Name 'required-final-watcher-status' -Passed ([string](Get-ConfigValue -Object $receiptSummary -Name 'FinalWatcherStatus' -DefaultValue '') -eq [string]$effectiveThresholds.RequiredFinalWatcherStatus) -Expected ([string]$effectiveThresholds.RequiredFinalWatcherStatus) -Observed ([string](Get-ConfigValue -Object $receiptSummary -Name 'FinalWatcherStatus' -DefaultValue '')))) | Out-Null
$checks.Add((New-CheckRow -Name 'expected-pair-count' -Passed ((@(Get-ConfigValue -Object $receiptSummary -Name 'FinalPairs' -DefaultValue @())).Count -eq [int]$effectiveThresholds.ExpectedPairCount) -Expected ([int]$effectiveThresholds.ExpectedPairCount) -Observed (@(Get-ConfigValue -Object $receiptSummary -Name 'FinalPairs' -DefaultValue @())).Count)) | Out-Null

$powershellPath = Resolve-PowerShellExecutable
$status = Invoke-PairedStatus -PowerShellPath $powershellPath -ResolvedConfigPath $resolvedConfigPath -ResolvedRunRoot $resolvedRunRoot
$statusPairsById = @{}
foreach ($row in @($status.Pairs)) {
    $pairId = [string](Get-ConfigValue -Object $row -Name 'PairId' -DefaultValue '')
    if (Test-NonEmptyString $pairId) {
        $statusPairsById[$pairId] = $row
    }
}

$receiptPairs = @(Get-ConfigValue -Object $receiptSummary -Name 'FinalPairs' -DefaultValue @())
$pairAgreements = New-Object System.Collections.Generic.List[object]
foreach ($receiptPair in @($receiptPairs)) {
    $pairId = [string](Get-ConfigValue -Object $receiptPair -Name 'PairId' -DefaultValue '')
    $statusPair = Get-ConfigValue -Object $statusPairsById -Name $pairId -DefaultValue $null
    $receiptPhase = ConvertTo-CanonicalPairPhase -Phase ([string](Get-ConfigValue -Object $receiptPair -Name 'CurrentPhase' -DefaultValue ''))
    $statusPhase = if ($null -ne $statusPair) {
        ConvertTo-CanonicalPairPhase -Phase ([string](Get-ConfigValue -Object $statusPair -Name 'CurrentPhase' -DefaultValue ''))
    }
    else {
        ''
    }
    $pairAgreements.Add([pscustomobject]@{
            PairId            = $pairId
            ExistsInStatus    = ($null -ne $statusPair)
            PhaseMatch        = (($null -ne $statusPair) -and ($receiptPhase -eq $statusPhase))
            RoundtripMatch    = (($null -ne $statusPair) -and ([int](Get-ConfigValue -Object $receiptPair -Name 'RoundtripCount' -DefaultValue 0) -eq [int](Get-ConfigValue -Object $statusPair -Name 'RoundtripCount' -DefaultValue 0)))
            NextHandoffMatch  = (($null -ne $statusPair) -and ([string](Get-ConfigValue -Object $receiptPair -Name 'NextExpectedHandoff' -DefaultValue '') -eq [string](Get-ConfigValue -Object $statusPair -Name 'NextExpectedHandoff' -DefaultValue '')))
            ReceiptPhase      = $receiptPhase
            StatusPhase       = $statusPhase
            ReceiptRoundtrip  = [int](Get-ConfigValue -Object $receiptPair -Name 'RoundtripCount' -DefaultValue 0)
            StatusRoundtrip   = if ($null -ne $statusPair) { [int](Get-ConfigValue -Object $statusPair -Name 'RoundtripCount' -DefaultValue 0) } else { 0 }
            ReceiptNextHandoff = [string](Get-ConfigValue -Object $receiptPair -Name 'NextExpectedHandoff' -DefaultValue '')
            StatusNextHandoff  = if ($null -ne $statusPair) { [string](Get-ConfigValue -Object $statusPair -Name 'NextExpectedHandoff' -DefaultValue '') } else { '' }
        }) | Out-Null
}

$watcherStatusMatch = ([string](Get-ConfigValue -Object $status.Watcher -Name 'Status' -DefaultValue '') -eq [string](Get-ConfigValue -Object $receiptSummary -Name 'FinalWatcherStatus' -DefaultValue ''))
$pairAgreementMismatchCount = (@($pairAgreements | Where-Object { -not ([bool]$_.ExistsInStatus -and [bool]$_.PhaseMatch -and [bool]$_.RoundtripMatch -and [bool]$_.NextHandoffMatch) })).Count
$pairAgreementPassed = ($pairAgreementMismatchCount -eq 0)
$checks.Add((New-CheckRow -Name 'status-watcher-match' -Passed $watcherStatusMatch -Expected ([string](Get-ConfigValue -Object $receiptSummary -Name 'FinalWatcherStatus' -DefaultValue '')) -Observed ([string](Get-ConfigValue -Object $status.Watcher -Name 'Status' -DefaultValue '')))) | Out-Null
$checks.Add((New-CheckRow -Name 'status-pair-agreement' -Passed $pairAgreementPassed -Expected 'receipt pairs match current paired status' -Observed $pairAgreementMismatchCount)) | Out-Null

$passed = (@($checks | Where-Object { -not [bool]$_.Passed })).Count -eq 0
$pairAgreementArray = [object[]]@($pairAgreements | ForEach-Object { $_ })
$checkArray = [object[]]@($checks | ForEach-Object { $_ })
$statusAgreement = New-Object PSObject
$statusAgreement | Add-Member -NotePropertyName 'WatcherStatusMatch' -NotePropertyValue $watcherStatusMatch
$statusAgreement | Add-Member -NotePropertyName 'PairAgreementPassed' -NotePropertyValue $pairAgreementPassed
$statusAgreement | Add-Member -NotePropertyName 'PairAgreements' -NotePropertyValue $pairAgreementArray

$closeout = New-Object PSObject
$closeout | Add-Member -NotePropertyName 'SchemaVersion' -NotePropertyValue '1.0.0'
$closeout | Add-Member -NotePropertyName 'GeneratedAt' -NotePropertyValue ((Get-Date).ToString('o'))
$closeout | Add-Member -NotePropertyName 'ConfigPath' -NotePropertyValue $resolvedConfigPath
$closeout | Add-Member -NotePropertyName 'RunRoot' -NotePropertyValue $resolvedRunRoot
$closeout | Add-Member -NotePropertyName 'ReceiptPath' -NotePropertyValue $receiptPath
$closeout | Add-Member -NotePropertyName 'Passed' -NotePropertyValue $passed
$closeout | Add-Member -NotePropertyName 'KnownLimitationsReviewed' -NotePropertyValue ([bool]$KnownLimitationsReviewed)
$closeout | Add-Member -NotePropertyName 'KnownLimitationsReviewNote' -NotePropertyValue $KnownLimitationsReviewNote
$closeout | Add-Member -NotePropertyName 'SummaryPath' -NotePropertyValue $summaryPath
$closeout | Add-Member -NotePropertyName 'EffectiveThresholds' -NotePropertyValue $effectiveThresholds
$closeout | Add-Member -NotePropertyName 'ReceiptSummary' -NotePropertyValue $receiptSummary
$closeout | Add-Member -NotePropertyName 'StatusAgreement' -NotePropertyValue $statusAgreement
$closeout | Add-Member -NotePropertyName 'Checks' -NotePropertyValue $checkArray

Ensure-Directory -Path $stateRoot
$closeout | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $closeoutPath -Encoding UTF8
Write-CloseoutSummaryText -Path $summaryPath -Closeout $closeout -PairAgreements $pairAgreementArray

if ($AsJson) {
    $closeout | ConvertTo-Json -Depth 10
}
else {
    $closeout
}
