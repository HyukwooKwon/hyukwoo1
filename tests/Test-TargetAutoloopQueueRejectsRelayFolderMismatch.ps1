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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopQueueRejectsRelayFolderMismatch'
$expectedInboxRoot = Join-Path $tmpRoot 'router-inbox'
$expectedTarget01Inbox = Join-Path $expectedInboxRoot 'target01'
$mismatchTarget01Inbox = Join-Path $tmpRoot 'different-router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-queue-mismatch.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_queue_mismatch'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
foreach ($path in @($expectedTarget01Inbox, $mismatchTarget01Inbox)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    InboxRoot = '$($expectedInboxRoot.Replace("'", "''"))'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($mismatchTarget01Inbox.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-queue-mismatch' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-inbox-submit'
        DispatchQueuedCommandsInline = `$false
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -AsJson
$start = $startJson | ConvertFrom-Json

$promptPath = Join-Path $tmpRoot 'prompt_target01.txt'
Set-Content -LiteralPath $promptPath -Encoding UTF8 -Value 'queue mismatch body'

$errorMessage = ''
try {
    & (Join-Path $root 'visible\Queue-TargetAutoloopCommand.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -TargetId target01 `
        -PromptFilePath $promptPath `
        -RunMode target-inbox-submit `
        -TriggerKind input-file `
        -LoopSource external-inbox `
        -TriggerFingerprint 'queue-mismatch-test' `
        -CycleId 1 `
        -AsJson | Out-Null
    throw 'Queue-TargetAutoloopCommand should fail when the configured relay folder mismatches InboxRoot.'
}
catch {
    $errorMessage = [string]$_.Exception.Message
}

Assert-True ($errorMessage -match 'target relay folder mismatch:') 'target-autoloop queue should fail in preflight.'
Assert-True ($errorMessage -match 'target=target01') 'target-autoloop queue mismatch should identify the target.'
Assert-True ($errorMessage.Contains(('configFolder=' + $mismatchTarget01Inbox))) 'target-autoloop queue mismatch should include the configured folder.'
Assert-True ($errorMessage.Contains(('expectedFolder=' + $expectedTarget01Inbox))) 'target-autoloop queue mismatch should include the expected inbox-root folder.'

$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetManifest = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$queuedCommands = @(Get-ChildItem -LiteralPath ([string]$targetManifest.QueueQueuedRoot) -File -Filter '*.json' -ErrorAction SilentlyContinue)
Assert-True (@($queuedCommands).Count -eq 0) 'queue preflight failure should not create a queued command file.'

Write-Host 'target autoloop queue relay-folder-mismatch ok'
