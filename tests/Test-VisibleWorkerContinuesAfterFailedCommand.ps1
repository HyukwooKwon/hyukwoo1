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

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "json file is empty: $Path"
    }

    return ($raw | ConvertFrom-Json)
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-visible-worker-continues-after-failed-command'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

$queueRoot = Join-Path $testRoot 'queue'
$statusRoot = Join-Path $testRoot 'status'
$logRoot = Join-Path $testRoot 'logs'
$queuedRoot = Join-Path $queueRoot 'target05\queued'
$processingRoot = Join-Path $queueRoot 'target05\processing'
$completedRoot = Join-Path $queueRoot 'target05\completed'
$failedRoot = Join-Path $queueRoot 'target05\failed'
foreach ($path in @($queuedRoot, $processingRoot, $completedRoot, $failedRoot, (Join-Path $statusRoot 'workers'), $logRoot)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

$configPath = Join-Path $testRoot 'settings.psd1'
$configContent = @"
@{
    PairTest = @{
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($queueRoot -replace '\\','\\')'
            StatusRoot = '$($statusRoot -replace '\\','\\')'
            LogRoot = '$($logRoot -replace '\\','\\')'
            PollIntervalMs = 100
            IdleExitSeconds = 1
            CommandTimeoutSeconds = 60
        }
        HeadlessExec = @{
            MaxRunSeconds = 60
        }
    }
}
"@
Set-Content -LiteralPath $configPath -Encoding UTF8 -Value $configContent

$commandOneId = [guid]::NewGuid().ToString('N')
$commandTwoId = [guid]::NewGuid().ToString('N')
$createdAt = (Get-Date).ToString('o')
$commandOne = [ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = $commandOneId
    CreatedAt = $createdAt
    RunRoot = (Join-Path $testRoot 'missing-run-one')
    PairId = 'pair01'
    TargetId = 'target05'
    PartnerTargetId = 'target01'
    RoleName = 'bottom'
    Mode = 'handoff'
    PromptFilePath = (Join-Path $testRoot 'missing-prompt-one.txt')
    MessagePath = (Join-Path $testRoot 'missing-prompt-one.txt')
}
$commandTwo = [ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = $commandTwoId
    CreatedAt = $createdAt
    RunRoot = (Join-Path $testRoot 'missing-run-two')
    PairId = 'pair01'
    TargetId = 'target05'
    PartnerTargetId = 'target01'
    RoleName = 'bottom'
    Mode = 'handoff'
    PromptFilePath = (Join-Path $testRoot 'missing-prompt-two.txt')
    MessagePath = (Join-Path $testRoot 'missing-prompt-two.txt')
}
$commandOne | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $queuedRoot 'command_target05_handoff_01.json') -Encoding UTF8
$commandTwo | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $queuedRoot 'command_target05_handoff_02.json') -Encoding UTF8

$workerScriptPath = Join-Path $root 'visible\Start-VisibleTargetWorker.ps1'
$worker = Start-Process -FilePath 'pwsh' -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $workerScriptPath,
    '-ConfigPath', $configPath,
    '-TargetId', 'target05',
    '-IdleExitSeconds', '1'
) -PassThru

$deadline = (Get-Date).AddSeconds(15)
while (-not $worker.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
}

if (-not $worker.HasExited) {
    Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue
    throw 'visible worker should have exited after idle timeout.'
}

$failedFiles = @(Get-ChildItem -LiteralPath $failedRoot -Filter '*.json' -File | Sort-Object Name)
$queuedFiles = @(Get-ChildItem -LiteralPath $queuedRoot -Filter '*.json' -File)
$processingFiles = @(Get-ChildItem -LiteralPath $processingRoot -Filter '*.json' -File)
$statusPath = Join-Path $statusRoot 'workers\worker_target05.json'
$statusDoc = Read-JsonObject -Path $statusPath

Assert-True ($failedFiles.Count -eq 2) 'visible worker should continue after first failed command and archive both failed commands.'
Assert-True ($queuedFiles.Count -eq 0) 'queued commands should be drained after worker finishes.'
Assert-True ($processingFiles.Count -eq 0) 'processing folder should be empty after worker finishes.'
Assert-True ([string]$statusDoc.State -eq 'stopped') 'worker status should be stopped after idle exit.'
Assert-True ([string]$statusDoc.LastCommandId -eq $commandTwoId) 'worker should record the last failed command after continuing.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$statusDoc.LastFailedAt)) 'worker should record LastFailedAt after failed commands.'

Write-Host 'visible worker continues after failed command ok'
