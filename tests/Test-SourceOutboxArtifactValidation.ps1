[CmdletBinding()]
param(
    [string]$ConfigPath
)

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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

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

function Invoke-PowerShellJson {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $ScriptPath @Arguments
    $exitCode = $LASTEXITCODE
    $raw = ($result | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "script returned no output: $ScriptPath"
    }

    try {
        $json = $raw | ConvertFrom-Json
    }
    catch {
        throw "json parse failed: $ScriptPath raw=$raw"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Raw = $raw
        Json = $json
    }
}

function Invoke-PowerShellProcess {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $ScriptPath @Arguments
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Raw = ($result | Out-String).Trim()
    }
}

function Get-FileHashHex {
    param([Parameter(Mandatory)][string]$Path)

    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function New-ReadyPayload {
    param(
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ReviewZipPath,
        [Parameter(Mandatory)][string]$PublishedAt,
        [Parameter(Mandatory)][string]$SchemaVersion,
        [int64]$SummarySizeBytes,
        [int64]$ReviewZipSizeBytes,
        [string]$SummarySha256 = '',
        [string]$ReviewZipSha256 = '',
        [string]$SourceContext = '',
        [string]$PublishedBy = 'publish-paired-exchange-artifact.ps1',
        [bool]$ValidationPassed = $true,
        [string]$ValidationCompletedAt = ''
    )

    $payload = [ordered]@{
        SchemaVersion = $SchemaVersion
        PairId = $PairId
        TargetId = $TargetId
        SummaryPath = $SummaryPath
        ReviewZipPath = $ReviewZipPath
        PublishedAt = $PublishedAt
        SummarySizeBytes = $SummarySizeBytes
        ReviewZipSizeBytes = $ReviewZipSizeBytes
        PublishedBy = $PublishedBy
        ValidationPassed = $ValidationPassed
        ValidationCompletedAt = $(if ([string]::IsNullOrWhiteSpace($ValidationCompletedAt) -eq $false) { $ValidationCompletedAt } else { $PublishedAt })
    }

    if ([string]::IsNullOrWhiteSpace($SummarySha256) -eq $false) {
        $payload.SummarySha256 = $SummarySha256
    }
    if ([string]::IsNullOrWhiteSpace($ReviewZipSha256) -eq $false) {
        $payload.ReviewZipSha256 = $ReviewZipSha256
    }
    if ([string]::IsNullOrWhiteSpace($SourceContext) -eq $false) {
        $payload.SourceContext = $SourceContext
    }

    return $payload
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $preferredExternalizedConfigPath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-config\bottest-live-visible\settings.externalized.psd1'
    if (Test-Path -LiteralPath $preferredExternalizedConfigPath -PathType Leaf) {
        $ConfigPath = $preferredExternalizedConfigPath
    }
    else {
        $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
    }
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_source_outbox_validation_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$target01Root = Join-Path $contractRunRoot 'pair01\target01'
$target01Request = Get-Content -LiteralPath (Join-Path $target01Root 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$target01Outbox = Split-Path -Parent ([string]$target01Request.SourceSummaryPath)
$target01SummaryPath = [string]$target01Request.SourceSummaryPath
$target01ReviewZipPath = [string]$target01Request.SourceReviewZipPath
$target01PublishReadyPath = [string]$target01Request.PublishReadyPath

New-Item -ItemType Directory -Path $target01Outbox -Force | Out-Null
[System.IO.File]::WriteAllText($target01SummaryPath, 'invalid zip waiting test', (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($target01ReviewZipPath, 'this is not a valid zip archive', (New-Utf8NoBomEncoding))
$target01Ready = New-ReadyPayload `
    -PairId 'pair01' `
    -TargetId 'target01' `
    -SummaryPath $target01SummaryPath `
    -ReviewZipPath $target01ReviewZipPath `
    -PublishedAt ((Get-Date).ToString('o')) `
    -SchemaVersion '1.0' `
    -SummarySizeBytes ([int64](Get-Item -LiteralPath $target01SummaryPath -ErrorAction Stop).Length) `
    -ReviewZipSizeBytes ([int64](Get-Item -LiteralPath $target01ReviewZipPath -ErrorAction Stop).Length) `
    -SummarySha256 (Get-FileHashHex -Path $target01SummaryPath) `
    -ReviewZipSha256 (Get-FileHashHex -Path $target01ReviewZipPath) `
    -SourceContext 'source-outbox-invalid-zip'
$target01Ready | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $target01PublishReadyPath -Encoding UTF8

$target05Root = Join-Path $contractRunRoot 'pair01\target05'
$target05Request = Get-Content -LiteralPath (Join-Path $target05Root 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$target05Outbox = Split-Path -Parent ([string]$target05Request.SourceSummaryPath)
$target05SummaryPath = [string]$target05Request.SourceSummaryPath
$target05ReviewZipPath = [string]$target05Request.SourceReviewZipPath
$target05PublishReadyPath = [string]$target05Request.PublishReadyPath
$target05ZipContentPath = Join-Path $target05Outbox 'target05-note.txt'

New-Item -ItemType Directory -Path $target05Outbox -Force | Out-Null
[System.IO.File]::WriteAllText($target05SummaryPath, 'unsupported schema waiting test', (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($target05ZipContentPath, 'schema validation zip content', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $target05ZipContentPath -DestinationPath $target05ReviewZipPath -Force
$target05Ready = New-ReadyPayload `
    -PairId 'pair01' `
    -TargetId 'target05' `
    -SummaryPath $target05SummaryPath `
    -ReviewZipPath $target05ReviewZipPath `
    -PublishedAt ((Get-Date).ToString('o')) `
    -SchemaVersion '999.0.0' `
    -SummarySizeBytes ([int64](Get-Item -LiteralPath $target05SummaryPath -ErrorAction Stop).Length) `
    -ReviewZipSizeBytes ([int64](Get-Item -LiteralPath $target05ReviewZipPath -ErrorAction Stop).Length) `
    -SummarySha256 (Get-FileHashHex -Path $target05SummaryPath) `
    -ReviewZipSha256 (Get-FileHashHex -Path $target05ReviewZipPath) `
    -SourceContext 'source-outbox-unsupported-schema'
$target05Ready | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $target05PublishReadyPath -Encoding UTF8

$watcherRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-RunDurationSec', '4'
)
Assert-True ($watcherRun.ExitCode -eq 0) 'watcher should exit cleanly when source-outbox markers are invalid.'

$sourceOutboxStatusPath = Join-Path $contractRunRoot '.state\source-outbox-status.json'
$sourceOutboxStatus = Get-Content -LiteralPath $sourceOutboxStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01Status = @($sourceOutboxStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$target05Status = @($sourceOutboxStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target05' } | Select-Object -First 1)[0]

Assert-True ($null -ne $target01Status) 'target01 source-outbox status should be recorded.'
Assert-True ($null -ne $target05Status) 'target05 source-outbox status should be recorded.'
Assert-True ([string]$target01Status.State -eq 'waiting') 'invalid zip marker should remain waiting.'
Assert-True ([string]$target01Status.Reason -eq 'source-reviewzip-invalid') 'invalid zip marker should report source-reviewzip-invalid.'
Assert-True ([string]$target05Status.State -eq 'waiting') 'unsupported schema marker should remain waiting.'
Assert-True ([string]$target05Status.Reason -eq 'marker-schema-version-unsupported') 'unsupported schema marker should report marker-schema-version-unsupported.'

Assert-True ((Test-Path -LiteralPath $target01PublishReadyPath -PathType Leaf)) 'invalid zip marker should remain in source-outbox.'
Assert-True ((Test-Path -LiteralPath $target05PublishReadyPath -PathType Leaf)) 'unsupported schema marker should remain in source-outbox.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $target01Root 'done.json') -PathType Leaf)) 'invalid zip marker should not produce done.json.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $target05Root 'done.json') -PathType Leaf)) 'unsupported schema marker should not produce done.json.'
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $target01Root 'reviewfile') -Filter '*.zip' -File -ErrorAction SilentlyContinue).Count -eq 0) 'invalid zip marker should not import any zip.'
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $target05Root 'reviewfile') -Filter '*.zip' -File -ErrorAction SilentlyContinue).Count -eq 0) 'unsupported schema marker should not import any zip.'

$pairedStatus = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'show-paired-exchange-status.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-AsJson'
)
Assert-True ($pairedStatus.ExitCode -eq 0) 'paired status should succeed after invalid source-outbox markers.'
Assert-True ([int]$pairedStatus.Json.Counts.SourceOutboxImportedCount -eq 0) 'invalid source-outbox markers should not count as imported.'

Write-Host ('source-outbox artifact validation ok: runRoot=' + $contractRunRoot)
