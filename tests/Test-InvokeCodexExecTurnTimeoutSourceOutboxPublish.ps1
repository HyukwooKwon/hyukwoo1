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

$runRoot = Join-Path $pairRunRootBase ('run_contract_exec_timeout_source_outbox_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 | Out-Null

$targetRoot = Join-Path $runRoot 'pair01\target01'
$donePath = Join-Path $targetRoot 'done.json'
$errorPath = Join-Path $targetRoot 'error.json'
$resultPath = Join-Path $targetRoot 'result.json'

$fakeCodexPath = Join-Path $runRoot 'fake-codex-timeout-source-outbox.ps1'
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
[System.IO.File]::WriteAllText($summaryPath, 'fresh source-outbox summary before timeout', [System.Text.UTF8Encoding]::new($false))
$notePath = Join-Path $outboxPath 'source-outbox-timeout-note.txt'
[System.IO.File]::WriteAllText($notePath, 'fresh source-outbox zip payload before timeout', [System.Text.UTF8Encoding]::new($false))
Compress-Archive -LiteralPath $notePath -DestinationPath $reviewZipPath -Force
$summaryItem = Get-Item -LiteralPath $summaryPath -ErrorAction Stop
$zipItem = Get-Item -LiteralPath $reviewZipPath -ErrorAction Stop
$payload = [ordered]@{
    SchemaVersion = '1.0.0'
    PairId = [string]$request.PairId
    TargetId = [string]$request.TargetId
    SummaryPath = $summaryPath
    ReviewZipPath = $reviewZipPath
    PublishedAt = (Get-Date).ToString('o')
    SummarySizeBytes = [int64]$summaryItem.Length
    ReviewZipSizeBytes = [int64]$zipItem.Length
}
$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $publishReadyPath -Encoding UTF8
Write-Output 'published source-outbox marker before timeout'
Start-Sleep -Milliseconds 1800
'@
[System.IO.File]::WriteAllText($fakeCodexPath, $fakeCodexScript, (New-Utf8NoBomEncoding))

$configPathOverride = Join-Path $runRoot 'settings.headless-timeout-source-outbox.psd1'
$configRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$configRaw = $configRaw.Replace("            Enabled                   = `$false", "            Enabled                   = `$true")
$configRaw = $configRaw.Replace("            CodexExecutable           = 'codex'", ("            CodexExecutable           = '" + (ConvertTo-PowerShellSingleQuotedLiteral -Value $fakeCodexPath) + "'"))
$configRaw = $configRaw.Replace("            Arguments                 = @('exec', '--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox')", "            Arguments                 = @()")
[System.IO.File]::WriteAllText($configPathOverride, $configRaw, (New-Utf8NoBomEncoding))

$exec = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $configPathOverride,
    '-RunRoot', $runRoot,
    '-TargetId', 'target01',
    '-TimeoutSec', '1',
    '-AsJson'
)

$done = Get-Content -LiteralPath $donePath -Raw -Encoding UTF8 | ConvertFrom-Json
$result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-True ($exec.ExitCode -eq 0) 'timeout after fresh source-outbox publish should still return cleanly.'
Assert-True ([bool]$exec.Json.SourceOutboxReady) 'timeout source-outbox branch should still detect published artifacts.'
Assert-True ([bool]$exec.Json.TimedOut) 'timeout source-outbox branch should preserve TimedOut=true.'
Assert-True ([bool]$exec.Json.Killed) 'timeout source-outbox branch should preserve Killed=true.'
Assert-True ([string]$exec.Json.KillReason -eq 'timeout') 'timeout source-outbox branch should preserve kill reason.'
Assert-True ((Test-Path -LiteralPath $donePath -PathType Leaf)) 'timeout source-outbox branch should leave done.json present.'
Assert-True (-not (Test-Path -LiteralPath $errorPath -PathType Leaf)) 'timeout source-outbox branch should not leave stale error.json.'
Assert-True ([string]$done.Mode -eq 'source-outbox-publish') 'done.json should record source-outbox-publish mode after timeout recovery.'
Assert-True ([bool]$done.TimedOut) 'done.json should preserve timeout marker for recovered source-outbox success.'
Assert-True ([bool]$result.SourceOutboxReady) 'result.json should record SourceOutboxReady=true after timeout recovery.'
Assert-True ([bool]$result.TimedOut) 'result.json should preserve TimedOut=true after timeout recovery.'

Write-Host ('invoke-codex-exec-turn timeout source-outbox publish recovery ok: runRoot=' + $runRoot)
