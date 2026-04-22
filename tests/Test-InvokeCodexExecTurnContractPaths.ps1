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

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )

    [System.IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 12), (New-Utf8NoBomEncoding))
}

function Set-ContractOverrides {
    param(
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ReviewFolderPath,
        [Parameter(Mandatory)][string]$DonePath,
        [Parameter(Mandatory)][string]$ErrorPath,
        [Parameter(Mandatory)][string]$ResultPath
    )

    $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $request.SummaryPath = $SummaryPath
    $request.ReviewFolderPath = $ReviewFolderPath
    $request.DoneFilePath = $DonePath
    $request.ErrorFilePath = $ErrorPath
    $request.ResultFilePath = $ResultPath
    Write-JsonFile -Path $RequestPath -Object $request
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return $Value.Replace("'", "''")
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase

$overrideRunRoot = Join-Path $pairRunRootBase ('run_contract_exec_contract_paths_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $overrideRunRoot `
    -IncludePairId pair01 | Out-Null

$overrideTargetRoot = Join-Path $overrideRunRoot 'pair01\target01'
$overrideRequestPath = Join-Path $overrideTargetRoot 'request.json'
$overrideContractRoot = Join-Path $overrideTargetRoot 'override-contract'
$overrideSummaryPath = Join-Path $overrideContractRoot 'summary.txt'
$overrideReviewFolderPath = Join-Path $overrideContractRoot 'reviewfile'
$overrideDonePath = Join-Path $overrideContractRoot 'done.json'
$overrideErrorPath = Join-Path $overrideContractRoot 'error.json'
$overrideResultPath = Join-Path $overrideContractRoot 'result.json'

New-Item -ItemType Directory -Path $overrideReviewFolderPath -Force | Out-Null
Set-ContractOverrides `
    -RequestPath $overrideRequestPath `
    -SummaryPath $overrideSummaryPath `
    -ReviewFolderPath $overrideReviewFolderPath `
    -DonePath $overrideDonePath `
    -ErrorPath $overrideErrorPath `
    -ResultPath $overrideResultPath

[System.IO.File]::WriteAllText($overrideSummaryPath, 'override contract summary', (New-Utf8NoBomEncoding))
$overrideZipInputPath = Join-Path $overrideContractRoot 'override-note.txt'
[System.IO.File]::WriteAllText($overrideZipInputPath, 'override contract zip payload', (New-Utf8NoBomEncoding))
$overrideZipPath = Join-Path $overrideReviewFolderPath 'override-review.zip'
Compress-Archive -LiteralPath $overrideZipInputPath -DestinationPath $overrideZipPath -Force

$overrideStatus = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'show-paired-exchange-status.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $overrideRunRoot,
    '-AsJson'
)
$overrideTarget = @($overrideStatus.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Assert-True ($overrideStatus.ExitCode -eq 0) 'show-paired-exchange-status should succeed for override contract case.'
Assert-True ([string]$overrideTarget.RequestPath -eq $overrideRequestPath) 'status should surface the request path for the target.'
Assert-True ([string]$overrideTarget.SummaryPath -eq $overrideSummaryPath) 'status should resolve SummaryPath from request overrides.'
Assert-True ([string]$overrideTarget.ReviewFolderPath -eq $overrideReviewFolderPath) 'status should resolve ReviewFolderPath from request overrides.'
Assert-True ([string]$overrideTarget.DonePath -eq $overrideDonePath) 'status should resolve DonePath from request overrides.'
Assert-True ([string]$overrideTarget.ErrorPath -eq $overrideErrorPath) 'status should resolve ErrorPath from request overrides.'
Assert-True ([string]$overrideTarget.ResultPath -eq $overrideResultPath) 'status should resolve ResultPath from request overrides.'
Assert-True ([bool]$overrideTarget.SummaryPresent) 'status should find the override summary file.'
Assert-True ([int]$overrideTarget.ZipCount -eq 1) 'status should count the override review zip.'
Assert-True ([string]$overrideTarget.LatestState -eq 'ready-to-forward') 'status should compute LatestState from override contract paths.'

$overrideDryRun = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $overrideRunRoot,
    '-TargetId', 'target01',
    '-DryRun',
    '-AsJson'
)

Assert-True ($overrideDryRun.ExitCode -eq 0) 'invoke-codex-exec-turn dry-run should succeed for override contract case.'
Assert-True ([string]$overrideDryRun.Json.SummaryPath -eq $overrideSummaryPath) 'dry-run should resolve SummaryPath from request overrides.'
Assert-True ([string]$overrideDryRun.Json.ReviewFolderPath -eq $overrideReviewFolderPath) 'dry-run should resolve ReviewFolderPath from request overrides.'
Assert-True ([string]$overrideDryRun.Json.DonePath -eq $overrideDonePath) 'dry-run should resolve DonePath from request overrides.'
Assert-True ([string]$overrideDryRun.Json.ErrorPath -eq $overrideErrorPath) 'dry-run should resolve ErrorPath from request overrides.'
Assert-True ([string]$overrideDryRun.Json.ResultPath -eq $overrideResultPath) 'dry-run should resolve ResultPath from request overrides.'

$staleRunRoot = Join-Path $pairRunRootBase ('run_contract_exec_stale_zip_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $staleRunRoot `
    -IncludePairId pair01 | Out-Null

$staleTargetRoot = Join-Path $staleRunRoot 'pair01\target01'
$staleReviewFolderPath = Join-Path $staleTargetRoot 'reviewfile'
New-Item -ItemType Directory -Path $staleReviewFolderPath -Force | Out-Null
$staleZipInputPath = Join-Path $staleTargetRoot 'stale-note.txt'
[System.IO.File]::WriteAllText($staleZipInputPath, 'stale zip payload', (New-Utf8NoBomEncoding))
$staleZipPath = Join-Path $staleReviewFolderPath 'review_target01_stale.zip'
Compress-Archive -LiteralPath $staleZipInputPath -DestinationPath $staleZipPath -Force
$staleZipItem = Get-Item -LiteralPath $staleZipPath -ErrorAction Stop
$staleZipAt = (Get-Date).AddMinutes(-5)
$staleZipItem.LastWriteTime = $staleZipAt
$staleZipItem.LastWriteTimeUtc = $staleZipAt.ToUniversalTime()

$fakeCodexPath = Join-Path $staleRunRoot 'fake-codex.cmd'
$fakeCodexContent = @'
@echo off
more >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$request = Get-Content -LiteralPath 'request.json' -Raw -Encoding UTF8 | ConvertFrom-Json; $summaryPath = if ([string]::IsNullOrWhiteSpace([string]$request.SummaryPath)) { Join-Path (Get-Location) 'summary.txt' } else { [string]$request.SummaryPath }; $parent = Split-Path -Parent $summaryPath; if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }; [System.IO.File]::WriteAllText($summaryPath, 'fresh summary from fake codex', [System.Text.UTF8Encoding]::new($false))"
exit /b 0
'@
[System.IO.File]::WriteAllText($fakeCodexPath, $fakeCodexContent, (New-Utf8NoBomEncoding))

$staleConfigPath = Join-Path $staleRunRoot 'settings.headless.psd1'
$staleConfigRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$staleConfigRaw = $staleConfigRaw.Replace("            Enabled                   = `$false", "            Enabled                   = `$true")
$staleConfigRaw = $staleConfigRaw.Replace("            CodexExecutable           = 'codex'", ("            CodexExecutable           = '" + (ConvertTo-PowerShellSingleQuotedLiteral -Value $fakeCodexPath) + "'"))
$staleConfigRaw = $staleConfigRaw.Replace("            Arguments                 = @('exec', '--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox')", "            Arguments                 = @()")
[System.IO.File]::WriteAllText($staleConfigPath, $staleConfigRaw, (New-Utf8NoBomEncoding))

$staleExec = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $staleConfigPath,
    '-RunRoot', $staleRunRoot,
    '-TargetId', 'target01',
    '-AsJson'
)

$staleDonePath = Join-Path $staleTargetRoot 'done.json'
$staleErrorPath = Join-Path $staleTargetRoot 'error.json'
$staleResultPath = Join-Path $staleTargetRoot 'result.json'
$staleError = Get-Content -LiteralPath $staleErrorPath -Raw -Encoding UTF8 | ConvertFrom-Json
$staleResult = Get-Content -LiteralPath $staleResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$staleStatus = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'show-paired-exchange-status.ps1') -Arguments @(
    '-ConfigPath', $staleConfigPath,
    '-RunRoot', $staleRunRoot,
    '-AsJson'
)
$staleTarget = @($staleStatus.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Assert-True ($staleExec.ExitCode -eq 0) 'invoke-codex-exec-turn should return cleanly when stale zip blocks contract success.'
Assert-True (-not [bool]$staleExec.Json.ContractArtifactsReady) 'stale zip should not satisfy ContractArtifactsReady.'
Assert-True ([string]$staleExec.Json.ContractArtifactsReadyReason -eq 'zip-not-fresh') 'stale zip should report zip-not-fresh readiness reason.'
Assert-True ([bool]$staleExec.Json.SummaryFresh) 'current summary should be marked fresh.'
Assert-True (-not [bool]$staleExec.Json.LatestZipFresh) 'pre-existing stale zip should not be marked fresh.'
Assert-True (-not (Test-Path -LiteralPath $staleDonePath)) 'executor should not write done.json when only a stale zip exists.'
Assert-True ((Test-Path -LiteralPath $staleErrorPath -PathType Leaf)) 'executor should write error.json when stale zip blocks success.'
Assert-True ([string]$staleError.Reason -eq 'zip-stale-after-exec') 'error.json should record zip-stale-after-exec.'
Assert-True (-not [bool]$staleResult.ContractArtifactsReady) 'result.json should record ContractArtifactsReady=false.'
Assert-True (-not [bool]$staleResult.LatestZipFresh) 'result.json should record LatestZipFresh=false.'
Assert-True ([bool]$staleTarget.ErrorPresent) 'status should surface the stale-zip failure as an active error.'
Assert-True ([string]$staleTarget.LatestState -eq 'error-present') 'status should report error-present once executor records the stale-zip failure.'

$sourceOutboxRunRoot = Join-Path $pairRunRootBase ('run_contract_exec_source_outbox_done_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $sourceOutboxRunRoot `
    -IncludePairId pair01 | Out-Null

$sourceOutboxTargetRoot = Join-Path $sourceOutboxRunRoot 'pair01\target01'
$sourceOutboxDonePath = Join-Path $sourceOutboxTargetRoot 'done.json'
$sourceOutboxErrorPath = Join-Path $sourceOutboxTargetRoot 'error.json'
$sourceOutboxResultPath = Join-Path $sourceOutboxTargetRoot 'result.json'
$sourceOutboxFakeCodexPath = Join-Path $sourceOutboxRunRoot 'fake-codex-source-outbox.cmd'
$sourceOutboxFakeCodexContent = @'
@echo off
more >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$request = Get-Content -LiteralPath 'request.json' -Raw -Encoding UTF8 | ConvertFrom-Json; $summaryPath = [string]$request.SourceSummaryPath; $reviewZipPath = [string]$request.SourceReviewZipPath; $publishReadyPath = [string]$request.PublishReadyPath; $outboxPath = Split-Path -Parent $summaryPath; if ($outboxPath -and -not (Test-Path -LiteralPath $outboxPath)) { New-Item -ItemType Directory -Path $outboxPath -Force | Out-Null }; [System.IO.File]::WriteAllText($summaryPath, 'fresh source-outbox summary', [System.Text.UTF8Encoding]::new($false)); $notePath = Join-Path $outboxPath 'source-outbox-note.txt'; [System.IO.File]::WriteAllText($notePath, 'fresh source-outbox zip payload', [System.Text.UTF8Encoding]::new($false)); Compress-Archive -LiteralPath $notePath -DestinationPath $reviewZipPath -Force; $summaryItem = Get-Item -LiteralPath $summaryPath -ErrorAction Stop; $zipItem = Get-Item -LiteralPath $reviewZipPath -ErrorAction Stop; $payload = [ordered]@{ SchemaVersion = '1.0.0'; PairId = [string]$request.PairId; TargetId = [string]$request.TargetId; SummaryPath = $summaryPath; ReviewZipPath = $reviewZipPath; PublishedAt = (Get-Date).ToString('o'); SummarySizeBytes = [int64]$summaryItem.Length; ReviewZipSizeBytes = [int64]$zipItem.Length }; $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $publishReadyPath -Encoding UTF8"
exit /b 0
'@
[System.IO.File]::WriteAllText($sourceOutboxFakeCodexPath, $sourceOutboxFakeCodexContent, (New-Utf8NoBomEncoding))

$sourceOutboxConfigPath = Join-Path $sourceOutboxRunRoot 'settings.headless-source-outbox.psd1'
$sourceOutboxConfigRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$sourceOutboxConfigRaw = $sourceOutboxConfigRaw.Replace("            Enabled                   = `$false", "            Enabled                   = `$true")
$sourceOutboxConfigRaw = $sourceOutboxConfigRaw.Replace("            CodexExecutable           = 'codex'", ("            CodexExecutable           = '" + (ConvertTo-PowerShellSingleQuotedLiteral -Value $sourceOutboxFakeCodexPath) + "'"))
$sourceOutboxConfigRaw = $sourceOutboxConfigRaw.Replace("            Arguments                 = @('exec', '--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox')", "            Arguments                 = @()")
[System.IO.File]::WriteAllText($sourceOutboxConfigPath, $sourceOutboxConfigRaw, (New-Utf8NoBomEncoding))

$sourceOutboxExec = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $sourceOutboxConfigPath,
    '-RunRoot', $sourceOutboxRunRoot,
    '-TargetId', 'target01',
    '-AsJson'
)

$sourceOutboxDone = Get-Content -LiteralPath $sourceOutboxDonePath -Raw -Encoding UTF8 | ConvertFrom-Json
$sourceOutboxResult = Get-Content -LiteralPath $sourceOutboxResultPath -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-True ($sourceOutboxExec.ExitCode -eq 0) 'invoke-codex-exec-turn should return cleanly for source-outbox publish success.'
Assert-True ([bool]$sourceOutboxExec.Json.SourceOutboxReady) 'source-outbox branch should detect published artifacts.'
Assert-True (-not [bool]$sourceOutboxExec.Json.ContractArtifactsReady) 'source-outbox success should not require immediate contract freshness.'
Assert-True ((Test-Path -LiteralPath $sourceOutboxDonePath -PathType Leaf)) 'source-outbox success should leave done.json present.'
Assert-True (-not (Test-Path -LiteralPath $sourceOutboxErrorPath)) 'source-outbox success should not leave error.json present.'
Assert-True ([string]$sourceOutboxDone.Mode -eq 'source-outbox-publish') 'done.json should record source-outbox-publish mode for asynchronous success.'
Assert-True ([bool]$sourceOutboxResult.SourceOutboxReady) 'result.json should record SourceOutboxReady=true for asynchronous success.'
Assert-True ([string]$sourceOutboxDone.PublishReadyPath -eq [string]$sourceOutboxResult.PublishReadyPath) 'done.json should point at the publish.ready marker used for source-outbox success.'
Assert-True ([string]$sourceOutboxResult.ContractArtifactsReadyReason -in @('summary-not-fresh', 'zip-not-fresh', 'summary-missing', 'zip-missing')) 'result.json should explain why contract freshness was deferred.'

Write-Host ('invoke-codex-exec-turn contract path + stale zip guards ok: overrideRunRoot=' + $overrideRunRoot + ' staleRunRoot=' + $staleRunRoot + ' sourceOutboxRunRoot=' + $sourceOutboxRunRoot)
