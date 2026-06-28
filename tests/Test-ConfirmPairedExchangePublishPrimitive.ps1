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
        Raw = ($result | Out-String).Trim()
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$originalConfig = Import-PowerShellDataFile -Path $resolvedConfigPath
$originalWorkRepoRoot = [string]$originalConfig.PairTest.DefaultSeedWorkRepoRoot
$testWorkRepoRoot = Join-Path $originalWorkRepoRoot '__codex-tests\publish-primitive'
$runtimeBaseRoot = Join-Path $testWorkRepoRoot 'runtime'
$runtimeRoot = Join-Path $testWorkRepoRoot 'runtime'
$logsRoot = Join-Path $testWorkRepoRoot 'logs'
$inboxRoot = Join-Path $testWorkRepoRoot 'inbox'
$retryPendingRoot = Join-Path $testWorkRepoRoot 'retry-pending'
$failedRoot = Join-Path $testWorkRepoRoot 'failed'
$processedRoot = Join-Path $testWorkRepoRoot 'processed'
$ignoredRoot = Join-Path $testWorkRepoRoot 'ignored'
$bindingProfilePath = Join-Path $runtimeRoot 'window-bindings\bottest-live-visible.json'
$configCopyPath = Join-Path $testWorkRepoRoot 'settings.publish-primitive.psd1'
New-Item -ItemType Directory -Path $testWorkRepoRoot -Force | Out-Null
$configText = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$configText = $configText.Replace($originalWorkRepoRoot, $testWorkRepoRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\runtime\', ($runtimeBaseRoot + '\'))
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible', $runtimeRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\logs\bottest-live-visible', $logsRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible', $inboxRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\retry-pending\bottest-live-visible', $retryPendingRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\failed\bottest-live-visible', $failedRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\processed\bottest-live-visible', $processedRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\ignored\bottest-live-visible', $ignoredRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\runtime\window-bindings\bottest-live-visible.json', $bindingProfilePath)
[System.IO.File]::WriteAllText($configCopyPath, $configText, (New-Utf8NoBomEncoding))
$resolvedConfigPath = $configCopyPath
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$seedWorkRepoRoot = [string]$config.PairTest.DefaultSeedWorkRepoRoot
$seedReviewInputPath = [string]$config.PairTest.DefaultSeedReviewInputPath
$runRoot = Join-Path $pairRunRootBase ('run_publish_primitive_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
if (-not [string]::IsNullOrWhiteSpace($seedReviewInputPath)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $seedReviewInputPath) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $seedReviewInputPath)) {
        [System.IO.File]::WriteAllText($seedReviewInputPath, 'publish primitive review input', (New-Utf8NoBomEncoding))
    }
}

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 `
    -SeedWorkRepoRoot $seedWorkRepoRoot `
    -SeedReviewInputPath $seedReviewInputPath `
    -SeedTaskText 'publish primitive test' | Out-Null

$manifest = Get-Content -LiteralPath (Join-Path $runRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$target01Manifest = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$target01Outbox = [string]$target01Manifest.SourceOutboxPath
$target01SummaryPath = [string]$target01Manifest.SourceSummaryPath
$target01ReviewZipPath = [string]$target01Manifest.SourceReviewZipPath
$target01PublishReadyPath = [string]$target01Manifest.PublishReadyPath
$stateRoot = Join-Path $runRoot '.state'
$seedSendStatusPath = Join-Path $stateRoot 'seed-send-status.json'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
New-Item -ItemType Directory -Path $target01Outbox -Force | Out-Null

$seedProcessedAt = (Get-Date).AddMinutes(-10).ToString('o')
$seedSendPayload = [ordered]@{
    SchemaVersion = '1.0.0'
    RunRoot = $runRoot
    UpdatedAt = (Get-Date).ToString('o')
    Targets = @(
        [ordered]@{
            TargetId = 'target01'
            UpdatedAt = (Get-Date).ToString('o')
            FinalState = 'processed'
            ExecutionPathMode = 'typed-window'
            UserVisibleCellExecutionRequired = $true
            AllowedWindowVisibilityMethods = @('hwnd')
            SubmitRetryModes = @('enter', 'ctrl_enter')
            SubmitRetrySequenceSummary = 'enter -> ctrl_enter'
            PrimarySubmitMode = 'enter'
            FinalSubmitMode = 'ctrl_enter'
            SubmitRetryIntervalMs = 1000
            AttemptCount = 1
            MaxAttempts = 3
            ProcessedPath = (Join-Path $stateRoot 'dummy-processed.txt')
            ProcessedAt = $seedProcessedAt
            FailedPath = ''
            FailedAt = ''
            RetryPendingPath = ''
            RetryPendingAt = ''
            OutboxPublished = $false
            OutboxObservedAt = ''
            LastReadyPath = ''
            LastReadyBaseName = ''
            TypedWindowSessionScopeKind = 'pair'
            TypedWindowSessionScopeId = 'pair01'
            TypedWindowSessionRouteKey = 'pair:pair01:target01'
        }
    )
}
$seedSendPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $seedSendStatusPath -Encoding UTF8

$watcherFirstRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-RunDurationSec', '2'
)
Assert-True ($watcherFirstRun.ExitCode -eq 0) 'watcher should exit cleanly for first publish primitive pass.'

[System.IO.File]::WriteAllText($target01SummaryPath, 'publish primitive started', (New-Utf8NoBomEncoding))
$payloadNotePath = Join-Path $target01Outbox 'publish-primitive-note.txt'
[System.IO.File]::WriteAllText($payloadNotePath, 'publish primitive payload', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $payloadNotePath -DestinationPath $target01ReviewZipPath -Force
Remove-Item -LiteralPath $payloadNotePath -Force
$publishHelper = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Publish-PairedExchangeArtifact.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-TargetId', 'target01',
    '-AsJson'
)
Assert-True ($publishHelper.ExitCode -eq 0) 'publish helper should exit cleanly for publish primitive test.'
$publishHelperJson = $publishHelper.Raw | ConvertFrom-Json
Assert-True ([bool]$publishHelperJson.PublishReadyCreated) 'publish helper should create a strict publish.ready marker.'
Assert-True ([string]$publishHelperJson.Target.PairId -eq 'pair01') 'publish helper should preserve pair01 target mapping.'
Assert-True ([string]$publishHelperJson.Target.TargetId -eq 'target01') 'publish helper should preserve selected target when writing publish marker.'
Assert-True ([string]$publishHelperJson.Contract.PublishReadyPath -eq $target01PublishReadyPath) 'publish helper should write marker to the manifest contract path.'

$watcherSecondRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-RunDurationSec', '2',
    '-ImportSourceOutboxOnly'
)
Assert-True ($watcherSecondRun.ExitCode -eq 0) 'watcher should exit cleanly for second publish primitive pass.'

$resultRaw = & (Join-Path $root 'tests\Confirm-PairedExchangePublishPrimitive.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -AsJson
$result = $resultRaw | ConvertFrom-Json

Assert-True ([string]$result.PrimitiveName -eq 'publish-confirm') 'wrapper should mark publish-confirm primitive name.'
Assert-True ([string]$result.PairId -eq 'pair01') 'wrapper should resolve pair01 from target01.'
Assert-True ([string]$result.TargetId -eq 'target01') 'wrapper should preserve selected target.'
Assert-True ([string]$result.PartnerTargetId -eq 'target05') 'wrapper should resolve partner target.'
Assert-True ([bool]$result.PrimitiveSuccess) 'wrapper should mark publish observation success when source-outbox changes.'
Assert-True ([bool]$result.PrimitiveAccepted) 'strict helper path should reach accepted publish state after watcher import.'
Assert-True ([string]$result.PrimitiveState -eq 'accepted') 'wrapper should classify helper-driven strict publish as accepted.'
Assert-True ([string]$result.NextPrimitiveAction -eq 'handoff-confirm') 'accepted strict publish should recommend handoff confirm.'
Assert-True ([string]$result.Evidence.SourceOutboxState -eq 'imported') 'wrapper should surface imported source-outbox state in evidence.'
Assert-True ([string]$result.Evidence.Target.SourceOutboxState -eq 'imported') 'wrapper should attach imported target evidence row.'
Assert-True ([string]$result.SourceOutboxState -eq 'imported') 'wrapper should surface imported source-outbox state.'
Assert-True ([string]$result.PairedTargetStatus.SourceOutboxState -eq 'imported') 'wrapper should attach imported paired target row.'
Assert-True ([string]$result.PairedTargetStatus.SourceOutboxNextAction -eq 'handoff-ready') 'wrapper should expose handoff-ready next action after import.'
Assert-True ([string]$result.PairedTargetStatus.TypedWindowSessionScopeKind -eq 'pair') 'wrapper should carry typed-window scope kind into paired target status.'
Assert-True ([string]$result.PairedTargetStatus.TypedWindowSessionScopeId -eq 'pair01') 'wrapper should carry typed-window scope id into paired target status.'
Assert-True ([string]$result.PairedTargetStatus.TypedWindowSessionRouteKey -eq 'pair:pair01:target01') 'wrapper should carry typed-window route key into paired target status.'
Assert-True ([string]$result.PairedStatusSnapshot.PairTest.ExecutionPathMode -eq 'typed-window') 'wrapper should attach paired status snapshot.'
Assert-True ([int]$result.PairedStatusSnapshot.Counts.FailureLineCount -eq 0) 'publish primitive import-only watcher pass should not leave handoff failure lines.'

Write-Host ('confirm paired exchange publish primitive ok: runRoot=' + $runRoot)
