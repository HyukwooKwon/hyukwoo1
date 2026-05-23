Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PairedSourceOutboxPaths {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$TargetEntry,
        $Request = $null
    )

    $targetFolder = [string](Get-ConfigValue -Object $Request -Name 'TargetFolder' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetFolder)) {
        $targetFolder = [string](Get-ConfigValue -Object $TargetEntry -Name 'TargetFolder' -DefaultValue '')
    }
    if (-not (Test-NonEmptyString $targetFolder)) {
        $targetFolder = [string](Get-ConfigValue -Object $TargetEntry -Name 'Folder' -DefaultValue '')
    }

    $sourceOutboxPath = [string](Get-ConfigValue -Object $Request -Name 'SourceOutboxPath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'SourceOutboxPath' -DefaultValue '')))
    if (-not (Test-NonEmptyString $sourceOutboxPath) -and (Test-NonEmptyString $targetFolder)) {
        $sourceOutboxPath = Join-Path $targetFolder ([string]$PairTest.SourceOutboxFolderName)
    }

    $sourceSummaryPath = [string](Get-ConfigValue -Object $Request -Name 'SourceSummaryPath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'SourceSummaryPath' -DefaultValue '')))
    if (-not (Test-NonEmptyString $sourceSummaryPath) -and (Test-NonEmptyString $sourceOutboxPath)) {
        $sourceSummaryPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
    }

    $sourceReviewZipPath = [string](Get-ConfigValue -Object $Request -Name 'SourceReviewZipPath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'SourceReviewZipPath' -DefaultValue '')))
    if (-not (Test-NonEmptyString $sourceReviewZipPath) -and (Test-NonEmptyString $sourceOutboxPath)) {
        $sourceReviewZipPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
    }

    $publishReadyPath = [string](Get-ConfigValue -Object $Request -Name 'PublishReadyPath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'PublishReadyPath' -DefaultValue '')))
    if (-not (Test-NonEmptyString $publishReadyPath) -and (Test-NonEmptyString $sourceOutboxPath)) {
        $publishReadyPath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishReadyFileName)
    }

    $publishedArchivePath = [string](Get-ConfigValue -Object $Request -Name 'PublishedArchivePath' -DefaultValue ([string](Get-ConfigValue -Object $TargetEntry -Name 'PublishedArchivePath' -DefaultValue '')))
    if (-not (Test-NonEmptyString $publishedArchivePath) -and (Test-NonEmptyString $sourceOutboxPath)) {
        $publishedArchivePath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishedArchiveFolderName)
    }

    return [pscustomobject]@{
        TargetFolder         = $targetFolder
        SourceOutboxPath     = $sourceOutboxPath
        SourceSummaryPath    = $sourceSummaryPath
        SourceReviewZipPath  = $sourceReviewZipPath
        PublishReadyPath     = $publishReadyPath
        PublishedArchivePath = $publishedArchivePath
    }
}
