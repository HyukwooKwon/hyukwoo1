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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopPublishReadyTrigger'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop'
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

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'summary ready for next cycle'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'zip payload'
if (Test-Path -LiteralPath $target01.SourceReviewZipPath) {
    Remove-Item -LiteralPath $target01.SourceReviewZipPath -Force
}
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $target01.SourceReviewZipPath -Force
$publishJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -CycleId 1 `
    -ParentCycleId 0 `
    -OutputFingerprint output-fingerprint-001 `
    -AsJson
$publish = $publishJson | ConvertFrom-Json
Assert-True ([string]$publish.Marker.OutputFingerprint -eq 'output-fingerprint-001') 'publish helper should keep the provided output fingerprint.'

$watchJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watch = $watchJson | ConvertFrom-Json
Assert-True ([int]$watch.QueuedCount -eq 1) 'publish-ready trigger should queue exactly one command.'

$queueFiles = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($queueFiles).Count -eq 1) 'one queued command should be present after publish-ready trigger.'
$command = Get-Content -LiteralPath $queueFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$command.RunMode -eq 'target-autoloop') 'queued command should preserve target-autoloop run mode.'
Assert-True ([string]$command.TriggerKind -eq 'publish-ready') 'queued command should record publish-ready trigger kind.'
Assert-True ([string]$command.LoopSource -eq 'self-output') 'queued command should record self-output loop source.'

$promptText = Get-Content -LiteralPath ([string]$command.PromptFilePath) -Raw -Encoding UTF8
$expectedPublishHelperCommand = (
    "pwsh -NoProfile -ExecutionPolicy Bypass -File '{0}' -ConfigPath '{1}' -RunRoot '{2}' -TargetId 'target01' -Overwrite" -f
    ((Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') -replace "'", "''"),
    ($configPath -replace "'", "''"),
    ($runRoot -replace "'", "''")
)
Assert-True ($promptText.Contains('[고정문구 / 항상 포함]')) 'publish-ready prompt should keep the fixed suffix header.'
Assert-True ($promptText.Contains('suffix-01')) 'publish-ready prompt should keep the target fixed suffix.'
Assert-True ($promptText.Contains('[생성해야 할 파일]')) 'publish-ready prompt should include the output contract block.'
Assert-True ($promptText.Contains(('1. summary.txt -> ' + [string]$target01.SourceSummaryPath))) 'publish-ready prompt should include the exact summary path.'
Assert-True ($promptText.Contains(('2. review.zip -> ' + [string]$target01.SourceReviewZipPath))) 'publish-ready prompt should include the exact review zip path.'
Assert-True ($promptText.Contains('[마지막 단계]')) 'publish-ready prompt should include the final-step block.'
Assert-True ($promptText.Contains(('3. publish helper 실행 -> ' + $expectedPublishHelperCommand))) 'publish-ready prompt should include the publish helper command with the coordinator runroot.'
Assert-True ($promptText.Contains(('4. helper output marker -> ' + [string]$target01.PublishReadyPath))) 'publish-ready prompt should include the publish ready marker path.'
Assert-True ($promptText.Contains('[규칙]')) 'publish-ready prompt should include the target output rules.'
Assert-True ($promptText.Contains('[현재 턴 메타]')) 'publish-ready prompt should keep publish metadata in a separate block.'
Assert-True ($promptText.Contains('LoopSource') -eq $false) 'publish-ready prompt should not expose queue-only loop source as task text.'

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetState = $state.Targets.target01
Assert-True ([string]$targetState.Phase -eq 'queued') 'target state should move to queued after publish-ready trigger.'
Assert-True ([string]$targetState.LastTriggerKind -eq 'publish-ready') 'target state should record publish-ready trigger kind.'
Assert-True ([string]$targetState.LastHandledPublishMarkerId -eq 'output-fingerprint-001') 'target state should keep publish marker id.'
Assert-True ([int]$targetState.LastHandledPublishCycleId -eq 1) 'target state should keep the publish cycle id.'
Assert-True ([int]$targetState.LastHandledPublishParentCycleId -eq 0) 'target state should keep the publish parent cycle id.'
Assert-True ([string]$targetState.LastHandledOutputFingerprint -eq 'output-fingerprint-001') 'target state should keep the handled output fingerprint.'
Assert-True (([string]$targetState.LastOutputReadyAt).Length -gt 0) 'target state should record last output ready time.'

Write-Host 'target autoloop publish-ready trigger ok'
