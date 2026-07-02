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
$tmpRoot = Join-Path $root '_tmp\Test-PublishTargetAutoloopArtifact'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.publish-target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_publish_target_autoloop'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
New-Item -ItemType Directory -Path $routerInboxRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($routerInboxRoot.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$false
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready') }
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
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$inputPath = Join-Path $target01.InboxPendingRoot 'seed_001.txt'
Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'publish helper seed body'
$watchJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watch = $watchJson | ConvertFrom-Json
Assert-True ([int]$watch.QueuedCount -eq 1) 'seed input should queue one command before publish helper.'

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'publish helper summary'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'publish-note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'publish helper zip content'
if (Test-Path -LiteralPath $target01.SourceReviewZipPath) {
    Remove-Item -LiteralPath $target01.SourceReviewZipPath -Force
}
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $target01.SourceReviewZipPath -Force

$publishJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -AsJson
$publish = $publishJson | ConvertFrom-Json
Assert-True ((Test-Path -LiteralPath $publish.PublishReadyPath -PathType Leaf)) 'publish helper should create publish.ready.json.'
Assert-True ([string]$publish.Marker.RunMode -eq 'target-autoloop') 'publish helper should mark target-autoloop run mode.'
Assert-True ([int]$publish.Marker.CycleId -eq 1) 'publish helper should infer cycle id from current request.'
Assert-True ([int]$publish.Marker.ParentCycleId -eq 0) 'publish helper should infer parent cycle id from current request.'
Assert-True (([string]$publish.Marker.OutputFingerprint).Length -gt 0) 'publish helper should populate output fingerprint.'
Assert-True ([string]$publish.Marker.PublishedBy -eq 'publish-target-autoloop-artifact.ps1') 'publish helper should mark its publisher.'
Assert-True ((Test-Path -LiteralPath ([string]$publish.ArtifactHistoryRoot) -PathType Container)) 'publish helper should create artifact history root.'
Assert-True ((Test-Path -LiteralPath ([string]$publish.ArtifactHistoryEntryPath) -PathType Container)) 'publish helper should create artifact history entry.'
Assert-True ((Test-Path -LiteralPath ([string]$publish.ArchivedSummaryPath) -PathType Leaf)) 'publish helper should archive summary.txt.'
Assert-True ((Test-Path -LiteralPath ([string]$publish.ArchivedReviewZipPath) -PathType Leaf)) 'publish helper should archive review.zip.'
Assert-True ((Test-Path -LiteralPath ([string]$publish.ArchivedPublishReadyPath) -PathType Leaf)) 'publish helper should archive publish.ready.json.'
Assert-True ((Test-Path -LiteralPath ([string]$publish.ArtifactHistoryMetadataPath) -PathType Leaf)) 'publish helper should write artifact history metadata.'
Assert-True ([string]$publish.Marker.ArtifactHistoryEntryPath -eq [string]$publish.ArtifactHistoryEntryPath) 'publish marker should reference artifact history entry.'
Assert-True ([string]$publish.ArtifactHistory.ArchivedReviewZipPath -eq [string]$publish.ArchivedReviewZipPath) 'history metadata should reference archived review.zip.'

$events = @(
    Get-Content -LiteralPath $start.EventsPath -Encoding UTF8 |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { $_ | ConvertFrom-Json }
)
$publishEvent = @($events | Where-Object { [string]$_.EventType -eq 'publish-ready-created' } | Select-Object -First 1)[0]
Assert-True ($null -ne $publishEvent) 'publish helper should append a publish-ready-created event.'
Assert-True ([int]$publishEvent.CycleId -eq 1) 'publish helper event should include cycle id.'
$historyEvent = @($events | Where-Object { [string]$_.EventType -eq 'artifact-history-created' } | Select-Object -First 1)[0]
Assert-True ($null -ne $historyEvent) 'publish helper should append an artifact-history-created event.'
Assert-True ([string]$historyEvent.ArchivedReviewZipPath -eq [string]$publish.ArchivedReviewZipPath) 'history event should include archived review zip path.'

Write-Host 'publish target autoloop artifact ok'
