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
    ValidationPassed = $true
    ValidationCompletedAt = $completedAt
    CurrentRequestPath = [string]$cycleContext.RequestPath
}

Write-JsonFileAtomically -Path $publishReadyPath -Payload $markerPayload
Append-TargetAutoloopEvent -Path $statePaths.EventsPath -EventType 'publish-ready-created' -TargetId $TargetId -TriggerKind 'publish-ready' -TriggerFingerprint $effectiveOutputFingerprint -Extra @{
    CycleId = [int]$cycleContext.CycleId
    ParentCycleId = [int]$cycleContext.ParentCycleId
    PublishReadyPath = $publishReadyPath
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    RunRoot = $resolvedRunRoot
    TargetId = $TargetId
    PublishReadyPath = $publishReadyPath
    Marker = [pscustomobject]$markerPayload
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

$result
