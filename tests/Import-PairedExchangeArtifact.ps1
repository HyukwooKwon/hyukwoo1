[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$SummarySourcePath,
    [Parameter(Mandatory)][string]$ReviewZipSourcePath,
    [string]$SourcePublishReadyPath = '',
    [string]$SourcePublishedAt = '',
    [string]$SourcePublishAttemptId = '',
    [int]$SourcePublishSequence = 0,
    [string]$SourcePublishCycleId = '',
    [string]$SourceValidationCompletedAt = '',
    [string]$SourceSummarySha256 = '',
    [string]$SourceReviewZipSha256 = '',
    [string]$ImportMode = 'manual-import',
    [switch]$KeepZipFileName,
    [switch]$Overwrite,
    [switch]$DryRun,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function Get-FileInfoSummary {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [pscustomobject]@{
        Name         = $item.Name
        FullName     = $item.FullName
        Exists       = $true
        ModifiedAt   = $item.LastWriteTime.ToString('o')
        ModifiedAtUtc = $item.LastWriteTimeUtc.ToString('o')
        SizeBytes    = if ($item.PSIsContainer) { 0 } else { [int64]$item.Length }
    }
}

function Test-ZipArchiveReadable {
    param([Parameter(Mandatory)][string]$Path)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    }
    catch {
    }

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $null = $archive.Entries.Count
        }
        finally {
            if ($null -ne $archive) {
                $archive.Dispose()
            }
        }

        return [pscustomobject]@{
            Ok = $true
            ErrorMessage = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Ok = $false
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Resolve-RequestedPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function New-ReviewZipName {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$TargetId
    )

    $resolved = $Pattern.Replace('{TargetId}', $TargetId).Replace('{Guid}', ([guid]::NewGuid().ToString()))
    return [regex]::Replace($resolved, '\{([^}]+)\}', {
        param($match)

        $format = [string]$match.Groups[1].Value
        try {
            return (Get-Date -Format $format)
        }
        catch {
            return $match.Value
        }
    })
}

function Get-TargetStatusSnapshot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId
    )

    $json = & (Join-Path $Root 'tests\Show-PairedExchangeStatus.ps1') -ConfigPath $ConfigPath -RunRoot $RunRoot -AsJson
    $payload = $json | ConvertFrom-Json
    $row = @($payload.Targets | Where-Object { [string]$_.TargetId -eq [string]$TargetId } | Select-Object -First 1)
    return [pscustomobject]@{
        Counts = $payload.Counts
        Target = if ($row.Count -gt 0) { $row[0] } else { $null }
    }
}

function Add-UniqueListItem {
    param(
        [Parameter(Mandatory)]$List,
        [string]$Value
    )

    if (-not (Test-NonEmptyString $Value)) {
        return
    }

    if ($List -notcontains [string]$Value) {
        [void]$List.Add([string]$Value)
    }
}

function Get-NormalizedFullPath {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    }
    catch {
        return ([string]$Path).ToLowerInvariant()
    }
}

function Test-NormalizedPathMatch {
    param(
        [string]$Left,
        [string]$Right
    )

    if (-not (Test-NonEmptyString $Left) -or -not (Test-NonEmptyString $Right)) {
        return $false
    }

    return ((Get-NormalizedFullPath -Path $Left) -eq (Get-NormalizedFullPath -Path $Right))
}

function Test-RemovableStaleError {
    param(
        $ErrorDoc = $null,
        [string]$RequestPath = '',
        [string]$SummaryPath = '',
        [string]$SourceSummaryPath = '',
        [string]$SourceReviewZipPath = '',
        [string]$PublishReadyPath = ''
    )

    if ($null -eq $ErrorDoc) {
        return $false
    }

    $reason = [string](Get-ConfigValue -Object $ErrorDoc -Name 'Reason' -DefaultValue '')
    if ($reason -notin @('codex-exec-timeout', 'summary-missing-after-exec', 'summary-stale-after-exec', 'zip-missing-after-exec', 'zip-stale-after-exec', 'source-outbox-incomplete-after-exec')) {
        return $false
    }

    $errorRequestPath = [string](Get-ConfigValue -Object $ErrorDoc -Name 'RequestPath' -DefaultValue '')
    $requestMatched = $false
    if (Test-NonEmptyString $errorRequestPath -or Test-NonEmptyString $RequestPath) {
        if (-not (Test-NormalizedPathMatch -Left $errorRequestPath -Right $RequestPath)) {
            return $false
        }
        $requestMatched = $true
    }

    $hasSourceIdentity = $false
    foreach ($pair in @(
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'SourceSummaryPath' -DefaultValue ''), $SourceSummaryPath),
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'SourceReviewZipPath' -DefaultValue ''), $SourceReviewZipPath),
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'PublishReadyPath' -DefaultValue ''), $PublishReadyPath)
        )) {
        $left = [string]$pair[0]
        $right = [string]$pair[1]
        if (Test-NonEmptyString $left -or Test-NonEmptyString $right) {
            $hasSourceIdentity = $true
            if (-not (Test-NormalizedPathMatch -Left $left -Right $right)) {
                return $false
            }
        }
    }

    if ($hasSourceIdentity) {
        return $true
    }

    return $requestMatched
}

function Get-ExistingContractArtifacts {
    param(
        [Parameter(Mandatory)]$Contract,
        [Parameter(Mandatory)][string]$DestinationZipPath
    )

    return [pscustomobject]@{
        Summary        = Get-FileInfoSummary -Path $Contract.SummaryPath
        DestinationZip = Get-FileInfoSummary -Path $DestinationZipPath
        Done           = Get-FileInfoSummary -Path $Contract.DonePath
        Error          = Get-FileInfoSummary -Path $Contract.ErrorPath
        Result         = Get-FileInfoSummary -Path $Contract.ResultPath
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$resolvedRunRoot = Resolve-PairRunRootPath -Root $root -RunRoot $RunRoot -PairTest $pairTest
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "manifest not found: $manifestPath"
}

$manifest = Read-JsonObject -Path $manifestPath
$targetEntry = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq [string]$TargetId } | Select-Object -First 1)
if ($targetEntry.Count -eq 0) {
    throw "target not found in manifest: $TargetId"
}
$targetEntry = $targetEntry[0]

$requestPath = if (Test-NonEmptyString ([string](Get-ConfigValue -Object $targetEntry -Name 'RequestPath' -DefaultValue ''))) {
    [string](Get-ConfigValue -Object $targetEntry -Name 'RequestPath' -DefaultValue '')
}
else {
    Join-Path ([string]$targetEntry.TargetFolder) ([string]$pairTest.HeadlessExec.RequestFileName)
}
$request = if (Test-Path -LiteralPath $requestPath) { Read-JsonObject -Path $requestPath } else { $null }
$contract = Get-TargetContractPaths -PairTest $pairTest -TargetEntry $targetEntry -Request $request
$publishReadyPath = [string](Get-ConfigValue -Object $request -Name 'PublishReadyPath' -DefaultValue '')

$resolvedSummarySourcePath = Resolve-RequestedPath -Path $SummarySourcePath
$resolvedReviewZipSourcePath = Resolve-RequestedPath -Path $ReviewZipSourcePath
$summarySourceInfo = Get-FileInfoSummary -Path $resolvedSummarySourcePath
$reviewZipSourceInfo = Get-FileInfoSummary -Path $resolvedReviewZipSourcePath
$summaryZipDeltaSeconds = if ($null -ne $summarySourceInfo -and $null -ne $reviewZipSourceInfo) {
    [math]::Round(((Get-Item -LiteralPath $resolvedReviewZipSourcePath).LastWriteTimeUtc - (Get-Item -LiteralPath $resolvedSummarySourcePath).LastWriteTimeUtc).TotalSeconds, 3)
}
else {
    $null
}

$issues = New-Object System.Collections.Generic.List[string]
$blockingIssues = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path -LiteralPath $resolvedSummarySourcePath -PathType Leaf)) {
    $issues.Add('summary-source-missing')
}
if (-not (Test-Path -LiteralPath $resolvedReviewZipSourcePath -PathType Leaf)) {
    $issues.Add('review-zip-source-missing')
}
if ([System.IO.Path]::GetExtension($resolvedReviewZipSourcePath) -notin @('.zip', '.ZIP')) {
    $issues.Add('review-zip-source-not-zip')
}
elseif (Test-Path -LiteralPath $resolvedReviewZipSourcePath -PathType Leaf) {
    $reviewZipValidation = Test-ZipArchiveReadable -Path $resolvedReviewZipSourcePath
    if (-not [bool]$reviewZipValidation.Ok) {
        $issues.Add('review-zip-source-invalid')
    }
}
$summaryForbiddenArtifact = Get-ForbiddenArtifactTextFileMatch `
    -Path $resolvedSummarySourcePath `
    -LiteralList @($pairTest.ForbiddenArtifactLiterals) `
    -RegexPatternList @($pairTest.ForbiddenArtifactRegexes)
if ([bool]$summaryForbiddenArtifact.Found) {
    $issues.Add('summary-source-forbidden-artifact')
}
$reviewZipForbiddenArtifact = Get-ForbiddenArtifactZipMatch `
    -Path $resolvedReviewZipSourcePath `
    -LiteralList @($pairTest.ForbiddenArtifactLiterals) `
    -RegexPatternList @($pairTest.ForbiddenArtifactRegexes)
if ([bool]$reviewZipForbiddenArtifact.Found) {
    $issues.Add('review-zip-source-forbidden-artifact')
}
if (-not (Test-NonEmptyString $contract.TargetFolder)) {
    $issues.Add('target-folder-missing-from-contract')
}
if ($summaryZipDeltaSeconds -is [double] -and $summaryZipDeltaSeconds -gt [double]$pairTest.SummaryZipMaxSkewSeconds) {
    $warnings.Add('manual-copy-would-be-summary-stale')
}
if (Test-Path -LiteralPath $contract.ErrorPath) {
    $warnings.Add('stale-error-marker-present')
}

$destinationZipName = if ($KeepZipFileName) {
    [System.IO.Path]::GetFileName($resolvedReviewZipSourcePath)
}
else {
    New-ReviewZipName -Pattern ([string]$pairTest.ReviewZipPattern) -TargetId ([string]$targetEntry.TargetId)
}
$destinationZipPath = Join-Path $contract.ReviewFolderPath $destinationZipName
$manualCopyLikelyState = if ($summaryZipDeltaSeconds -is [double] -and $summaryZipDeltaSeconds -gt [double]$pairTest.SummaryZipMaxSkewSeconds) {
    'summary-stale'
}
else {
    'ready-to-forward-or-forwarded'
}

$preImportStatus = Get-TargetStatusSnapshot -Root $root -ConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -TargetId ([string]$targetEntry.TargetId)
$existingContract = Get-ExistingContractArtifacts -Contract $contract -DestinationZipPath $destinationZipPath
$overwriteTargets = New-Object System.Collections.Generic.List[string]
if ($null -ne $existingContract.Summary) {
    $overwriteTargets.Add('summary.txt')
}
if ($null -ne $existingContract.DestinationZip) {
    $overwriteTargets.Add('review zip')
}
if ($null -ne $existingContract.Done) {
    $overwriteTargets.Add('done.json')
}
if ($null -ne $existingContract.Result) {
    $overwriteTargets.Add('result.json')
}
$blockingLatestState = if ($null -ne $preImportStatus.Target) { [string]$preImportStatus.Target.LatestState } else { '' }
$guardedStates = @('ready-to-forward', 'forwarded', 'error-present')
$requiresOverwrite = ($overwriteTargets.Count -gt 0) -or ($blockingLatestState -in $guardedStates)
if ($blockingLatestState -in $guardedStates) {
    Add-UniqueListItem -List $warnings -Value ('current-target-state-' + $blockingLatestState)
}
if ($overwriteTargets.Count -gt 0) {
    Add-UniqueListItem -List $warnings -Value 'existing-contract-files-present'
}
if ($Overwrite) {
    Add-UniqueListItem -List $warnings -Value 'overwrite-enabled'
}
elseif ($requiresOverwrite -and -not $DryRun) {
    if ($blockingLatestState -in $guardedStates) {
        $blockingIssues.Add('overwrite-required-existing-target-state')
    }
    if ($overwriteTargets.Count -gt 0) {
        $blockingIssues.Add('overwrite-required-existing-contract-files')
    }
}
$preflightLines = New-Object System.Collections.Generic.List[string]
$preflightLines.Add(('Target: {0} / pair={1} / partner={2}' -f [string]$targetEntry.TargetId, [string]$targetEntry.PairId, [string]$targetEntry.PartnerTargetId))
$preflightLines.Add(('Current LatestState: {0}' -f $(if (Test-NonEmptyString $blockingLatestState) { $blockingLatestState } else { '(unknown)' })))
$preflightLines.Add(('Current LatestZip: {0}' -f $(if ($null -ne $preImportStatus.Target -and (Test-NonEmptyString ([string]$preImportStatus.Target.LatestZipName))) { ([string]$preImportStatus.Target.LatestZipName + ' @ ' + [string]$preImportStatus.Target.LatestZipModifiedAt) } else { '(none)' })))
$preflightLines.Add('Submit rule: source summary/source zip는 입력만 담당합니다. paired submit은 target folder contract(summary/reviewfile/done/result)를 쓸 때만 완료됩니다.')
$preflightLines.Add(('Import writes: {0}, {1}, {2}, {3}' -f $contract.SummaryPath, $destinationZipPath, $contract.DonePath, $contract.ResultPath))
$preflightLines.Add(('Would overwrite: {0}' -f $(if ($overwriteTargets.Count -gt 0) { $overwriteTargets -join ', ' } else { '(none)' })))
$preflightLines.Add(('Overwrite required: {0}' -f $(if ($requiresOverwrite) { 'yes' } else { 'no' })))
$preflightLines.Add(('Overwrite requested: {0}' -f $(if ($Overwrite) { 'yes' } else { 'no' })))
$preflightLines.Add(('Conflict summary: {0}' -f $(if ($blockingLatestState -in $guardedStates) { "현재 target은 $blockingLatestState 상태입니다." } elseif ($overwriteTargets.Count -gt 0) { '현재 contract 파일이 이미 존재합니다.' } else { '(none)' })))
$preflightLines.Add(('Manual copy likely state: {0}' -f $manualCopyLikelyState))
$preflightLines.Add(('Warnings: {0}' -f $(if ($warnings.Count -gt 0) { $warnings -join ', ' } else { '(none)' })))
$preflightLines.Add(('ForbiddenArtifactSummary: {0}' -f $(if ([bool]$summaryForbiddenArtifact.Found) { ('detected type=' + [string]$summaryForbiddenArtifact.MatchKind + ' pattern=' + [string]$summaryForbiddenArtifact.Pattern + ' match=' + [string]$summaryForbiddenArtifact.MatchText) } else { '(clean)' })))
$preflightLines.Add(('ForbiddenArtifactReviewZip: {0}' -f $(if ([bool]$reviewZipForbiddenArtifact.Found) { ('detected type=' + [string]$reviewZipForbiddenArtifact.MatchKind + ' pattern=' + [string]$reviewZipForbiddenArtifact.Pattern + ' match=' + [string]$reviewZipForbiddenArtifact.MatchText + ' entry=' + [string]$reviewZipForbiddenArtifact.EntryPath) } else { '(clean)' })))
$preflightLines.Add(('BlockingIssues: {0}' -f $(if ($blockingIssues.Count -gt 0) { $blockingIssues -join ', ' } else { '(none)' })))
$effectiveIssues = New-Object System.Collections.Generic.List[string]
foreach ($issue in $issues) {
    [void]$effectiveIssues.Add([string]$issue)
}
foreach ($issue in $blockingIssues) {
    [void]$effectiveIssues.Add([string]$issue)
}
$completedAt = ''
$postImportStatus = $null

if ($effectiveIssues.Count -eq 0 -and -not $DryRun) {
    Ensure-Directory -Path $contract.TargetFolder
    Ensure-Directory -Path $contract.ReviewFolderPath

    $summaryText = [System.IO.File]::ReadAllText($resolvedSummarySourcePath)
    [System.IO.File]::WriteAllText($contract.SummaryPath, $summaryText, (New-Utf8NoBomEncoding))

    $sourceZipFullPath = [System.IO.Path]::GetFullPath($resolvedReviewZipSourcePath)
    $destinationZipFullPath = [System.IO.Path]::GetFullPath($destinationZipPath)
    if ($sourceZipFullPath -ne $destinationZipFullPath) {
        Copy-Item -LiteralPath $resolvedReviewZipSourcePath -Destination $destinationZipPath -Force
    }

    $completedAt = (Get-Date).ToString('o')
    $resultPayload = [ordered]@{
        CompletedAt            = $completedAt
        Mode                   = [string]$ImportMode
        PairId                 = [string]$targetEntry.PairId
        TargetId               = [string]$targetEntry.TargetId
        PartnerTargetId        = [string]$targetEntry.PartnerTargetId
        RunRoot                = $resolvedRunRoot
        RequestPath            = $contract.RequestPath
        SummarySourcePath      = $resolvedSummarySourcePath
        ReviewZipSourcePath    = $resolvedReviewZipSourcePath
        SourcePublishReadyPath = [string]$SourcePublishReadyPath
        SourcePublishedAt      = [string]$SourcePublishedAt
        SourcePublishAttemptId = [string]$SourcePublishAttemptId
        SourcePublishSequence  = [int]$SourcePublishSequence
        SourcePublishCycleId   = [string]$SourcePublishCycleId
        SourceValidationCompletedAt = [string]$SourceValidationCompletedAt
        SourceSummarySha256    = [string]$SourceSummarySha256
        SourceReviewZipSha256  = [string]$SourceReviewZipSha256
        SummaryPath            = $contract.SummaryPath
        LatestZipPath          = $destinationZipPath
        ImportedZipPath        = $destinationZipPath
        KeepZipFileName        = [bool]$KeepZipFileName
        ReviewZipPattern       = [string]$pairTest.ReviewZipPattern
        SummaryZipDeltaSeconds = $summaryZipDeltaSeconds
        SummaryZipMaxSkewSeconds = [double]$pairTest.SummaryZipMaxSkewSeconds
    }
    $resultPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $contract.ResultPath -Encoding UTF8

    $donePayload = [ordered]@{
        CompletedAt            = $completedAt
        Mode                   = [string]$ImportMode
        PairId                 = [string]$targetEntry.PairId
        TargetId               = [string]$targetEntry.TargetId
        PartnerTargetId        = [string]$targetEntry.PartnerTargetId
        RunRoot                = $resolvedRunRoot
        RequestPath            = $contract.RequestPath
        SummarySourcePath      = $resolvedSummarySourcePath
        ReviewZipSourcePath    = $resolvedReviewZipSourcePath
        SourcePublishReadyPath = [string]$SourcePublishReadyPath
        SourcePublishedAt      = [string]$SourcePublishedAt
        SourcePublishAttemptId = [string]$SourcePublishAttemptId
        SourcePublishSequence  = [int]$SourcePublishSequence
        SourcePublishCycleId   = [string]$SourcePublishCycleId
        SourceValidationCompletedAt = [string]$SourceValidationCompletedAt
        SourceSummarySha256    = [string]$SourceSummarySha256
        SourceReviewZipSha256  = [string]$SourceReviewZipSha256
        SummaryPath            = $contract.SummaryPath
        LatestZipPath          = $destinationZipPath
        ResultPath             = $contract.ResultPath
        KeepZipFileName        = [bool]$KeepZipFileName
        ManualCopyLikelyState  = $manualCopyLikelyState
    }
    $donePayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $contract.DonePath -Encoding UTF8
    if (Test-Path -LiteralPath $contract.ErrorPath) {
        $existingError = $null
        try {
            $existingError = Read-JsonObject -Path $contract.ErrorPath
        }
        catch {
            $existingError = $null
        }
        if (Test-RemovableStaleError -ErrorDoc $existingError -RequestPath $contract.RequestPath -SummaryPath $contract.SummaryPath -SourceSummaryPath $resolvedSummarySourcePath -SourceReviewZipPath $resolvedReviewZipSourcePath -PublishReadyPath $publishReadyPath) {
            Remove-Item -LiteralPath $contract.ErrorPath -Force -ErrorAction SilentlyContinue
        }
    }

    $postImportStatus = Get-TargetStatusSnapshot -Root $root -ConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -TargetId ([string]$targetEntry.TargetId)
}

$status = [pscustomobject]@{
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    DryRun = [bool]$DryRun
    KeepZipFileName = [bool]$KeepZipFileName
    Overwrite = [bool]$Overwrite
    Validation = [pscustomobject]@{
        Ok = ($effectiveIssues.Count -eq 0)
        Issues = @($effectiveIssues)
        InputIssues = @($issues)
        BlockingIssues = @($blockingIssues)
        Warnings = @($warnings)
        ManualCopyLikelyState = $manualCopyLikelyState
        ImportWritesDoneFile = $true
        RequiresOverwrite = [bool]$requiresOverwrite
        OverwriteTargets = @($overwriteTargets)
        BlockingLatestState = $blockingLatestState
        ForbiddenArtifactChecks = [pscustomobject]@{
            Summary = $summaryForbiddenArtifact
            ReviewZip = $reviewZipForbiddenArtifact
        }
    }
    Target = [pscustomobject]@{
        PairId = [string]$targetEntry.PairId
        RoleName = [string](Get-ConfigValue -Object $request -Name 'RoleName' -DefaultValue ([string](Get-ConfigValue -Object $targetEntry -Name 'RoleName' -DefaultValue '')))
        TargetId = [string]$targetEntry.TargetId
        PartnerTargetId = [string]$targetEntry.PartnerTargetId
    }
    Sources = [pscustomobject]@{
        Summary = $summarySourceInfo
        ReviewZip = $reviewZipSourceInfo
        SummaryZipDeltaSeconds = $summaryZipDeltaSeconds
    }
    SourcePublish = [pscustomobject]@{
        PublishReadyPath = [string]$SourcePublishReadyPath
        PublishedAt = [string]$SourcePublishedAt
        AttemptId = [string]$SourcePublishAttemptId
        PublishSequence = [int]$SourcePublishSequence
        PublishCycleId = [string]$SourcePublishCycleId
        ValidationCompletedAt = [string]$SourceValidationCompletedAt
        SummarySha256 = [string]$SourceSummarySha256
        ReviewZipSha256 = [string]$SourceReviewZipSha256
    }
    Preflight = [pscustomobject]@{
        SummaryLines = @($preflightLines)
        CurrentLatestState = $blockingLatestState
        CurrentLatestZipName = if ($null -ne $preImportStatus.Target) { [string]$preImportStatus.Target.LatestZipName } else { '' }
        CurrentLatestZipModifiedAt = if ($null -ne $preImportStatus.Target) { [string]$preImportStatus.Target.LatestZipModifiedAt } else { '' }
        RequiresOverwrite = [bool]$requiresOverwrite
        OverwriteRequested = [bool]$Overwrite
        OverwriteTargets = @($overwriteTargets)
    }
    Contract = [pscustomobject]@{
        TargetFolder = $contract.TargetFolder
        SummaryPath = $contract.SummaryPath
        ReviewFolderPath = $contract.ReviewFolderPath
        RequestPath = $contract.RequestPath
        DonePath = $contract.DonePath
        ErrorPath = $contract.ErrorPath
        ResultPath = $contract.ResultPath
        DestinationZipName = $destinationZipName
        DestinationZipPath = $destinationZipPath
        ReviewZipPattern = [string]$pairTest.ReviewZipPattern
        SummaryZipMaxSkewSeconds = [double]$pairTest.SummaryZipMaxSkewSeconds
    }
    Existing = [pscustomobject]@{
        Summary = $existingContract.Summary
        DestinationZip = $existingContract.DestinationZip
        Done = $existingContract.Done
        Error = $existingContract.Error
        Result = $existingContract.Result
    }
    PreImportStatus = $preImportStatus.Target
    PostImportStatus = if ($null -ne $postImportStatus) { $postImportStatus.Target } else { $null }
    Counts = if ($null -ne $postImportStatus) { $postImportStatus.Counts } else { $preImportStatus.Counts }
    CompletedAt = $completedAt
}

if ($AsJson) {
    $status | ConvertTo-Json -Depth 8
    if ($effectiveIssues.Count -gt 0) {
        $host.SetShouldExit(1)
    }
    return
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('Paired Exchange Artifact Import')
$lines.Add(('Mode: {0}' -f $(if ($DryRun) { 'dry-run' } else { 'import' })))
$lines.Add(('RunRoot: {0}' -f $status.RunRoot))
$lines.Add(('Target: {0} / pair={1} / partner={2}' -f $status.Target.TargetId, $status.Target.PairId, $status.Target.PartnerTargetId))
$lines.Add(('Sources: summary={0} zip={1}' -f $resolvedSummarySourcePath, $resolvedReviewZipSourcePath))
$lines.Add('Submit rule: source summary/source zip만 만들면 watcher는 움직이지 않습니다. 이 명령이 target folder contract에 기록할 때 paired submit이 완료됩니다.')
$lines.Add(('Contract: summary={0} reviewFolder={1} destZip={2}' -f $status.Contract.SummaryPath, $status.Contract.ReviewFolderPath, $status.Contract.DestinationZipPath))
$lines.Add(('Manual copy likely state: {0}' -f $status.Validation.ManualCopyLikelyState))
$lines.Add(('Overwrite required: {0}' -f $(if ($status.Validation.RequiresOverwrite) { 'yes' } else { 'no' })))
$lines.Add(('Overwrite targets: {0}' -f $(if ($status.Validation.OverwriteTargets.Count -gt 0) { $status.Validation.OverwriteTargets -join ', ' } else { '(none)' })))
$lines.Add(('Issues: {0}' -f $(if ($status.Validation.Issues.Count -gt 0) { $status.Validation.Issues -join ', ' } else { '(none)' })))
$lines.Add(('Warnings: {0}' -f $(if ($status.Validation.Warnings.Count -gt 0) { $status.Validation.Warnings -join ', ' } else { '(none)' })))
$lines.Add('')
$lines.Add('Preflight')
foreach ($preflightLine in @($status.Preflight.SummaryLines)) {
    $lines.Add([string]$preflightLine)
}
if ($status.PreImportStatus) {
    $lines.Add(('PreImport LatestState: {0}' -f [string]$status.PreImportStatus.LatestState))
}
if ($status.PostImportStatus) {
    $lines.Add(('PostImport LatestState: {0}' -f [string]$status.PostImportStatus.LatestState))
}
if (Test-NonEmptyString $status.CompletedAt) {
    $lines.Add(('CompletedAt: {0}' -f $status.CompletedAt))
}
$lines

if ($effectiveIssues.Count -gt 0) {
    $host.SetShouldExit(1)
    return
}

$host.SetShouldExit(0)
return
