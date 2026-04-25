[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SupportedSourceOutboxSchemaVersions = @('1.0.0', '1.0')

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

function Get-ConfigValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
}

function Write-ValidSourceOutboxArtifacts {
    param(
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath
    )

    $sourceOutboxRoot = Split-Path -Parent $PublishReadyPath
    New-Item -ItemType Directory -Path $sourceOutboxRoot -Force | Out-Null
    Set-Content -LiteralPath $SummaryPath -Encoding UTF8 -Value 'source-outbox summary'
    $zipNotePath = Join-Path $sourceOutboxRoot 'review-note.txt'
    Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'source-outbox review zip content'
    if (Test-Path -LiteralPath $ReviewZipPath) {
        Remove-Item -LiteralPath $ReviewZipPath -Force
    }
    Compress-Archive -LiteralPath $zipNotePath -DestinationPath $ReviewZipPath -Force

    $summaryItem = Get-Item -LiteralPath $SummaryPath -ErrorAction Stop
    $zipItem = Get-Item -LiteralPath $ReviewZipPath -ErrorAction Stop
    $payload = [ordered]@{
        SchemaVersion = '1.0.0'
        PairId = $PairId
        TargetId = $TargetId
        SummaryPath = $SummaryPath
        ReviewZipPath = $ReviewZipPath
        PublishedAt = (Get-Date).ToString('o')
        SummarySizeBytes = [int64]$summaryItem.Length
        ReviewZipSizeBytes = [int64]$zipItem.Length
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $PublishReadyPath -Encoding UTF8
}

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'executor\Invoke-CodexExecTurn.ps1'
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
foreach ($functionName in @(
        'Test-NonEmptyString',
        'Read-JsonObject',
        'Get-NormalizedFullPath',
        'Test-ZipArchiveReadable',
        'Get-FileHashHex',
        'Test-SourceOutboxMarkerContract',
        'Test-SourceOutboxFreshReady'
    )) {
    $functionAst = @(
        $scriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) |
            Select-Object -First 1
    )
    Assert-True (@($functionAst).Count -eq 1) ("missing function: " + $functionName)
    Invoke-Expression $functionAst[0].Extent.Text
}

$testRoot = Join-Path $root '_tmp\test-invoke-codex-exec-turn-source-outbox-fresh-ready'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$pairId = 'pair01'
$targetId = 'target01'
$summaryPath = Join-Path $testRoot 'source-outbox\summary.txt'
$reviewZipPath = Join-Path $testRoot 'source-outbox\review.zip'
$publishReadyPath = Join-Path $testRoot 'source-outbox\publish.ready.json'

Write-ValidSourceOutboxArtifacts -PairId $pairId -TargetId $targetId -SummaryPath $summaryPath -ReviewZipPath $reviewZipPath -PublishReadyPath $publishReadyPath
$readyState = Test-SourceOutboxFreshReady `
    -PairId $pairId `
    -TargetId $targetId `
    -SourceSummaryPath $summaryPath `
    -SourceReviewZipPath $reviewZipPath `
    -PublishReadyPath $publishReadyPath
Assert-True ([bool]$readyState.IsReady) 'well-formed source-outbox marker should be ready.'
Assert-True ([string]$readyState.Reason -eq 'ready') 'well-formed source-outbox marker should report ready.'

Set-Content -LiteralPath $publishReadyPath -Encoding UTF8 -Value '{not-json'
$invalidState = Test-SourceOutboxFreshReady `
    -PairId $pairId `
    -TargetId $targetId `
    -SourceSummaryPath $summaryPath `
    -SourceReviewZipPath $reviewZipPath `
    -PublishReadyPath $publishReadyPath
Assert-True (-not [bool]$invalidState.IsReady) 'malformed source-outbox marker should not be ready.'
Assert-True ([string]$invalidState.Reason -eq 'marker-json-invalid') 'malformed source-outbox marker should report marker-json-invalid.'

Write-ValidSourceOutboxArtifacts -PairId $pairId -TargetId $targetId -SummaryPath $summaryPath -ReviewZipPath $reviewZipPath -PublishReadyPath $publishReadyPath
Start-Sleep -Milliseconds 1100
Set-Content -LiteralPath $summaryPath -Encoding UTF8 -Value 'source-outbox summary updated after marker'
$orderingState = Test-SourceOutboxFreshReady `
    -PairId $pairId `
    -TargetId $targetId `
    -SourceSummaryPath $summaryPath `
    -SourceReviewZipPath $reviewZipPath `
    -PublishReadyPath $publishReadyPath
Assert-True (-not [bool]$orderingState.IsReady) 'marker older than source artifacts should not be ready.'
Assert-True ([string]$orderingState.Reason -eq 'marker-before-artifacts') 'marker older than source artifacts should report marker-before-artifacts.'

Write-Host 'invoke-codex-exec-turn source-outbox freshness validation ok'
