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
        Raw      = $raw
        Json     = $json
    }
}

function Get-ZipFingerprint {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$ZipPath
    )

    $zipItem = Get-Item -LiteralPath $ZipPath -ErrorAction Stop
    return ('{0}|{1}|{2}|{3}' -f
        [string]$TargetId,
        $zipItem.FullName.ToLowerInvariant(),
        [int64]$zipItem.Length,
        [int64]$zipItem.LastWriteTimeUtc.Ticks
    )
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_import_artifact_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$sourceRoot = Join-Path $contractRunRoot '_external_artifact_source'
New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null

$summarySourcePath = Join-Path $sourceRoot 'review-summary.md'
$zipNotePath = Join-Path $sourceRoot 'notes.txt'
$zipSourcePath = Join-Path $sourceRoot 'frontend-backend-review.zip'

$summaryText = @'
핵심 검토 결과
- import bridge smoke test
- stale summary warning expected before import
'@
[System.IO.File]::WriteAllText($summarySourcePath, $summaryText, (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($zipNotePath, 'external artifact zip content', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $zipSourcePath -Force
(Get-Item -LiteralPath $summarySourcePath).LastWriteTime = (Get-Date).AddSeconds(-10)

$targetRoot = Join-Path $contractRunRoot 'pair01\target01'
$errorPath = Join-Path $targetRoot 'error.json'
Set-Content -LiteralPath $errorPath -Value '{"Error":"stale-before-import"}' -Encoding UTF8

$commonArgs = @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-TargetId', 'target01',
    '-SummarySourcePath', $summarySourcePath,
    '-ReviewZipSourcePath', $zipSourcePath,
    '-AsJson'
)

$check = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'check-paired-exchange-artifact.ps1') -Arguments $commonArgs
Assert-True ($check.ExitCode -eq 0) 'check script should succeed for valid external artifacts.'
Assert-True ([bool]$check.Json.Validation.Ok) 'check validation should be ok.'

$checkWarnings = @($check.Json.Validation.Warnings | ForEach-Object { [string]$_ })
Assert-True ('manual-copy-would-be-summary-stale' -in $checkWarnings) 'expected stale summary warning before import.'
Assert-True ('stale-error-marker-present' -in $checkWarnings) 'expected stale error marker warning before import.'
Assert-True ([string]$check.Json.Validation.ManualCopyLikelyState -eq 'summary-stale') 'manual copy should be predicted as summary-stale.'
$preflightLines = @($check.Json.Preflight.SummaryLines | ForEach-Object { [string]$_ })
Assert-True ($preflightLines -match 'source summary/source zip') 'preflight should clarify source artifact vs paired submit.'

$import = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'import-paired-exchange-artifact.ps1') -Arguments $commonArgs
Assert-True ($import.ExitCode -eq 0) 'import script should succeed for valid external artifacts.'
Assert-True ([bool]$import.Json.Validation.Ok) 'import validation should be ok.'
Assert-True ([string]$import.Json.PostImportStatus.LatestState -eq 'ready-to-forward') 'post import status should be ready-to-forward.'
$resultPayload = Get-Content -LiteralPath ([string]$import.Json.Contract.ResultPath) -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$resultPayload.LatestZipPath -eq [string]$import.Json.Contract.DestinationZipPath) 'result payload should record LatestZipPath for the imported zip.'

$status = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'show-paired-exchange-status.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-AsJson'
)
Assert-True ($status.ExitCode -eq 0) 'paired status should succeed.'

$targetRow = @($status.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)
Assert-True ($targetRow.Count -eq 1) 'target01 row should exist in paired status.'
$target = $targetRow[0]

Assert-True ([string]$target.LatestState -eq 'ready-to-forward') 'target01 latest state should be ready-to-forward.'
Assert-True ([bool]$target.DonePresent) 'done.json should exist after import.'
Assert-True (-not [bool]$target.ErrorPresent) 'stale error.json should not remain blocking after import.'
Assert-True ([bool]$target.ErrorSuperseded) 'stale error.json should be marked as superseded after import.'
Assert-True ([int]$target.ZipCount -eq 1) 'target01 should have exactly one imported zip.'

$repeatCheck = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'check-paired-exchange-artifact.ps1') -Arguments $commonArgs
Assert-True ($repeatCheck.ExitCode -eq 0) 'repeat check should succeed and report overwrite requirement.'
Assert-True ([bool]$repeatCheck.Json.Validation.Ok) 'repeat check validation should remain ok.'
Assert-True ([bool]$repeatCheck.Json.Validation.RequiresOverwrite) 'repeat check should require overwrite after ready state exists.'

$repeatImportBlocked = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'import-paired-exchange-artifact.ps1') -Arguments $commonArgs
Assert-True ($repeatImportBlocked.ExitCode -ne 0) 'repeat import without overwrite should be blocked.'
$repeatIssues = @($repeatImportBlocked.Json.Validation.Issues | ForEach-Object { [string]$_ })
Assert-True ('overwrite-required-existing-target-state' -in $repeatIssues) 'repeat import should block on existing target state.'
Assert-True ('overwrite-required-existing-contract-files' -in $repeatIssues) 'repeat import should block on existing contract files.'

$overwriteImport = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'import-paired-exchange-artifact.ps1') -Arguments ($commonArgs + @('-Overwrite'))
Assert-True ($overwriteImport.ExitCode -eq 0) 'repeat import with overwrite should succeed.'
Assert-True ([bool]$overwriteImport.Json.Overwrite) 'overwrite import payload should report overwrite=true.'

$forwardedMapPath = Join-Path $contractRunRoot '.state\forwarded.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $forwardedMapPath) -Force | Out-Null
$latestZipPath = [string]$overwriteImport.Json.Contract.DestinationZipPath
$fingerprint = Get-ZipFingerprint -TargetId 'target01' -ZipPath $latestZipPath
([ordered]@{ $fingerprint = (Get-Date).ToString('o') } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $forwardedMapPath -Encoding UTF8

$forwardedCheck = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'check-paired-exchange-artifact.ps1') -Arguments $commonArgs
Assert-True ($forwardedCheck.ExitCode -eq 0) 'forwarded check should still succeed as a preflight.'
Assert-True ([string]$forwardedCheck.Json.Preflight.CurrentLatestState -eq 'forwarded') 'forwarded preflight should report forwarded state.'
Assert-True ([bool]$forwardedCheck.Json.Validation.RequiresOverwrite) 'forwarded preflight should require overwrite.'

$invalidCheck = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'check-paired-exchange-artifact.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-TargetId', 'target01',
    '-SummarySourcePath', (Join-Path $sourceRoot 'missing-summary.md'),
    '-ReviewZipSourcePath', $zipSourcePath,
    '-AsJson'
)
Assert-True ($invalidCheck.ExitCode -ne 0) 'missing summary check should fail.'
$invalidIssues = @($invalidCheck.Json.Validation.Issues | ForEach-Object { [string]$_ })
Assert-True ('summary-source-missing' -in $invalidIssues) 'missing summary should be reported.'

$strictRunRoot = Join-Path $pairRunRootBase ('run_contract_import_error_strict_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $strictRunRoot `
    -IncludePairId pair01 | Out-Null

$strictTargetRoot = Join-Path $strictRunRoot 'pair01\target01'
$strictReviewRoot = Join-Path $strictTargetRoot 'reviewfile'
$strictSummaryPath = Join-Path $strictTargetRoot 'summary.txt'
$strictZipNotePath = Join-Path $strictReviewRoot 'strict-note.txt'
$strictZipPath = Join-Path $strictReviewRoot 'strict-review.zip'
$strictErrorPath = Join-Path $strictTargetRoot 'error.json'

[System.IO.File]::WriteAllText($strictSummaryPath, 'strict error supersede test', (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($strictZipNotePath, 'strict zip content', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $strictZipNotePath -DestinationPath $strictZipPath -Force
Set-Content -LiteralPath $strictErrorPath -Value '{"Error":"older-error"}' -Encoding UTF8
(Get-Item -LiteralPath $strictErrorPath).LastWriteTime = (Get-Date).AddMinutes(-5)
(Get-Item -LiteralPath $strictSummaryPath).LastWriteTime = (Get-Date).AddMinutes(-1)
(Get-Item -LiteralPath $strictZipPath).LastWriteTime = Get-Date

$strictStatus = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'show-paired-exchange-status.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $strictRunRoot,
    '-AsJson'
)
Assert-True ($strictStatus.ExitCode -eq 0) 'strict status should succeed.'
$strictTargetRow = @($strictStatus.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)
Assert-True ($strictTargetRow.Count -eq 1) 'strict target01 row should exist.'
$strictTarget = $strictTargetRow[0]
Assert-True ([string]$strictTarget.LatestState -eq 'error-present') 'error should remain blocking without done/result success evidence.'
Assert-True ([bool]$strictTarget.ErrorPresent) 'strict target should still report error present.'
Assert-True (-not [bool]$strictTarget.ErrorSuperseded) 'strict target should not mark error as superseded without done/result.'

$mismatchRunRoot = Join-Path $pairRunRootBase ('run_contract_import_error_mismatch_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $mismatchRunRoot `
    -IncludePairId pair01 | Out-Null

$mismatchTargetRoot = Join-Path $mismatchRunRoot 'pair01\target01'
$mismatchReviewRoot = Join-Path $mismatchTargetRoot 'reviewfile'
$mismatchSummaryPath = Join-Path $mismatchTargetRoot 'summary.txt'
$mismatchOldNotePath = Join-Path $mismatchReviewRoot 'old-note.txt'
$mismatchNewNotePath = Join-Path $mismatchReviewRoot 'new-note.txt'
$mismatchOldZipPath = Join-Path $mismatchReviewRoot 'old-manual-import.zip'
$mismatchNewZipPath = Join-Path $mismatchReviewRoot 'new-latest.zip'
$mismatchDonePath = Join-Path $mismatchTargetRoot 'done.json'
$mismatchResultPath = Join-Path $mismatchTargetRoot 'result.json'
$mismatchErrorPath = Join-Path $mismatchTargetRoot 'error.json'

[System.IO.File]::WriteAllText($mismatchSummaryPath, 'manual import mismatch test', (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($mismatchOldNotePath, 'old zip content', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $mismatchOldNotePath -DestinationPath $mismatchOldZipPath -Force
Start-Sleep -Milliseconds 1100
[System.IO.File]::WriteAllText($mismatchNewNotePath, 'new latest zip content', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $mismatchNewNotePath -DestinationPath $mismatchNewZipPath -Force

$mismatchDonePayload = [ordered]@{
    CompletedAt      = (Get-Date).ToString('o')
    Mode             = 'manual-import'
    TargetId         = 'target01'
    SummaryPath      = $mismatchSummaryPath
    LatestZipPath    = $mismatchOldZipPath
    ResultPath       = $mismatchResultPath
}
$mismatchResultPayload = [ordered]@{
    CompletedAt      = (Get-Date).ToString('o')
    Mode             = 'manual-import'
    TargetId         = 'target01'
    SummaryPath      = $mismatchSummaryPath
    LatestZipPath    = $mismatchOldZipPath
    ImportedZipPath  = $mismatchOldZipPath
}
$mismatchDonePayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $mismatchDonePath -Encoding UTF8
$mismatchResultPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $mismatchResultPath -Encoding UTF8
Set-Content -LiteralPath $mismatchErrorPath -Value '{"Error":"zip-mismatch-should-stay-blocking"}' -Encoding UTF8
(Get-Item -LiteralPath $mismatchErrorPath).LastWriteTime = (Get-Date).AddMinutes(-5)
(Get-Item -LiteralPath $mismatchDonePath).LastWriteTime = (Get-Date).AddMinutes(-1)
(Get-Item -LiteralPath $mismatchResultPath).LastWriteTime = (Get-Date).AddMinutes(-1)
(Get-Item -LiteralPath $mismatchSummaryPath).LastWriteTime = (Get-Date).AddMinutes(-1)
(Get-Item -LiteralPath $mismatchOldZipPath).LastWriteTime = (Get-Date).AddMinutes(-2)
(Get-Item -LiteralPath $mismatchNewZipPath).LastWriteTime = Get-Date

$mismatchStatus = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'show-paired-exchange-status.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $mismatchRunRoot,
    '-AsJson'
)
Assert-True ($mismatchStatus.ExitCode -eq 0) 'mismatch status should succeed.'
$mismatchTargetRow = @($mismatchStatus.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)
Assert-True ($mismatchTargetRow.Count -eq 1) 'mismatch target01 row should exist.'
$mismatchTarget = $mismatchTargetRow[0]
Assert-True ([string]$mismatchTarget.LatestZipName -eq 'new-latest.zip') 'mismatch run should pick the newer zip as latest.'
Assert-True ([string]$mismatchTarget.LatestState -eq 'error-present') 'old manual-import marker should not supersede error when latest zip changed.'
Assert-True ([bool]$mismatchTarget.ErrorPresent) 'mismatch run should still report error present.'
Assert-True (-not [bool]$mismatchTarget.ErrorSuperseded) 'mismatch run should not mark error as superseded when LatestZipPath mismatches current latest zip.'

Write-Host ('import-paired-exchange-artifact hardening smoke ok: runRoot=' + $contractRunRoot + ' strictRunRoot=' + $strictRunRoot + ' mismatchRunRoot=' + $mismatchRunRoot)
