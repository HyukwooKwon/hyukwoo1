[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    param([Parameter(Mandatory)]$Paths)

    $sourceOutboxRoot = Split-Path -Parent $Paths.PublishReadyPath
    New-Item -ItemType Directory -Path $sourceOutboxRoot -Force | Out-Null

    Set-Content -LiteralPath $Paths.SourceSummaryPath -Encoding UTF8 -Value 'source-outbox summary'
    $notePath = Join-Path $sourceOutboxRoot 'review-note.txt'
    Set-Content -LiteralPath $notePath -Encoding UTF8 -Value 'source-outbox review zip content'
    if (Test-Path -LiteralPath $Paths.SourceReviewZipPath) {
        Remove-Item -LiteralPath $Paths.SourceReviewZipPath -Force
    }
    Compress-Archive -LiteralPath $notePath -DestinationPath $Paths.SourceReviewZipPath -Force

    $summaryItem = Get-Item -LiteralPath $Paths.SourceSummaryPath -ErrorAction Stop
    $zipItem = Get-Item -LiteralPath $Paths.SourceReviewZipPath -ErrorAction Stop
    $payload = [ordered]@{
        SchemaVersion = '1.0.0'
        PairId = [string]$Paths.PairId
        TargetId = [string]$Paths.TargetId
        SummaryPath = [string]$Paths.SourceSummaryPath
        ReviewZipPath = [string]$Paths.SourceReviewZipPath
        PublishedAt = (Get-Date).ToString('o')
        SummarySizeBytes = [int64]$summaryItem.Length
        ReviewZipSizeBytes = [int64]$zipItem.Length
        PublishedBy = 'publish-paired-exchange-artifact.ps1'
        ValidationPassed = $true
        ValidationCompletedAt = (Get-Date).ToString('o')
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Paths.PublishReadyPath -Encoding UTF8
}

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'visible\Start-VisibleTargetWorker.ps1'
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
foreach ($functionName in @(
        'Test-NonEmptyString',
        'Get-ConfigValue',
        'Read-JsonObject',
        'Get-NormalizedFullPath',
        'Test-ZipArchiveReadable',
        'Get-FileHashHex',
        'Test-SourceOutboxPublishReadyValid',
        'Test-CommandExecutionSucceeded'
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

$testRoot = Join-Path $root '_tmp\test-visible-worker-command-execution-succeeded'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$paths = [pscustomobject]@{
    PairId = 'pair01'
    TargetId = 'target01'
    DonePath = Join-Path $testRoot 'done.json'
    ErrorPath = Join-Path $testRoot 'error.json'
    ResultPath = Join-Path $testRoot 'result.json'
    PublishReadyPath = Join-Path $testRoot 'source-outbox\publish.ready.json'
    SourceSummaryPath = Join-Path $testRoot 'source-outbox\summary.txt'
    SourceReviewZipPath = Join-Path $testRoot 'source-outbox\review.zip'
}

Set-Content -LiteralPath $paths.ErrorPath -Encoding UTF8 -Value '{"Reason":"stale-error"}'
Set-Content -LiteralPath $paths.DonePath -Encoding UTF8 -Value '{"Mode":"source-outbox-publish"}'
Assert-True (Test-CommandExecutionSucceeded -Paths $paths) 'done.json should win over stale error.json.'
Remove-Item -LiteralPath $paths.DonePath -Force

Write-ValidSourceOutboxArtifacts -Paths $paths
Assert-True (Test-CommandExecutionSucceeded -Paths $paths) 'valid publish.ready.json should win over stale error.json.'

Set-Content -LiteralPath $paths.PublishReadyPath -Encoding UTF8 -Value '{not-json'
Assert-True (-not (Test-CommandExecutionSucceeded -Paths $paths)) 'malformed publish.ready.json should not report success.'

Write-ValidSourceOutboxArtifacts -Paths $paths
Set-Content -LiteralPath $paths.ResultPath -Encoding UTF8 -Value '{"SourceOutboxReady":true,"ContractArtifactsReady":false}'
Assert-True (Test-CommandExecutionSucceeded -Paths $paths) 'result.json SourceOutboxReady=true should succeed only with a valid source-outbox marker.'

Set-Content -LiteralPath $paths.PublishReadyPath -Encoding UTF8 -Value '{not-json'
Assert-True (-not (Test-CommandExecutionSucceeded -Paths $paths)) 'result.json SourceOutboxReady=true should fail when the source-outbox marker is malformed.'
Remove-Item -LiteralPath $paths.ResultPath -Force

Set-Content -LiteralPath $paths.ResultPath -Encoding UTF8 -Value '{"SourceOutboxReady":false,"ContractArtifactsReady":true}'
Assert-True (Test-CommandExecutionSucceeded -Paths $paths) 'result.json ContractArtifactsReady=true should win over stale error.json.'
Remove-Item -LiteralPath $paths.ResultPath -Force

Remove-Item -LiteralPath $paths.PublishReadyPath -Force
Assert-True (-not (Test-CommandExecutionSucceeded -Paths $paths)) 'error.json alone should still report failure.'

Write-Host 'visible-worker command execution success marker precedence ok'
