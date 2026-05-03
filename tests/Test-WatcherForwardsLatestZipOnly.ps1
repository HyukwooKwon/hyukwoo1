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

function Invoke-PowerShellProcess {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $ScriptPath @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Raw      = (($result | Out-String).Trim())
    }
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return $Value.Replace("'", "''")
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
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_latest_zip_only_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$target01Root = Join-Path $contractRunRoot 'pair01\target01'
$target01ReviewRoot = Join-Path $target01Root 'reviewfile'
$target01SummaryPath = Join-Path $target01Root 'summary.txt'
$target01DonePath = Join-Path $target01Root 'done.json'
$target01OldNotePath = Join-Path $target01Root 'note-old.txt'
$target01NewNotePath = Join-Path $target01Root 'note-new.txt'
$target01OldZipPath = Join-Path $target01ReviewRoot 'review_target01_older.zip'
$target01NewZipPath = Join-Path $target01ReviewRoot 'review_target01_latest.zip'

New-Item -ItemType Directory -Path $target01ReviewRoot -Force | Out-Null
[System.IO.File]::WriteAllText($target01OldNotePath, 'older zip payload', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $target01OldNotePath -DestinationPath $target01OldZipPath -Force
Start-Sleep -Milliseconds 1200
[System.IO.File]::WriteAllText($target01NewNotePath, 'latest zip payload', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $target01NewNotePath -DestinationPath $target01NewZipPath -Force
[System.IO.File]::WriteAllText($target01SummaryPath, 'summary for latest zip', (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($target01DonePath, (@{
    CompletedAt = (Get-Date).ToString('o')
    Mode        = 'manual-test'
} | ConvertTo-Json -Depth 4), (New-Utf8NoBomEncoding))

$fakeCodexPath = Join-Path $contractRunRoot 'fake-codex-latest-only.ps1'
$fakeCodexScript = @'
param()

[void][Console]::In.ReadToEnd()
$request = Get-Content -LiteralPath 'request.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$summaryPath = if ([string]::IsNullOrWhiteSpace([string]$request.SummaryPath)) { Join-Path (Get-Location) 'summary.txt' } else { [string]$request.SummaryPath }
$reviewFolderPath = if ([string]::IsNullOrWhiteSpace([string]$request.ReviewFolderPath)) { Join-Path (Get-Location) 'reviewfile' } else { [string]$request.ReviewFolderPath }
if (-not (Test-Path -LiteralPath $reviewFolderPath)) {
    New-Item -ItemType Directory -Path $reviewFolderPath -Force | Out-Null
}
$summaryParent = Split-Path -Parent $summaryPath
if (-not [string]::IsNullOrWhiteSpace($summaryParent) -and -not (Test-Path -LiteralPath $summaryParent)) {
    New-Item -ItemType Directory -Path $summaryParent -Force | Out-Null
}
[System.IO.File]::WriteAllText($summaryPath, 'forwarded summary from fake codex', [System.Text.UTF8Encoding]::new($false))
$notePath = Join-Path $reviewFolderPath 'forwarded-note.txt'
[System.IO.File]::WriteAllText($notePath, 'forwarded zip payload', [System.Text.UTF8Encoding]::new($false))
$zipPath = Join-Path $reviewFolderPath 'forwarded-review.zip'
Compress-Archive -LiteralPath $notePath -DestinationPath $zipPath -Force
'@
[System.IO.File]::WriteAllText($fakeCodexPath, $fakeCodexScript, (New-Utf8NoBomEncoding))

$headlessConfigPath = Join-Path $contractRunRoot 'settings.headless-latest-only.psd1'
$headlessConfigRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$headlessConfigRaw = [System.Text.RegularExpressions.Regex]::Replace(
    $headlessConfigRaw,
    "(?m)(CodexExecutable\s*=\s*)'[^']*'",
    ('$1' + "'" + (ConvertTo-PowerShellSingleQuotedLiteral -Value $fakeCodexPath) + "'")
)
$headlessConfigRaw = [System.Text.RegularExpressions.Regex]::Replace(
    $headlessConfigRaw,
    "(?ms)(Arguments\s*=\s*)@\([^\)]*\)",
    '$1@()'
)
[System.IO.File]::WriteAllText($headlessConfigPath, $headlessConfigRaw, (New-Utf8NoBomEncoding))

$watcherRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $headlessConfigPath,
    '-RunRoot', $contractRunRoot,
    '-UseHeadlessDispatch',
    '-AllowHeadlessDispatchInTypedWindowLane',
    '-MaxForwardCount', '1',
    '-RunDurationSec', '90'
)

Assert-True ($watcherRun.ExitCode -eq 0) 'watcher should complete cleanly for latest-zip-only test.'

$messagesRoot = Join-Path $contractRunRoot 'messages'
$handoffMessage = Get-ChildItem -LiteralPath $messagesRoot -Filter 'handoff_target01_to_target05_*.txt' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc |
    Select-Object -Last 1
Assert-True ($null -ne $handoffMessage) 'watcher should emit a handoff message for target05.'
$handoffText = Get-Content -LiteralPath $handoffMessage.FullName -Raw -Encoding UTF8
Assert-True ($handoffText.Contains($target01NewZipPath)) 'handoff should use the latest zip path.'
Assert-True (-not $handoffText.Contains($target01OldZipPath)) 'handoff should not retry the older zip once a newer zip exists.'

$pairedStatus = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -Arguments @(
    '-ConfigPath', $headlessConfigPath,
    '-RunRoot', $contractRunRoot,
    '-AsJson'
)

Assert-True ([int]$pairedStatus.Json.Counts.ForwardedStateCount -eq 1) 'watcher should forward exactly one latest zip in this smoke test.'
Assert-True ([string]$pairedStatus.Json.Watcher.StatusReason -eq 'max-forward-count-reached') 'watcher should stop due to max forward count.'
Assert-True ([int]$pairedStatus.Json.Counts.FailureLineCount -eq 0) 'latest-zip-only smoke test should not record handoff failures.'

Write-Host ('watcher latest zip only contract ok: runRoot=' + $contractRunRoot)
