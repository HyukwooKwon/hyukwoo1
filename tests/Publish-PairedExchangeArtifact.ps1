[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [string]$PublishedAt = '',
    [string]$SourceContext = '',
    [switch]$Overwrite,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not (Test-NonEmptyString $raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Get-FileHashHex {
    param([Parameter(Mandatory)][string]$Path)

    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Resolve-SourceOutboxContractPaths {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$TargetEntry,
        $Request = $null
    )

    $targetFolder = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetFolder' -DefaultValue '')
    $sourceOutboxPath = [string](Get-ConfigValue -Object $Request -Name 'SourceOutboxPath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'SourceOutboxPath' -DefaultValue '')))
    if (-not (Test-NonEmptyString $sourceOutboxPath)) {
        $sourceOutboxPath = Join-Path $targetFolder ([string]$PairTest.SourceOutboxFolderName)
    }

    $summaryPath = [string](Get-ConfigValue -Object $Request -Name 'SourceSummaryPath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'SourceSummaryPath' -DefaultValue '')))
    if (-not (Test-NonEmptyString $summaryPath)) {
        $summaryPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
    }

    $reviewZipPath = [string](Get-ConfigValue -Object $Request -Name 'SourceReviewZipPath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'SourceReviewZipPath' -DefaultValue '')))
    if (-not (Test-NonEmptyString $reviewZipPath)) {
        $reviewZipPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
    }

    $publishReadyPath = [string](Get-ConfigValue -Object $Request -Name 'PublishReadyPath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'PublishReadyPath' -DefaultValue '')))
    if (-not (Test-NonEmptyString $publishReadyPath)) {
        $publishReadyPath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishReadyFileName)
    }

    return [pscustomobject]@{
        SourceOutboxPath  = $sourceOutboxPath
        SourceSummaryPath = $summaryPath
        SourceReviewZipPath = $reviewZipPath
        PublishReadyPath  = $publishReadyPath
        PublishedArchivePath = [string](Get-ConfigValue -Object $Request -Name 'PublishedArchivePath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'PublishedArchivePath' -DefaultValue (Join-Path $sourceOutboxPath ([string]$PairTest.PublishedArchiveFolderName)))))
    }
}

function ConvertTo-IntOrDefault {
    param(
        $Value,
        [int]$DefaultValue = 0
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $DefaultValue
}

function Get-NextPublishIdentity {
    param(
        [Parameter(Mandatory)][string]$PublishReadyPath,
        [Parameter(Mandatory)][string]$PublishedArchivePath,
        [AllowEmptyString()][string]$AttemptId = '',
        [Parameter(Mandatory)][string]$TargetId
    )

    $maxSequence = 0
    foreach ($candidatePath in @($PublishReadyPath)) {
        if (-not (Test-NonEmptyString $candidatePath) -or -not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            continue
        }

        $candidateDoc = Read-JsonObject -Path $candidatePath
        $candidateSequence = ConvertTo-IntOrDefault -Value (Get-ConfigValue -Object $candidateDoc -Name 'PublishSequence' -DefaultValue 0)
        if ($candidateSequence -gt $maxSequence) {
            $maxSequence = $candidateSequence
        }
    }

    if (Test-NonEmptyString $PublishedArchivePath -and (Test-Path -LiteralPath $PublishedArchivePath -PathType Container)) {
        foreach ($archiveItem in @(Get-ChildItem -LiteralPath $PublishedArchivePath -Filter '*.ready.json' -File -ErrorAction SilentlyContinue)) {
            $archiveDoc = Read-JsonObject -Path ([string]$archiveItem.FullName)
            $archiveSequence = ConvertTo-IntOrDefault -Value (Get-ConfigValue -Object $archiveDoc -Name 'PublishSequence' -DefaultValue 0)
            if ($archiveSequence -gt $maxSequence) {
                $maxSequence = $archiveSequence
            }
        }
    }

    $nextSequence = $maxSequence + 1
    $cycleBase = if (Test-NonEmptyString $AttemptId) { [string]$AttemptId } else { [string]$TargetId }
    $cycleId = ('{0}__publish_{1}' -f $cycleBase, $nextSequence.ToString('0000'))

    return [pscustomobject]@{
        PublishSequence = $nextSequence
        PublishCycleId  = $cycleId
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
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "manifest not found: $manifestPath"
}

$manifest = Read-JsonObject -Path $manifestPath
$targetEntry = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq [string]$TargetId } | Select-Object -First 1)
if ($targetEntry.Count -eq 0) {
    throw "target not found in manifest: $TargetId"
}
$targetEntry = $targetEntry[0]

$requestPath = [string](Get-ConfigValue -Object $TargetEntry -Name 'RequestPath' -DefaultValue '')
if (-not (Test-NonEmptyString $requestPath)) {
    $requestPath = Join-Path ([string]$targetEntry.TargetFolder) ([string]$pairTest.HeadlessExec.RequestFileName)
}
$request = Read-JsonObject -Path $requestPath
$contract = Resolve-SourceOutboxContractPaths -PairTest $pairTest -TargetEntry $targetEntry -Request $request

$checkRaw = & (Join-Path $root 'check-paired-exchange-artifact.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $resolvedRunRoot `
    -TargetId ([string]$targetEntry.TargetId) `
    -SummarySourcePath ([string]$contract.SourceSummaryPath) `
    -ReviewZipSourcePath ([string]$contract.SourceReviewZipPath) `
    -AsJson
$checkPayloadText = ($checkRaw | Out-String).Trim()
$checkPayload = if (Test-NonEmptyString $checkPayloadText) { $checkPayloadText | ConvertFrom-Json } else { $null }

$issues = New-Object System.Collections.Generic.List[string]
if ($null -eq $checkPayload) {
    [void]$issues.Add('check-artifact-no-output')
}
elseif (-not [bool](Get-ConfigValue -Object (Get-ConfigValue -Object $checkPayload -Name 'Validation' -DefaultValue $null) -Name 'Ok' -DefaultValue $false)) {
    [void]$issues.Add('check-artifact-rejected')
}

$attemptId = [string](Get-ConfigValue -Object $request -Name 'AttemptId' -DefaultValue ([string](Get-ConfigValue -Object $targetEntry -Name 'AttemptId' -DefaultValue '')))
$attemptStartedAt = [string](Get-ConfigValue -Object $request -Name 'AttemptStartedAt' -DefaultValue ([string](Get-ConfigValue -Object $request -Name 'CreatedAt' -DefaultValue ([string](Get-ConfigValue -Object $targetEntry -Name 'AttemptStartedAt' -DefaultValue '')))))
$publishIdentity = Get-NextPublishIdentity `
    -PublishReadyPath ([string]$contract.PublishReadyPath) `
    -PublishedArchivePath ([string]$contract.PublishedArchivePath) `
    -AttemptId $attemptId `
    -TargetId ([string]$targetEntry.TargetId)

if (Test-Path -LiteralPath $contract.PublishReadyPath -PathType Leaf) {
    if ($Overwrite) {
        Remove-Item -LiteralPath $contract.PublishReadyPath -Force -ErrorAction Stop
    }
    else {
        [void]$issues.Add('publish-ready-already-exists')
    }
}

$markerCreated = $false
$markerPayload = $null
$completedAt = ''

if ($issues.Count -eq 0) {
    $summaryItem = Get-Item -LiteralPath $contract.SourceSummaryPath -ErrorAction Stop
    $zipItem = Get-Item -LiteralPath $contract.SourceReviewZipPath -ErrorAction Stop
    $completedAt = (Get-Date).ToString('o')
    $effectivePublishedAt = if (Test-NonEmptyString $PublishedAt) { [string]$PublishedAt } else { $completedAt }
    $effectiveSourceContext = if (Test-NonEmptyString $SourceContext) { [string]$SourceContext } else { 'source-outbox-publish-helper' }

    $markerPayload = [ordered]@{
        SchemaVersion       = '1.0.0'
        PairId              = [string]$targetEntry.PairId
        TargetId            = [string]$targetEntry.TargetId
        AttemptId           = $attemptId
        AttemptStartedAt    = $attemptStartedAt
        PublishSequence     = [int]$publishIdentity.PublishSequence
        PublishCycleId      = [string]$publishIdentity.PublishCycleId
        SummaryPath         = [string]$contract.SourceSummaryPath
        ReviewZipPath       = [string]$contract.SourceReviewZipPath
        PublishedAt         = $effectivePublishedAt
        SummarySizeBytes    = [int64]$summaryItem.Length
        ReviewZipSizeBytes  = [int64]$zipItem.Length
        SummarySha256       = (Get-FileHashHex -Path $contract.SourceSummaryPath)
        ReviewZipSha256     = (Get-FileHashHex -Path $contract.SourceReviewZipPath)
        SourceContext       = $effectiveSourceContext
        PublishedBy         = 'publish-paired-exchange-artifact.ps1'
        ValidationPassed    = $true
        ValidationCompletedAt = $completedAt
        ValidationSource    = 'check-paired-exchange-artifact.ps1'
    }

    $markerPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $contract.PublishReadyPath -Encoding UTF8
    $markerCreated = $true
}

$status = [pscustomobject]@{
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    Overwrite = [bool]$Overwrite
    PublishReadyCreated = $markerCreated
    PublishedAt = if ($markerCreated) { [string]$markerPayload.PublishedAt } else { '' }
    Target = [pscustomobject]@{
        PairId = [string]$targetEntry.PairId
        TargetId = [string]$targetEntry.TargetId
        PartnerTargetId = [string]$targetEntry.PartnerTargetId
    }
    Contract = [pscustomobject]@{
        SourceOutboxPath = [string]$contract.SourceOutboxPath
        SourceSummaryPath = [string]$contract.SourceSummaryPath
        SourceReviewZipPath = [string]$contract.SourceReviewZipPath
        PublishReadyPath = [string]$contract.PublishReadyPath
        PublishedArchivePath = [string]$contract.PublishedArchivePath
        RequestPath = [string]$requestPath
    }
    Validation = if ($null -ne $checkPayload) { $checkPayload.Validation } else { [pscustomobject]@{ Ok = $false; Issues = @('check-artifact-no-output') } }
    Marker = $markerPayload
    Issues = @($issues)
    CompletedAt = $completedAt
}

if ($AsJson) {
    $status | ConvertTo-Json -Depth 8
    if (-not $markerCreated) {
        $host.SetShouldExit(1)
    }
    return
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('Paired Exchange Source Publish')
$lines.Add(('RunRoot: {0}' -f $resolvedRunRoot))
$lines.Add(('Target: {0} / pair={1}' -f [string]$targetEntry.TargetId, [string]$targetEntry.PairId))
$lines.Add(('SourceOutboxPath: {0}' -f [string]$contract.SourceOutboxPath))
$lines.Add(('SourceSummaryPath: {0}' -f [string]$contract.SourceSummaryPath))
$lines.Add(('SourceReviewZipPath: {0}' -f [string]$contract.SourceReviewZipPath))
$lines.Add(('PublishReadyPath: {0}' -f [string]$contract.PublishReadyPath))
$lines.Add(('ValidationOk: {0}' -f $(if ($null -ne $status.Validation -and [bool]$status.Validation.Ok) { 'yes' } else { 'no' })))
$lines.Add(('PublishReadyCreated: {0}' -f $(if ($markerCreated) { 'yes' } else { 'no' })))
$lines.Add(('Issues: {0}' -f $(if ($issues.Count -gt 0) { $issues -join ', ' } else { '(none)' })))
$lines

if (-not $markerCreated) {
    $host.SetShouldExit(1)
    return
}

$host.SetShouldExit(0)
