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
$tmpRoot = Join-Path $root '_tmp\Test-StartTargetAutoloopRun'
$targetWorkRepoRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'relay-target-autoloop-start-workrepo'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
if (Test-Path -LiteralPath $targetWorkRepoRoot) {
    Remove-Item -LiteralPath $targetWorkRepoRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
New-Item -ItemType Directory -Path $targetWorkRepoRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
        @{ Id = 'target02'; Folder = 'C:\tmp\target02'; WindowTitle = 'Target02'; FixedSuffix = `$null }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-inbox-submit'
        DispatchQueuedCommandsInline = `$false
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file'); WorkRepoRoot = '$($targetWorkRepoRoot.Replace("'", "''"))' }
            @{ TargetId = 'target02'; Enabled = `$false; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -AsJson
$start = $startJson | ConvertFrom-Json

Assert-True ((Test-Path -LiteralPath $start.RunRoot -PathType Container)) 'run root should be created.'
Assert-True ((Test-Path -LiteralPath $start.ManifestPath -PathType Leaf)) 'manifest.json should be created.'
Assert-True ((Test-Path -LiteralPath $start.StatePath -PathType Leaf)) 'target-state.json should be created.'
Assert-True ((Test-Path -LiteralPath $start.StatusPath -PathType Leaf)) 'target-autoloop-status.json should be created.'
Assert-True ((Test-Path -LiteralPath $start.ControlPath -PathType Leaf)) 'target-autoloop-control.json should be created.'

$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ($null -ne $target01) 'manifest should include target01.'
Assert-True ([string]$target01.WorkRepoRoot -eq [System.IO.Path]::GetFullPath($targetWorkRepoRoot)) 'manifest should preserve target01 WorkRepoRoot.'
Assert-True ([string]$target01.TargetRunRoot -match [regex]::Escape('\.relay-runs\bottest-live-visible\target-autoloop\run_target_autoloop')) 'manifest should place target01 target runroot under its WorkRepoRoot.'
Assert-True ((Test-Path -LiteralPath $target01.InboxPendingRoot -PathType Container)) 'target01 inbox/pending should be created.'
Assert-True ((Test-Path -LiteralPath $target01.WorkRoot -PathType Container)) 'target01 work root should be created.'
Assert-True ((Test-Path -LiteralPath $target01.SourceOutboxPath -PathType Container)) 'target01 source-outbox should be created.'
Assert-True ((Test-Path -LiteralPath $target01.QueueQueuedRoot -PathType Container)) 'target01 queued root should be created.'

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetState = $state.Targets.target01
Assert-True ([string]$targetState.Phase -eq 'idle') 'target01 initial phase should be idle.'
Assert-True ([string]$targetState.NextAction -eq 'wait-for-input') 'target01 next action should be wait-for-input.'
Assert-True ([int]$targetState.CycleCount -eq 0) 'target01 cycle count should start at zero.'
Assert-True (-not [bool]$start.QueueDispatchIntegrated) 'dispatch should remain disabled in the isolated groundwork.'

Write-Host 'start target autoloop run ok'
