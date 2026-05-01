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
        SchemaVersion = '1.0.0'
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
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_source_outbox_publish_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$target01Root = Join-Path $contractRunRoot 'pair01\target01'
$target01Request = Get-Content -LiteralPath (Join-Path $target01Root 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$target01Outbox = Split-Path -Parent ([string]$target01Request.SourceSummaryPath)
$target01SourceSummaryPath = [string]$target01Request.SourceSummaryPath
$target01SourceZipPath = [string]$target01Request.SourceReviewZipPath
$target01PublishReadyPath = [string]$target01Request.PublishReadyPath
$target01ArchiveRoot = [string]$target01Request.PublishedArchivePath
$target01ZipContentPath = Join-Path $target01Outbox 'target01-note.txt'
$target01PublishScriptPath = Join-Path $target01Root 'publish-artifact.ps1'

New-Item -ItemType Directory -Path $target01Outbox -Force | Out-Null
[System.IO.File]::WriteAllText($target01SourceSummaryPath, 'source outbox publish summary', (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($target01ZipContentPath, 'source outbox publish zip content', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $target01ZipContentPath -DestinationPath $target01SourceZipPath -Force
$target01Publish = Invoke-PowerShellJson -ScriptPath $target01PublishScriptPath -Arguments @('-AsJson')
Assert-True ($target01Publish.ExitCode -eq 0) 'target01 publish wrapper should succeed.'
Assert-True ([bool]$target01Publish.Json.PublishReadyCreated) 'target01 publish wrapper should create ready marker.'
$target01ReadyPayload = $target01Publish.Json.Marker

$target05Root = Join-Path $contractRunRoot 'pair01\target05'
$target05Request = Get-Content -LiteralPath (Join-Path $target05Root 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$target05Outbox = Split-Path -Parent ([string]$target05Request.SourceSummaryPath)
$target05SourceSummaryPath = [string]$target05Request.SourceSummaryPath
$target05SourceZipPath = [string]$target05Request.SourceReviewZipPath
$target05PublishReadyPath = [string]$target05Request.PublishReadyPath
$target05ZipContentPath = Join-Path $target05Outbox 'target05-note.txt'

New-Item -ItemType Directory -Path $target05Outbox -Force | Out-Null
[System.IO.File]::WriteAllText($target05SourceSummaryPath, 'invalid source outbox publish summary', (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($target05ZipContentPath, 'invalid source outbox publish zip content', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $target05ZipContentPath -DestinationPath $target05SourceZipPath -Force
$target05ReadyPayload = New-ReadyPayload `
    -PairId 'pair01' `
    -TargetId 'target05' `
    -SummaryPath $target05SourceSummaryPath `
    -ReviewZipPath $target05SourceZipPath `
    -PublishedAt ((Get-Date).ToString('o')) `
    -SummarySizeBytes ([int64](Get-Item -LiteralPath $target05SourceSummaryPath -ErrorAction Stop).Length) `
    -ReviewZipSizeBytes ([int64](Get-Item -LiteralPath $target05SourceZipPath -ErrorAction Stop).Length + 5) `
    -SourceContext 'source-outbox-test-target05-invalid'
$target05ReadyPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $target05PublishReadyPath -Encoding UTF8

$watcherRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-MaxForwardCount', '1',
    '-RunDurationSec', '4'
)
Assert-True ($watcherRun.ExitCode -eq 0) 'watcher should exit cleanly for source-outbox smoke test.'

$target01ContractSummaryPath = Join-Path $target01Root 'summary.txt'
$target01ReviewRoot = Join-Path $target01Root 'reviewfile'
$target01DonePath = Join-Path $target01Root 'done.json'
$target01ResultPath = Join-Path $target01Root 'result.json'
$target01ImportedZips = @(Get-ChildItem -LiteralPath $target01ReviewRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue)
Assert-True ((Test-Path -LiteralPath $target01ContractSummaryPath -PathType Leaf)) 'target01 contract summary should exist after source-outbox import.'
Assert-True ((Test-Path -LiteralPath $target01DonePath -PathType Leaf)) 'target01 done.json should exist after source-outbox import.'
Assert-True ((Test-Path -LiteralPath $target01ResultPath -PathType Leaf)) 'target01 result.json should exist after source-outbox import.'
Assert-True ($target01ImportedZips.Count -eq 1) 'target01 reviewfile should contain exactly one imported zip after first publish.'
Assert-True (-not (Test-Path -LiteralPath $target01PublishReadyPath -PathType Leaf)) 'target01 ready marker should be archived after import.'
Assert-True (@(Get-ChildItem -LiteralPath $target01ArchiveRoot -Filter '*.ready.json' -File -ErrorAction SilentlyContinue).Count -eq 1) 'target01 archive folder should contain one archived ready marker after import.'

$target01Result = Get-Content -LiteralPath $target01ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01Done = Get-Content -LiteralPath $target01DonePath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$target01Result.Mode -eq 'source-outbox-publish') 'target01 result should record source-outbox-publish mode.'
Assert-True ([string]$target01Done.Mode -eq 'source-outbox-publish') 'target01 done should record source-outbox-publish mode.'
Assert-True ([string]$target01Result.SourcePublishReadyPath -eq $target01PublishReadyPath) 'target01 result should record source publish marker path.'
Assert-True ([string]$target01Result.SourcePublishedAt -eq [string]$target01ReadyPayload.PublishedAt) 'target01 result should record source publish marker publishedAt.'
Assert-True ([string]$target01Result.SourcePublishAttemptId -eq [string]$target01ReadyPayload.AttemptId) 'target01 result should record source publish attempt id.'
Assert-True ([int]$target01Result.SourcePublishSequence -eq [int]$target01ReadyPayload.PublishSequence) 'target01 result should record source publish sequence.'
Assert-True ([string]$target01Result.SourcePublishCycleId -eq [string]$target01ReadyPayload.PublishCycleId) 'target01 result should record source publish cycle id.'
Assert-True ([string]$target01Result.SourceValidationCompletedAt -eq [string]$target01ReadyPayload.ValidationCompletedAt) 'target01 result should record source validation completion time.'
Assert-True ([string]$target01Result.SourceSummarySha256 -eq [string]$target01ReadyPayload.SummarySha256) 'target01 result should record source summary hash.'
Assert-True ([string]$target01Result.SourceReviewZipSha256 -eq [string]$target01ReadyPayload.ReviewZipSha256) 'target01 result should record source review zip hash.'

$messagesRoot = Join-Path $contractRunRoot 'messages'
$handoffMessage = Get-ChildItem -LiteralPath $messagesRoot -Filter 'handoff_target01_to_target05_*.txt' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc |
    Select-Object -Last 1
Assert-True ($null -ne $handoffMessage) 'watcher should emit a handoff message for target05 after target01 publish.'
$handoffText = Get-Content -LiteralPath $handoffMessage.FullName -Raw -Encoding UTF8
Assert-True ($handoffText.Contains(("내 작업 폴더: " + $target05Root))) 'handoff message should direct partner to the target05 work folder.'
Assert-True ($handoffText.Contains(("- summary.txt: " + (Join-Path $target05Outbox 'summary.txt')))) 'handoff message should name the target05 source-outbox summary path.'
Assert-True ($handoffText.Contains(("- review.zip: " + (Join-Path $target05Outbox 'review.zip')))) 'handoff message should name the target05 source-outbox review zip path.'
Assert-True ($handoffText.Contains(("- publish.ready.json: " + $target05PublishReadyPath))) 'handoff message should contain target05 publish.ready.json path.'
Assert-True ($handoffText.Contains('직접 target contract 경로에 복사하거나 별도 submit 명령을 다시 실행하지 마세요.')) 'handoff message should forbid direct contract writes.'
Assert-True (-not $handoffText.Contains('검토 결과는 내 폴더의 summary.txt에 기록하세요.')) 'handoff message should not use the old contract-folder summary instruction.'

$statusAfterFirstRun = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-AsJson'
)
$target01StatusRow = @($statusAfterFirstRun.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$target05StatusRow = @($statusAfterFirstRun.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target05' } | Select-Object -First 1)[0]
Assert-True ([string]$target01StatusRow.LatestState -in @('ready-to-forward', 'forwarded')) 'target01 latest state should advance after source-outbox import.'
Assert-True ([string]$target05StatusRow.LatestState -eq 'no-zip') 'target05 should remain no-zip when invalid source-outbox marker is ignored.'
Assert-True ([string]$statusAfterFirstRun.Json.Watcher.StatusReason -eq 'max-forward-count-reached') 'watcher should stop due to max forward count in source-outbox smoke test.'
Assert-True ([string]$statusAfterFirstRun.Json.Watcher.StopCategory -eq 'expected-limit') 'watcher should classify max forward count as expected-limit.'
Assert-True ([int]$statusAfterFirstRun.Json.Watcher.ForwardedCount -eq 1) 'watcher should record one forwarded handoff.'
Assert-True ([int]$statusAfterFirstRun.Json.Watcher.ConfiguredMaxForwardCount -eq 1) 'watcher should report configured max forward count.'
Assert-True ([int]$statusAfterFirstRun.Json.Counts.SourceOutboxImportedCount -eq 1) 'status should count one imported source-outbox target.'
Assert-True ([int]$statusAfterFirstRun.Json.Counts.HandoffReadyCount -ge 1) 'status should count at least one handoff-ready target after source-outbox import.'

$sourceOutboxStatusPath = Join-Path $contractRunRoot '.state\source-outbox-status.json'
$sourceOutboxStatus = Get-Content -LiteralPath $sourceOutboxStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01OutboxStatus = @($sourceOutboxStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$target01OutboxStatus.State -in @('imported', 'imported-archive-pending', 'forwarded', 'duplicate-marker-archived')) 'target01 source-outbox status should report import success.'
Assert-True ([string]$target01OutboxStatus.ContractLatestState -eq 'ready-to-forward') 'target01 source-outbox status should surface contract latest state.'
Assert-True ([string]$target01OutboxStatus.NextAction -eq 'handoff-ready') 'target01 source-outbox status should surface next handoff action.'
Assert-True ([int]$target01OutboxStatus.PublishSequence -eq [int]$target01ReadyPayload.PublishSequence) 'target01 source-outbox status should surface publish sequence.'
Assert-True ([string]$target01OutboxStatus.PublishCycleId -eq [string]$target01ReadyPayload.PublishCycleId) 'target01 source-outbox status should surface publish cycle id.'
Assert-True ([int]$target01OutboxStatus.ImportedSourcePublishSequence -eq [int]$target01ReadyPayload.PublishSequence) 'target01 source-outbox status should surface imported source publish sequence.'
Assert-True ([string]$target01OutboxStatus.ImportedSourcePublishCycleId -eq [string]$target01ReadyPayload.PublishCycleId) 'target01 source-outbox status should surface imported source publish cycle id.'
Assert-True (@($sourceOutboxStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target05' }).Count -eq 0) 'watcher should stop before processing target05 source-outbox marker when max forward count is reached.'

$sourceOutboxProcessedPath = Join-Path $contractRunRoot '.state\source-outbox-processed.json'
$sourceOutboxProcessed = Get-Content -LiteralPath $sourceOutboxProcessedPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (@($sourceOutboxProcessed.PSObject.Properties).Count -eq 1) 'source-outbox processed state should contain exactly one fingerprint after first publish.'

$target01ReadyPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $target01PublishReadyPath -Encoding UTF8
$watcherDuplicateRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-RunDurationSec', '3'
)
Assert-True ($watcherDuplicateRun.ExitCode -eq 0) 'watcher should exit cleanly for duplicate marker pass.'
Assert-True (-not (Test-Path -LiteralPath $target01PublishReadyPath -PathType Leaf)) 'duplicate target01 ready marker should be archived without reimport.'
Assert-True (@(Get-ChildItem -LiteralPath $target01ArchiveRoot -Filter '*.ready.json' -File -ErrorAction SilentlyContinue).Count -eq 2) 'target01 archive folder should contain two archived ready markers after duplicate pass.'
Assert-True (@(Get-ChildItem -LiteralPath $target01ReviewRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue).Count -eq 1) 'duplicate ready marker should not create a second imported zip.'

$sourceOutboxStatusAfterDuplicate = Get-Content -LiteralPath $sourceOutboxStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01OutboxStatusAfterDuplicate = @($sourceOutboxStatusAfterDuplicate.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$target01OutboxStatusAfterDuplicate.State -in @('duplicate-marker-archived', 'duplicate-marker-present')) 'duplicate target01 ready marker should be reported as skipped.'

Write-Host ('paired-exchange source-outbox publish ok: runRoot=' + $contractRunRoot)
