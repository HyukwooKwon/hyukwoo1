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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopDispatchRejectsRelayFolderMismatch'
$expectedInboxRoot = Join-Path $tmpRoot 'router-inbox'
$expectedTarget01Inbox = Join-Path $expectedInboxRoot 'target01'
$mismatchTarget01Inbox = Join-Path $tmpRoot 'different-router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-router-mismatch.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_router_mismatch'
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
    AhkExePath = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    AhkScriptPath = 'C:\dev\python\hyukwoo\hyukwoo1\sender\SendToWindow.ahk'
    ResolverShellPath = 'pwsh.exe'
    RuntimeMapPath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible\target-runtime.json'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($mismatchTarget01Inbox.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-mismatch' }
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
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetManifest = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$promptPath = Join-Path $tmpRoot 'prompt_target01.txt'
Set-Content -LiteralPath $promptPath -Encoding UTF8 -Value 'dispatch mismatch body'

$commandPath = Join-Path ([string]$targetManifest.QueueQueuedRoot) 'command_target01_dispatch_mismatch.json'
[ordered]@{
    SchemaVersion = '1.0.0'
    RunMode = 'target-inbox-submit'
    RunRoot = $runRoot
    TargetId = 'target01'
    CommandId = 'target01-dispatch-mismatch'
    TriggerKind = 'input-file'
    TriggerFingerprint = 'mismatch-test'
    LoopSource = 'external-inbox'
    PromptPath = $promptPath
    PromptFilePath = $promptPath
    FixedSuffixPolicy = 'target'
    CycleId = 1
    ParentCycleId = 0
    CreatedAt = (Get-Date).ToString('o')
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $commandPath -Encoding UTF8

$errorMessage = ''
try {
    & (Join-Path $root 'tests\Dispatch-TargetAutoloopCommand.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -TargetId target01 `
        -CommandPath $commandPath `
        -AsJson | Out-Null
    throw 'Dispatch-TargetAutoloopCommand should fail when the configured relay folder mismatches InboxRoot.'
}
catch {
    $errorMessage = [string]$_.Exception.Message
}

Assert-True ($errorMessage -match 'target relay folder mismatch:') 'target-autoloop dispatch should fail in preflight.'
Assert-True ($errorMessage -match 'target=target01') 'target-autoloop dispatch mismatch should identify the target.'
Assert-True ($errorMessage.Contains(('configFolder=' + $mismatchTarget01Inbox))) 'target-autoloop dispatch mismatch should include the configured folder.'
Assert-True ($errorMessage.Contains(('expectedFolder=' + $expectedTarget01Inbox))) 'target-autoloop dispatch mismatch should include the expected inbox-root folder.'
Assert-True (-not ($errorMessage -match 'Target folder not found:')) 'target-autoloop dispatch mismatch should fail before producer invocation.'

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetState = $state.Targets.target01
Assert-True ([string]$targetState.Phase -eq 'failed') 'target-autoloop state should move to failed after relay folder mismatch.'
Assert-True ([string]$targetState.LastDispatchState -eq 'relay-folder-preflight-failed') 'target-autoloop state should record relay-folder preflight failure state.'
Assert-True ([string]$targetState.RelayTargetFolderState -eq 'relay-folder-mismatch') 'target-autoloop state should persist the relay folder mismatch state.'
Assert-True ([string]$targetState.LastFailureReason -match 'target relay folder mismatch:') 'target-autoloop state should persist the mismatch reason.'

$failedCommands = @(Get-ChildItem -LiteralPath ([string]$targetManifest.QueueFailedRoot) -File -Filter '*.json' -ErrorAction SilentlyContinue)
Assert-True (@($failedCommands).Count -eq 1) 'failed queue archive should contain the mismatched dispatch command.'

Write-Host 'target autoloop dispatch relay-folder-mismatch ok'
