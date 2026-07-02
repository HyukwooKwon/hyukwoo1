[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [int]$CycleId = -1,
    [int]$ParentCycleId = -1,
    [string]$PublishedAt = '',
    [string]$SourceContext = '',
    [string]$OutputFingerprint = '',
    [switch]$Overwrite,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

function Resolve-CycleContext {
    param(
        [Parameter(Mandatory)]$TargetEntry,
        [Parameter(Mandatory)]$StateEntry,
        [int]$RequestedCycleId,
        [int]$RequestedParentCycleId
    )

    $request = $null
    $requestPath = [string](Get-ConfigValue -Object $TargetEntry -Name 'CurrentRequestPath' -DefaultValue '')
    if ((Test-NonEmptyString $requestPath) -and (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
        $request = Read-JsonObject -Path $requestPath
    }

    $requestCycleId = [int](Get-ConfigValue -Object $request -Name 'CycleId' -DefaultValue 0)
    $requestParentCycleId = [int](Get-ConfigValue -Object $request -Name 'ParentCycleId' -DefaultValue 0)
    $stateCycleId = [int](Get-ConfigValue -Object $StateEntry -Name 'LastCycleId' -DefaultValue 0)
    $stateParentCycleId = [int](Get-ConfigValue -Object $StateEntry -Name 'LastParentCycleId' -DefaultValue 0)

    $effectiveCycleId = if ($RequestedCycleId -ge 0) {
        $RequestedCycleId
    }
    elseif ($requestCycleId -gt 0) {
        $requestCycleId
    }
    elseif ($stateCycleId -gt 0) {
        $stateCycleId
    }
    else {
        1
    }

    $effectiveParentCycleId = if ($RequestedParentCycleId -ge 0) {
        $RequestedParentCycleId
    }
    elseif ($requestCycleId -gt 0) {
        $requestParentCycleId
    }
    elseif ($stateCycleId -gt 0) {
        $stateParentCycleId
    }
    else {
        0
    }

    return [pscustomobject]@{
        CycleId = $effectiveCycleId
        ParentCycleId = $effectiveParentCycleId
        RequestPath = $requestPath
    }
}

function New-OutputFingerprint {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ReviewZipPath,
        [Parameter(Mandatory)][string]$PublishedAt,
        [Parameter(Mandatory)][int]$CycleId,
        [Parameter(Mandatory)][int]$ParentCycleId
    )

    $payload = [ordered]@{
        TargetId = $TargetId
        CycleId = $CycleId
        ParentCycleId = $ParentCycleId
        PublishedAt = $PublishedAt
        SummaryPath = (Get-NormalizedFullPath -Path $SummaryPath)
        SummarySha256 = (Get-FileHashHex -Path $SummaryPath).ToLowerInvariant()
        ReviewZipPath = (Get-NormalizedFullPath -Path $ReviewZipPath)
        ReviewZipSha256 = (Get-FileHashHex -Path $ReviewZipPath).ToLowerInvariant()
    } | ConvertTo-Json -Depth 8 -Compress

    return (Get-TextHashHex -Text $payload)
}

function New-TargetAutoloopArtifactHistoryEntryPath {
    param(
        [Parameter(Mandatory)][string]$HistoryRoot,
        [Parameter(Mandatory)][int]$CycleId,
        [Parameter(Mandatory)][string]$OutputFingerprint
    )

    $fingerprintPart = [string]$OutputFingerprint
    if ($fingerprintPart.Length -gt 12) {
        $fingerprintPart = $fingerprintPart.Substring(0, 12)
    }
    if (-not (Test-NonEmptyString $fingerprintPart)) {
        $fingerprintPart = 'no-fingerprint'
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $baseName = 'cycle_{0:D6}_{1}_{2}' -f $CycleId, $stamp, $fingerprintPart
    $entryPath = Join-Path $HistoryRoot $baseName
    $suffix = 2
    while (Test-Path -LiteralPath $entryPath) {
        $entryPath = Join-Path $HistoryRoot ('{0}_{1}' -f $baseName, $suffix)
        $suffix += 1
    }
    return $entryPath
}

function Save-TargetAutoloopArtifactHistory {
    param(
        [Parameter(Mandatory)][string]$HistoryRoot,
        [Parameter(Mandatory)][string]$EntryPath,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath,
        [Parameter(Mandatory)]$MarkerPayload
    )

    Ensure-Directory -Path $EntryPath
    $archivedSummaryPath = Join-Path $EntryPath 'summary.txt'
    $archivedReviewZipPath = Join-Path $EntryPath 'review.zip'
    $archivedPublishReadyPath = Join-Path $EntryPath 'publish.ready.json'
    Copy-Item -LiteralPath $SummaryPath -Destination $archivedSummaryPath -Force
    Copy-Item -LiteralPath $ReviewZipPath -Destination $archivedReviewZipPath -Force
    Copy-Item -LiteralPath $PublishReadyPath -Destination $archivedPublishReadyPath -Force

    $summaryItem = Get-Item -LiteralPath $archivedSummaryPath -ErrorAction Stop
    $zipItem = Get-Item -LiteralPath $archivedReviewZipPath -ErrorAction Stop
    $readyItem = Get-Item -LiteralPath $archivedPublishReadyPath -ErrorAction Stop
    $historyPayload = [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Kind = 'target-autoloop-artifact-history'
        TargetId = $TargetId
        RunRoot = $RunRoot
        CycleId = [int](Get-ConfigValue -Object $MarkerPayload -Name 'CycleId' -DefaultValue 0)
        ParentCycleId = [int](Get-ConfigValue -Object $MarkerPayload -Name 'ParentCycleId' -DefaultValue 0)
        OutputFingerprint = [string](Get-ConfigValue -Object $MarkerPayload -Name 'OutputFingerprint' -DefaultValue '')
        PublishedAt = [string](Get-ConfigValue -Object $MarkerPayload -Name 'PublishedAt' -DefaultValue '')
        ArchivedAt = (Get-Date).ToString('o')
        SourceSummaryPath = $SummaryPath
        SourceReviewZipPath = $ReviewZipPath
        SourcePublishReadyPath = $PublishReadyPath
        ArtifactHistoryRoot = $HistoryRoot
        ArtifactHistoryEntryPath = $EntryPath
        ArchivedSummaryPath = $archivedSummaryPath
        ArchivedReviewZipPath = $archivedReviewZipPath
        ArchivedPublishReadyPath = $archivedPublishReadyPath
        SummarySizeBytes = [int64]$summaryItem.Length
        ReviewZipSizeBytes = [int64]$zipItem.Length
        PublishReadySizeBytes = [int64]$readyItem.Length
        SummarySha256 = (Get-FileHashHex -Path $archivedSummaryPath).ToLowerInvariant()
        ReviewZipSha256 = (Get-FileHashHex -Path $archivedReviewZipPath).ToLowerInvariant()
        PublishReadySha256 = (Get-FileHashHex -Path $archivedPublishReadyPath).ToLowerInvariant()
    }
    $historyMetadataPath = Join-Path $EntryPath 'artifact-history.json'
    Write-JsonFileAtomically -Path $historyMetadataPath -Payload $historyPayload

    return [pscustomobject]@{
        ArtifactHistoryRoot = $HistoryRoot
        ArtifactHistoryEntryPath = $EntryPath
        ArchivedSummaryPath = $archivedSummaryPath
        ArchivedReviewZipPath = $archivedReviewZipPath
        ArchivedPublishReadyPath = $archivedPublishReadyPath
        ArtifactHistoryMetadataPath = $historyMetadataPath
        Metadata = [pscustomobject]$historyPayload
    }
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
$resolvedRunRoot = if ([System.IO.Path]::IsPathRooted($RunRoot)) {
    [System.IO.Path]::GetFullPath($RunRoot)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $root $RunRoot))
}

$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "target autoloop manifest not found: $manifestPath"
}

$manifest = Read-JsonObject -Path $manifestPath
$targetEntry = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq [string]$TargetId } | Select-Object -First 1)
if ($targetEntry.Count -eq 0) {
    throw "target not found in target-autoloop manifest: $TargetId"
}
$targetEntry = $targetEntry[0]

$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
$stateDocument = Read-JsonObject -Path $statePaths.StatePath
$stateMap = Get-TargetAutoloopTargetStateMap -StateDocument $stateDocument
$stateEntry = Get-ConfigValue -Object $stateMap -Name $TargetId -DefaultValue $null
if ($null -eq $stateEntry) {
    throw "target not found in target-autoloop state: $TargetId"
}

$summaryPath = [string](Get-ConfigValue -Object $targetEntry -Name 'SourceSummaryPath' -DefaultValue '')
$reviewZipPath = [string](Get-ConfigValue -Object $targetEntry -Name 'SourceReviewZipPath' -DefaultValue '')
$publishReadyPath = [string](Get-ConfigValue -Object $targetEntry -Name 'PublishReadyPath' -DefaultValue '')
$artifactHistoryRoot = [string](Get-ConfigValue -Object $targetEntry -Name 'ArtifactHistoryRoot' -DefaultValue '')
if (-not (Test-NonEmptyString $artifactHistoryRoot)) {
    $artifactHistoryRoot = Join-Path (Split-Path -Parent $publishReadyPath) '.artifact-history'
}
foreach ($pathInfo in @(
        @{ Label = 'summary'; Path = $summaryPath },
        @{ Label = 'review zip'; Path = $reviewZipPath }
    )) {
    if (-not (Test-Path -LiteralPath ([string]$pathInfo.Path) -PathType Leaf)) {
        throw ("target autoloop {0} artifact not found: {1}" -f [string]$pathInfo.Label, [string]$pathInfo.Path)
    }
}

if ((Test-Path -LiteralPath $publishReadyPath -PathType Leaf) -and -not $Overwrite) {
    throw "publish.ready.json already exists: $publishReadyPath"
}

$cycleContext = Resolve-CycleContext -TargetEntry $targetEntry -StateEntry $stateEntry -RequestedCycleId $CycleId -RequestedParentCycleId $ParentCycleId
$summaryItem = Get-Item -LiteralPath $summaryPath -ErrorAction Stop
$zipItem = Get-Item -LiteralPath $reviewZipPath -ErrorAction Stop
$completedAt = (Get-Date).ToString('o')
$effectivePublishedAt = if (Test-NonEmptyString $PublishedAt) { [string]$PublishedAt } else { $completedAt }
$effectiveSourceContext = if (Test-NonEmptyString $SourceContext) { [string]$SourceContext } else { 'target-autoloop-source-outbox' }
$effectiveOutputFingerprint = if (Test-NonEmptyString $OutputFingerprint) {
    [string]$OutputFingerprint
}
else {
    New-OutputFingerprint `
        -TargetId $TargetId `
        -SummaryPath $summaryPath `
        -ReviewZipPath $reviewZipPath `
        -PublishedAt $effectivePublishedAt `
        -CycleId ([int]$cycleContext.CycleId) `
        -ParentCycleId ([int]$cycleContext.ParentCycleId)
}
$artifactHistoryEntryPath = New-TargetAutoloopArtifactHistoryEntryPath `
    -HistoryRoot $artifactHistoryRoot `
    -CycleId ([int]$cycleContext.CycleId) `
    -OutputFingerprint $effectiveOutputFingerprint

$markerPayload = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    RunMode = 'target-autoloop'
    TargetId = $TargetId
    CycleId = [int]$cycleContext.CycleId
    ParentCycleId = [int]$cycleContext.ParentCycleId
    SummaryPath = $summaryPath
    ReviewZipPath = $reviewZipPath
    PublishedAt = $effectivePublishedAt
    PublishedBy = 'publish-target-autoloop-artifact.ps1'
    SummarySizeBytes = [int64]$summaryItem.Length
    ReviewZipSizeBytes = [int64]$zipItem.Length
    SummarySha256 = (Get-FileHashHex -Path $summaryPath).ToLowerInvariant()
    ReviewZipSha256 = (Get-FileHashHex -Path $reviewZipPath).ToLowerInvariant()
    SourceContext = $effectiveSourceContext
    OutputFingerprint = $effectiveOutputFingerprint
    ArtifactHistoryRoot = $artifactHistoryRoot
    ArtifactHistoryEntryPath = $artifactHistoryEntryPath
    ArchivedSummaryPath = (Join-Path $artifactHistoryEntryPath 'summary.txt')
    ArchivedReviewZipPath = (Join-Path $artifactHistoryEntryPath 'review.zip')
    ArchivedPublishReadyPath = (Join-Path $artifactHistoryEntryPath 'publish.ready.json')
    ValidationPassed = $true
    ValidationCompletedAt = $completedAt
    CurrentRequestPath = [string]$cycleContext.RequestPath
}

Write-JsonFileAtomically -Path $publishReadyPath -Payload $markerPayload
$artifactHistory = Save-TargetAutoloopArtifactHistory `
    -HistoryRoot $artifactHistoryRoot `
    -EntryPath $artifactHistoryEntryPath `
    -TargetId $TargetId `
    -RunRoot $resolvedRunRoot `
    -SummaryPath $summaryPath `
    -ReviewZipPath $reviewZipPath `
    -PublishReadyPath $publishReadyPath `
    -MarkerPayload ([pscustomobject]$markerPayload)
Append-TargetAutoloopEvent -Path $statePaths.EventsPath -EventType 'publish-ready-created' -TargetId $TargetId -TriggerKind 'publish-ready' -TriggerFingerprint $effectiveOutputFingerprint -Extra @{
    CycleId = [int]$cycleContext.CycleId
    ParentCycleId = [int]$cycleContext.ParentCycleId
    PublishReadyPath = $publishReadyPath
    ArtifactHistoryEntryPath = [string]$artifactHistory.ArtifactHistoryEntryPath
    ArchivedReviewZipPath = [string]$artifactHistory.ArchivedReviewZipPath
}
Append-TargetAutoloopEvent -Path $statePaths.EventsPath -EventType 'artifact-history-created' -TargetId $TargetId -TriggerKind 'publish-ready' -TriggerFingerprint $effectiveOutputFingerprint -Extra @{
    CycleId = [int]$cycleContext.CycleId
    ParentCycleId = [int]$cycleContext.ParentCycleId
    ArtifactHistoryRoot = [string]$artifactHistory.ArtifactHistoryRoot
    ArtifactHistoryEntryPath = [string]$artifactHistory.ArtifactHistoryEntryPath
    ArchivedSummaryPath = [string]$artifactHistory.ArchivedSummaryPath
    ArchivedReviewZipPath = [string]$artifactHistory.ArchivedReviewZipPath
    ArchivedPublishReadyPath = [string]$artifactHistory.ArchivedPublishReadyPath
    ArtifactHistoryMetadataPath = [string]$artifactHistory.ArtifactHistoryMetadataPath
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    RunRoot = $resolvedRunRoot
    TargetId = $TargetId
    PublishReadyPath = $publishReadyPath
    ArtifactHistoryRoot = [string]$artifactHistory.ArtifactHistoryRoot
    ArtifactHistoryEntryPath = [string]$artifactHistory.ArtifactHistoryEntryPath
    ArchivedSummaryPath = [string]$artifactHistory.ArchivedSummaryPath
    ArchivedReviewZipPath = [string]$artifactHistory.ArchivedReviewZipPath
    ArchivedPublishReadyPath = [string]$artifactHistory.ArchivedPublishReadyPath
    ArtifactHistoryMetadataPath = [string]$artifactHistory.ArtifactHistoryMetadataPath
    Marker = [pscustomobject]$markerPayload
    ArtifactHistory = $artifactHistory.Metadata
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

$result
