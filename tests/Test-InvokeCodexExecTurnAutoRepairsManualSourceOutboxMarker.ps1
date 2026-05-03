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

    return [pscustomobject]@{
        ExitCode = $exitCode
        Raw = $raw
        Json = ($raw | ConvertFrom-Json)
    }
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
$runRoot = Join-Path $pairRunRootBase ('run_exec_manual_marker_repair_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 | Out-Null

$fakeCodexPath = Join-Path $runRoot 'fake-codex-manual-marker.ps1'
$fakeCodexScript = @'
param()

[void][Console]::In.ReadToEnd()
$request = Get-Content -LiteralPath 'request.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$summaryPath = [string]$request.SourceSummaryPath
$reviewZipPath = [string]$request.SourceReviewZipPath
$publishReadyPath = [string]$request.PublishReadyPath
$outboxPath = Split-Path -Parent $summaryPath
if ($outboxPath -and -not (Test-Path -LiteralPath $outboxPath)) {
    New-Item -ItemType Directory -Path $outboxPath -Force | Out-Null
}
[System.IO.File]::WriteAllText($summaryPath, 'exec manual marker summary', [System.Text.UTF8Encoding]::new($false))
$notePath = Join-Path $outboxPath 'exec-manual-marker-note.txt'
[System.IO.File]::WriteAllText($notePath, 'exec manual marker zip payload', [System.Text.UTF8Encoding]::new($false))
Compress-Archive -LiteralPath $notePath -DestinationPath $reviewZipPath -Force
$summaryItem = Get-Item -LiteralPath $summaryPath -ErrorAction Stop
$zipItem = Get-Item -LiteralPath $reviewZipPath -ErrorAction Stop
$publishedAt = (Get-Date).ToString('o')
$payload = [ordered]@{
    SchemaVersion = '1.0.0'
    PairId = [string]$request.PairId
    TargetId = [string]$request.TargetId
    SummaryPath = $summaryPath
    ReviewZipPath = $reviewZipPath
    PublishedAt = $publishedAt
    SummarySizeBytes = [int64]$summaryItem.Length
    ReviewZipSizeBytes = [int64]$zipItem.Length
    SummarySha256 = [string](Get-FileHash -LiteralPath $summaryPath -Algorithm SHA256 -ErrorAction Stop).Hash
    ReviewZipSha256 = [string](Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256 -ErrorAction Stop).Hash
    PublishedBy = 'codex'
    ValidationPassed = $true
    ValidationCompletedAt = $publishedAt
}
$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $publishReadyPath -Encoding UTF8
Write-Output 'wrote manual source-outbox marker'
'@
[System.IO.File]::WriteAllText($fakeCodexPath, $fakeCodexScript, (New-Utf8NoBomEncoding))

$configPathOverride = Join-Path $runRoot 'settings.exec-manual-marker-repair.psd1'
$configRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$configRaw = $configRaw.Replace("            Enabled                   = `$false", "            Enabled                   = `$true")
$configRaw = $configRaw.Replace("            CodexExecutable           = 'codex'", ("            CodexExecutable           = '" + (ConvertTo-PowerShellSingleQuotedLiteral -Value $fakeCodexPath) + "'"))
$configRaw = $configRaw.Replace("            Arguments                 = @('exec', '--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox')", "            Arguments                 = @()")
[System.IO.File]::WriteAllText($configPathOverride, $configRaw, (New-Utf8NoBomEncoding))

$exec = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $configPathOverride,
    '-RunRoot', $runRoot,
    '-TargetId', 'target01',
    '-AsJson'
)

$targetRoot = Join-Path $runRoot 'pair01\target01'
$donePath = Join-Path $targetRoot 'done.json'
$errorPath = Join-Path $targetRoot 'error.json'
$resultPath = Join-Path $targetRoot 'result.json'
$request = Get-Content -LiteralPath (Join-Path $targetRoot 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$publishReadyPath = [string]$request.PublishReadyPath
$done = Get-Content -LiteralPath $donePath -Raw -Encoding UTF8 | ConvertFrom-Json
$result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$repairedReady = Get-Content -LiteralPath $publishReadyPath -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-True ($exec.ExitCode -eq 0) 'invoke-codex-exec-turn should exit cleanly after manual marker auto-repair.'
Assert-True ([bool]$exec.Json.SourceOutboxReady) 'manual marker should be repaired into a ready source-outbox state.'
Assert-True ([bool]$exec.Json.SourceOutboxRepairAttempted) 'manual marker path should record repair attempt.'
Assert-True ([bool]$exec.Json.SourceOutboxRepairSucceeded) 'manual marker path should record repair success.'
Assert-True ([string]$exec.Json.SourceOutboxOriginalReadyReason -eq 'marker-publisher-unsupported') 'exec payload should record the original readiness reason before auto-repair.'
Assert-True ([string]$exec.Json.SourceOutboxFinalReadyReason -eq 'ready') 'exec payload should record the repaired readiness reason.'
Assert-True ((Test-Path -LiteralPath $donePath -PathType Leaf)) 'done.json should exist after manual marker auto-repair.'
Assert-True (-not (Test-Path -LiteralPath $errorPath -PathType Leaf)) 'error.json should not remain after manual marker auto-repair.'
Assert-True ([string]$done.Mode -eq 'source-outbox-publish') 'done.json should keep source-outbox-publish mode after auto-repair.'
Assert-True ([bool]$result.SourceOutboxRepairSucceeded) 'result.json should record source-outbox repair success.'
Assert-True ([string]$result.SourceOutboxOriginalReadyReason -eq 'marker-publisher-unsupported') 'result.json should record the original readiness reason before auto-repair.'
Assert-True ([string]$result.SourceOutboxFinalReadyReason -eq 'ready') 'result.json should record the repaired readiness reason.'
Assert-True ([string]$result.SourceOutboxRepairSourceContext -eq 'exec-auto-repair:marker-publisher-unsupported') 'result.json should record the repair source context.'
Assert-True ([string]$repairedReady.PublishedBy -eq 'publish-paired-exchange-artifact.ps1') 'publish.ready.json should be rewritten by publish helper.'

Write-Host ('invoke-codex-exec-turn manual source-outbox marker auto-repair ok: runRoot=' + $runRoot)
