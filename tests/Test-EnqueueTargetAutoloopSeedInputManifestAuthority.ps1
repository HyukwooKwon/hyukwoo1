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

function Write-TestConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunRootBase,
        [Parameter(Mandatory)][string]$RouterInboxRoot,
        [string]$WorkRepoRoot = ''
    )

    $workRepoLine = ''
    if ($WorkRepoRoot.Trim()) {
        $workRepoLine = "WorkRepoRoot = '$($WorkRepoRoot.Replace("'", "''"))'; "
    }

    [System.IO.File]::WriteAllText($Path, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target04'; Folder = '$($RouterInboxRoot.Replace("'", "''"))'; WindowTitle = 'Target04'; FixedSuffix = 'suffix-04' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        RunRootBase = '$($RunRootBase.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target04'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); $workRepoLine MaxCycleCount = 2 }
        )
    }
}
"@, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-PathStartsWith {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BasePath
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\')
    return $fullPath.StartsWith($fullBase + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-EnqueueTargetAutoloopSeedInputManifestAuthority'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target04'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop-seed-queue-authority.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_seed_queue_authority'
$driftWorkRepoRoot = 'C:\dev\python\relay-target-autoloop-seed-queue-drift'

foreach ($path in @($tmpRoot, $driftWorkRepoRoot)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
New-Item -ItemType Directory -Path $routerInboxRoot -Force | Out-Null

Write-TestConfig -Path $configPath -RunRootBase $tmpRoot -RouterInboxRoot $routerInboxRoot

$start = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target04 `
    -AsJson | ConvertFrom-Json

$manifest = Get-Content -LiteralPath ([string]$start.ManifestPath) -Raw -Encoding UTF8 | ConvertFrom-Json
$target04 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target04' } | Select-Object -First 1)[0]
Assert-True ($null -ne $target04) 'manifest should include target04.'

Write-TestConfig -Path $configPath -RunRootBase $tmpRoot -RouterInboxRoot $routerInboxRoot -WorkRepoRoot $driftWorkRepoRoot

$queueJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Enqueue-TargetAutoloopSeedInput.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target04 `
    -Text "manifest authority queue prompt`nsummary path: $([string]$target04.SourceSummaryPath)" `
    -AsJson | ConvertFrom-Json

Assert-True ([string]$queueJson.PathSource -eq 'manifest') 'enqueue result should report manifest path source.'
Assert-True ([string]$queueJson.ManifestPath -eq [string]$start.ManifestPath) 'enqueue result should keep the selected RunRoot manifest path.'
Assert-True (Test-Path -LiteralPath ([string]$queueJson.InputTriggerPath) -PathType Leaf) 'enqueue script should create an input trigger file.'
Assert-True (Test-PathStartsWith -Path ([string]$queueJson.InputTriggerPath) -BasePath ([string]$target04.InboxPendingRoot)) 'enqueue should write under manifest InboxPendingRoot after config drift.'
Assert-True (-not (Test-PathStartsWith -Path ([string]$queueJson.InputTriggerPath) -BasePath $driftWorkRepoRoot)) 'enqueue should not write under drift WorkRepoRoot.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $driftWorkRepoRoot '.relay-runs') -PathType Container)) 'enqueue should not create drift WorkRepoRoot relay run directories.'

$pendingFiles = @(Get-ChildItem -LiteralPath ([string]$target04.InboxPendingRoot) -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($pendingFiles).Count -eq 1) 'manifest pending inbox should contain exactly one queued input trigger.'

Write-Host 'enqueue target autoloop seed input manifest authority ok'
