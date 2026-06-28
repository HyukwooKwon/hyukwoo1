[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopStatusRunRootMismatch'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_pair_manifest_mismatch'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('publish-ready'); MaxCycleCount = 2 }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json

$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest.RunMode = 'paired-exchange'
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.ManifestPath -Encoding UTF8

$status = Get-Content -LiteralPath $start.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$status.WatcherState = 'stopped'
$status.ControllerState = 'running'
$status.WatcherStopReason = 'test-stopped'
$status.LastUpdatedAt = (Get-Date).ToString('o')
$status | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatusPath -Encoding UTF8

$statusJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True ([string]$statusJson.ManifestRunMode -eq 'paired-exchange') 'status json should surface non target-autoloop manifest run mode.'
Assert-True ([string]$statusJson.RecommendationActionKey -eq 'prepare_autoloop_runroot') 'status json should recommend preparing a new target-autoloop RunRoot.'
Assert-True ([string]$statusJson.RecommendationLabel -eq '새 RunRoot 준비') 'status json should surface new RunRoot action label.'
Assert-True ([string]$statusJson.NextOperatorAction -eq '새 RunRoot 준비 (prepare_autoloop_runroot)') 'status json should surface next operator action for RunRoot mismatch.'
Assert-True ([string]$statusJson.RecommendationDetail -match 'target-autoloop용 run이 아닙니다') 'status json should explain manifest run mode mismatch.'

$output = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$joined = (@($output) -join "`n")

Assert-True ($joined -match 'Manifest: exists=True runMode=paired-exchange') 'status text should surface manifest run mode mismatch.'
Assert-True ($joined -match 'NextOperatorAction: 새 RunRoot 준비 \(prepare_autoloop_runroot\)') 'status text should surface next operator action for RunRoot mismatch.'

Write-Host 'show target autoloop status runroot mismatch ok'
