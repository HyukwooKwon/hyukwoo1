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
    foreach ($name in @('pwsh.exe', 'pwsh')) {
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

    throw 'pwsh (PowerShell 7+)를 찾지 못했습니다.'
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
        Raw      = ($result | Out-String).Trim()
    }
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
$runRoot = Join-Path $pairRunRootBase ('run_watch_archived_duplicate_marker_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair04 | Out-Null

$targetRoot = Join-Path $runRoot 'pair04\target04'
$request = Get-Content -LiteralPath (Join-Path $targetRoot 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$summaryPath = [string]$request.SourceSummaryPath
$reviewZipPath = [string]$request.SourceReviewZipPath
$publishReadyPath = [string]$request.PublishReadyPath
$publishScriptPath = [string]$request.PublishScriptPath
$archiveRoot = [string]$request.PublishedArchivePath
$sourceOutboxRoot = Split-Path -Parent $summaryPath

New-Item -ItemType Directory -Path $sourceOutboxRoot -Force | Out-Null
[System.IO.File]::WriteAllText($summaryPath, 'archived duplicate marker summary', (New-Utf8NoBomEncoding))
$zipNotePath = Join-Path $sourceOutboxRoot 'archived-duplicate-marker-note.txt'
[System.IO.File]::WriteAllText($zipNotePath, 'archived duplicate marker zip payload', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $reviewZipPath -Force

$publish = Invoke-PowerShellProcess -ScriptPath $publishScriptPath -Arguments @(
    '-Overwrite',
    '-SourceContext', 'watch-test-archived-duplicate-marker',
    '-AsJson'
)
Assert-True ($publish.ExitCode -eq 0) 'publish helper should create the source-outbox marker.'
Assert-True ((Test-Path -LiteralPath $publishReadyPath -PathType Leaf)) 'publish.ready.json should exist before watcher import.'

$watcherArgs = @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-RunDurationSec', '6',
    '-PollIntervalMs', '250',
    '-PairMaxRoundtripCount', '4',
    '-ImportSourceOutboxOnly'
)

$firstWatcherRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments $watcherArgs
Assert-True ($firstWatcherRun.ExitCode -eq 0) 'first watcher pass should exit cleanly after source-outbox import.'
Assert-True ($firstWatcherRun.Raw.Contains('source-outbox imported target04')) 'first watcher pass should import target04 source-outbox output.'
Assert-True (-not $firstWatcherRun.Raw.Contains('typed-window handoff prepare')) 'source-outbox-only watcher pass must not enter typed-window handoff.'
Assert-True (-not (Test-Path -LiteralPath $publishReadyPath -PathType Leaf)) 'root publish.ready.json should be archived after import.'

$archivedReadyFiles = @(Get-ChildItem -LiteralPath $archiveRoot -Filter '*.ready.json' -File -ErrorAction SilentlyContinue)
Assert-True ($archivedReadyFiles.Count -eq 1) 'archive should contain the imported ready marker exactly once.'

$sourceOutboxStatusPath = Join-Path $runRoot '.state\source-outbox-status.json'
$firstStatusDocument = Get-Content -LiteralPath $sourceOutboxStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$firstTargetStatus = @($firstStatusDocument.Targets | Where-Object { [string]$_.TargetId -eq 'target04' } | Select-Object -First 1)[0]
Assert-True ($null -ne $firstTargetStatus) 'source-outbox status should include target04 after import.'
Assert-True ([string]$firstTargetStatus.State -eq 'imported') 'first source-outbox status should remain imported after archiving.'
$firstUpdatedAt = [string]$firstTargetStatus.UpdatedAt
$firstArchivedReadyPath = [string]$firstTargetStatus.ArchivedReadyPath
Assert-True ((Test-Path -LiteralPath $firstArchivedReadyPath -PathType Leaf)) 'first status should point to the archived ready marker.'

$secondWatcherRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments $watcherArgs
Assert-True ($secondWatcherRun.ExitCode -eq 0) 'second watcher pass should exit cleanly with the archived marker still present.'
Assert-True (-not $secondWatcherRun.Raw.Contains('source-outbox duplicate skipped target04')) 'second watcher pass should not reprocess an already imported archived marker as a duplicate.'
Assert-True (-not $secondWatcherRun.Raw.Contains('typed-window handoff prepare')) 'second source-outbox-only watcher pass must not enter typed-window handoff.'

$secondStatusDocument = Get-Content -LiteralPath $sourceOutboxStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$secondTargetStatus = @($secondStatusDocument.Targets | Where-Object { [string]$_.TargetId -eq 'target04' } | Select-Object -First 1)[0]
Assert-True ($null -ne $secondTargetStatus) 'source-outbox status should still include target04 after the second pass.'
Assert-True ([string]$secondTargetStatus.State -eq 'imported') 'second pass should not downgrade target04 to duplicate-marker-archived.'
Assert-True ([string]$secondTargetStatus.UpdatedAt -eq $firstUpdatedAt) 'second pass should leave target04 source-outbox status timestamp unchanged.'
Assert-True ([string]$secondTargetStatus.ArchivedReadyPath -eq $firstArchivedReadyPath) 'second pass should keep the same archived ready marker path.'

Write-Host ('watch-paired-exchange archived duplicate marker skip ok: runRoot=' + $runRoot)
