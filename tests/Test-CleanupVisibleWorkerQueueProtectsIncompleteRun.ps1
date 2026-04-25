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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth 10), (New-Utf8NoBomEncoding))
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-cleanup-visible-worker-protect-incomplete-run'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$runtimeRoot = Join-Path $testRoot 'runtime'
$queueRoot = Join-Path $runtimeRoot 'visible-worker\queue\target01'
$queuedRoot = Join-Path $queueRoot 'queued'
$statusRoot = Join-Path $runtimeRoot 'visible-worker\status'
$logRoot = Join-Path $runtimeRoot 'visible-worker\logs'
New-Item -ItemType Directory -Path $queuedRoot,$statusRoot,$logRoot -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($testRoot.Replace("'", "''"))\inbox\target01'
            EnterCount = 1
            WindowTitle = 'CleanupProtectWindow01'
            FixedSuffix = `$null
        }
    )
    PairTest = @{
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($(Join-Path $runtimeRoot 'visible-worker\queue').Replace("'", "''"))'
            StatusRoot = '$($statusRoot.Replace("'", "''"))'
            LogRoot = '$($logRoot.Replace("'", "''"))'
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$keepRunRoot = Join-Path $testRoot 'pair-test\run_keep'
$protectedRunRoot = Join-Path $testRoot 'pair-test\run_protected'
New-Item -ItemType Directory -Path $keepRunRoot,$protectedRunRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $protectedRunRoot '.state') -Force | Out-Null

$protectedCommandPath = Join-Path $queuedRoot 'command_target01_handoff_protected.json'
Write-JsonFile -Path $protectedCommandPath -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = 'protected-handoff'
    CreatedAt = (Get-Date).ToString('o')
    RunRoot = $protectedRunRoot
    TargetId = 'target01'
    PromptFilePath = (Join-Path $protectedRunRoot 'handoff.txt')
})

Write-JsonFile -Path (Join-Path $protectedRunRoot '.state\watcher-status.json') -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    State = 'running'
    Reason = ''
    ForwardedCount = 2
    ConfiguredMaxForwardCount = 4
    UpdatedAt = (Get-Date).ToString('o')
})

$applyRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Cleanup-VisibleWorkerQueue.ps1') `
    -ConfigPath $configPath `
    -TargetId target01 `
    -KeepRunRoot $keepRunRoot `
    -Apply `
    -AsJson
if ($LASTEXITCODE -ne 0) {
    throw ('cleanup apply failed: ' + (($applyRaw | Out-String).Trim()))
}

$applyResult = $applyRaw | ConvertFrom-Json
Assert-True ([int]$applyResult.Summary.ArchivedCount -eq 0) 'cleanup should not archive protected foreign command from incomplete run.'
Assert-True ([int]$applyResult.Summary.ProtectedRunCount -eq 1) 'cleanup should report one protected foreign command.'
Assert-True (Test-Path -LiteralPath $protectedCommandPath -PathType Leaf) 'cleanup should preserve the protected foreign command.'
Assert-True ([string]$applyResult.Targets[0].Items[0].Action -eq 'keep-protected-run') 'cleanup item should be classified as keep-protected-run.'

Write-Host 'cleanup-visible-worker-queue protects incomplete run ok'
