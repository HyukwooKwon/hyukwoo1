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

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
    }
    catch {
        if ([string]$_.Exception.Message -match $Pattern) {
            return
        }

        throw ($Message + ' actual=' + [string]$_.Exception.Message)
    }

    throw ($Message + ' actual=<no exception>')
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\TargetAutoloopConfig.ps1')

$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopConfig'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$smokeReceiptPath = Join-Path $tmpRoot 'smoke-receipt.json'
$smokeReceipt = Write-TargetAutoloopSmokeReceipt `
    -Path $smokeReceiptPath `
    -Scenario 'one-target-live-smoke' `
    -Result 'passed' `
    -Source 'script-smoke' `
    -ProofLevel 'script-level' `
    -RunRoot 'C:\repo\.relay-runs\run_001' `
    -TargetId 'target01' `
    -CycleCount 2 `
    -MaxCycleCount 2 `
    -FinalPhase 'limit-reached' `
    -WatcherStopReason 'all-targets-limit-reached' `
    -CompletedAt '2026-05-12T20:45:00+09:00'
Assert-True ([string]$smokeReceipt.ReceiptKind -eq 'target-autoloop-smoke') 'smoke receipt helper should stamp the canonical receipt kind.'
$persistedSmokeReceipt = Read-JsonObject -Path $smokeReceiptPath
Assert-True ([string]$persistedSmokeReceipt.SchemaVersion -eq $script:TargetAutoloopSchemaVersion) 'smoke receipt helper should stamp the target-autoloop schema version.'
Assert-True ([string]$persistedSmokeReceipt.Result -eq 'passed') 'smoke receipt helper should persist the canonical result field.'
Assert-True ([string]$persistedSmokeReceipt.ProofLevel -eq 'script-level') 'smoke receipt helper should persist the canonical proof level field.'

$legacySmokeReceiptPath = Join-Path $tmpRoot 'legacy-smoke-receipt.json'
Write-JsonFileAtomically -Path $legacySmokeReceiptPath -Payload ([ordered]@{
    SchemaVersion = '0.9.0'
    ReceiptKind = 'legacy-target-autoloop-smoke'
    Scenario = 'legacy-smoke'
    State = 'passed'
    Source = 'script-smoke'
    Proof = 'script-level'
    SeedTargetId = 'target07'
    CycleCount = 1
    MaxCycleCount = 3
    Stage = 'waiting-output'
    StopReason = 'manual-stop'
    GeneratedAt = '2026-05-12T20:50:00+09:00'
})
$legacySmokeSummary = Get-TargetAutoloopSmokeReceiptSummary -Path $legacySmokeReceiptPath
Assert-True ([string]$legacySmokeSummary.Result -eq 'passed') 'legacy smoke receipt should normalize State into Result.'
Assert-True ([string]$legacySmokeSummary.ProofLevel -eq 'script-level') 'legacy smoke receipt should normalize Proof into ProofLevel.'
Assert-True ([string]$legacySmokeSummary.TargetId -eq 'target07') 'legacy smoke receipt should normalize SeedTargetId into TargetId.'
Assert-True ([string]$legacySmokeSummary.FinalPhase -eq 'waiting-output') 'legacy smoke receipt should normalize Stage into FinalPhase.'
Assert-True ([string]$legacySmokeSummary.WatcherStopReason -eq 'manual-stop') 'legacy smoke receipt should normalize StopReason into WatcherStopReason.'
Assert-True ([string]$legacySmokeSummary.CompletedAt -eq '2026-05-12T20:50:00+09:00') 'legacy smoke receipt should normalize GeneratedAt into CompletedAt.'
$scriptSmokeCloseout = Get-TargetAutoloopProofCloseoutSummary -ProofReceipt $legacySmokeSummary
Assert-True ([string]$scriptSmokeCloseout.State -eq 'pending-visible-proof') 'script-level smoke proof should stay pending visible proof.'
Assert-True ([string]$scriptSmokeCloseout.Mode -eq 'operational') 'script-level smoke proof should remain operational but not final.'
$visibleProofCloseout = Get-TargetAutoloopProofCloseoutSummary -ProofReceipt ([pscustomobject]@{
    Result = 'passed'
    ProofLevel = 'visible-live'
    Source = 'shared-visible-acceptance'
})
Assert-True ([string]$visibleProofCloseout.State -eq 'final-pass') 'visible-live proof should promote closeout to final-pass.'
Assert-True ([string]$visibleProofCloseout.Mode -eq 'final') 'visible-live proof should mark the closeout mode as final.'

$invalidPublishReadyConfigPath = Join-Path $tmpRoot 'invalid-publish-ready.psd1'
[System.IO.File]::WriteAllText($invalidPublishReadyConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = `$null }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-inbox-submit'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

Assert-ThrowsLike `
    -Action { Resolve-TargetAutoloopConfig -Root $root -ConfigPath $invalidPublishReadyConfigPath | Out-Null } `
    -Pattern 'cannot include publish-ready' `
    -Message 'target-inbox-submit should reject publish-ready trigger kinds.'

$duplicateTargetConfigPath = Join-Path $tmpRoot 'duplicate-target.psd1'
[System.IO.File]::WriteAllText($duplicateTargetConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = `$null }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready') }
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

Assert-ThrowsLike `
    -Action { Resolve-TargetAutoloopConfig -Root $root -ConfigPath $duplicateTargetConfigPath | Out-Null } `
    -Pattern 'duplicate TargetId' `
    -Message 'duplicate target rows should fail fast.'

$validConfigPath = Join-Path $tmpRoot 'valid-target-autoloop.psd1'
[System.IO.File]::WriteAllText($validConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
        @{ Id = 'target02'; Folder = 'C:\tmp\target02'; WindowTitle = 'Target02'; FixedSuffix = `$null }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DefaultPublishReadyDispatchDelaySeconds = 12
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); PublishReadyDispatchDelaySeconds = 18 }
            @{ TargetId = 'target02'; Enabled = `$false; TriggerKinds = @('input-file', 'publish-ready') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$resolved = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $validConfigPath
Assert-True ([string]$resolved.RunMode -eq 'target-autoloop') 'run mode should resolve to target-autoloop.'
Assert-True ([string]$resolved.MutexScope -eq 'target') 'mutex scope should stay target.'
Assert-True ([int]$resolved.DefaultPublishReadyDispatchDelaySeconds -eq 12) 'default publish-ready dispatch delay should resolve from config.'
Assert-True (@($resolved.Targets).Count -eq 2) 'two targets should be resolved.'
$target01 = @($resolved.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([bool]$target01.Enabled) 'target01 should be enabled.'
Assert-True ([string]$target01.FixedSuffix -eq 'suffix-01') 'target01 should inherit fixed suffix from Targets metadata.'
Assert-True (@($target01.TriggerKinds).Count -eq 2) 'target01 should keep both trigger kinds in target-autoloop mode.'
Assert-True ([int]$target01.PublishReadyDispatchDelaySeconds -eq 18) 'target01 should keep explicit publish-ready dispatch delay.'
$target02 = @($resolved.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
Assert-True ([int]$target02.PublishReadyDispatchDelaySeconds -eq 12) 'target02 should inherit global publish-ready dispatch delay.'

$externalWorkRepoRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'relay-target-autoloop-workrepo-config'
$workRepoConfigPath = Join-Path $tmpRoot 'workrepo-target-autoloop.psd1'
[System.IO.File]::WriteAllText($workRepoConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = `$null }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file'); WorkRepoRoot = '$($externalWorkRepoRoot.Replace("'", "''"))' }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$workRepoResolved = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $workRepoConfigPath
$workRepoTarget = @($workRepoResolved.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$workRepoTarget.WorkRepoRoot -eq [System.IO.Path]::GetFullPath($externalWorkRepoRoot)) 'target WorkRepoRoot should resolve to an absolute external path.'
$workRepoPaths = Get-TargetAutoloopTargetPaths -RunRoot (Join-Path $tmpRoot 'central-runroot') -TargetId 'target01' -Target $workRepoTarget -Config $workRepoResolved
Assert-True ([string]$workRepoPaths.TargetRunRoot -match [regex]::Escape('\.relay-runs\bottest-live-visible\target-autoloop\central-runroot')) 'target-local runroot should derive under WorkRepoRoot.'
Assert-True ([string]$workRepoPaths.SourceSummaryPath -match [regex]::Escape('target01\source-outbox\summary.txt')) 'target-local contract summary should remain target-scoped.'
Assert-True ([string]$workRepoPaths.TargetStateRoot -match [regex]::Escape('target01\.state')) 'target sidecar state root should remain target-scoped.'
Assert-True ([string]$workRepoPaths.TargetStatusPath -match [regex]::Escape('target01\.state\target-autoloop-status.json')) 'target sidecar status path should remain target-scoped.'
Assert-True ([string]$workRepoPaths.TargetControlPath -match [regex]::Escape('target01\.state\target-autoloop-control.json')) 'target sidecar control path should remain target-scoped.'
Assert-True ([string]$workRepoPaths.TargetEventsPath -match [regex]::Escape('target01\.state\target-events.jsonl')) 'target sidecar events path should remain target-scoped.'
Assert-True ([string]$workRepoPaths.TargetWatcherMutexName -match '^Global\\RelayTargetAutoloopTarget_[0-9a-f]+$') 'target watcher mutex preview should be target-scoped.'

$automationRepoWorkRepoConfigPath = Join-Path $tmpRoot 'automation-workrepo-target-autoloop.psd1'
[System.IO.File]::WriteAllText($automationRepoWorkRepoConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = `$null }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file'); WorkRepoRoot = '$($tmpRoot.Replace("'", "''"))' }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

Assert-ThrowsLike `
    -Action { Resolve-TargetAutoloopConfig -Root $root -ConfigPath $automationRepoWorkRepoConfigPath | Out-Null } `
    -Pattern 'WorkRepoRoot must be outside automation repo' `
    -Message 'target WorkRepoRoot under the automation repo should fail fast.'

$rangeConfigPath = Join-Path $tmpRoot 'range-target-autoloop.psd1'
[System.IO.File]::WriteAllText($rangeConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
        @{ Id = 'target02'; Folder = 'C:\tmp\target02'; WindowTitle = 'Target02'; FixedSuffix = `$null }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DefaultPublishReadyDispatchMinDelaySeconds = 15
        DefaultPublishReadyDispatchMaxDelaySeconds = 30
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); PublishReadyDispatchMinDelaySeconds = 17; PublishReadyDispatchMaxDelaySeconds = 21 }
            @{ TargetId = 'target02'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$rangeResolved = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $rangeConfigPath
Assert-True ([string]$rangeResolved.DefaultPublishReadyDispatchDelayMode -eq 'range') 'global publish-ready delay mode should resolve to range.'
Assert-True ([int]$rangeResolved.DefaultPublishReadyDispatchMinDelaySeconds -eq 15) 'global publish-ready min delay should resolve from config.'
Assert-True ([int]$rangeResolved.DefaultPublishReadyDispatchMaxDelaySeconds -eq 30) 'global publish-ready max delay should resolve from config.'
$rangeTarget01 = @($rangeResolved.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$rangeTarget01.PublishReadyDispatchDelayMode -eq 'range') 'target01 should resolve to range delay mode.'
Assert-True ([int]$rangeTarget01.PublishReadyDispatchMinDelaySeconds -eq 17) 'target01 should keep explicit publish-ready min delay.'
Assert-True ([int]$rangeTarget01.PublishReadyDispatchMaxDelaySeconds -eq 21) 'target01 should keep explicit publish-ready max delay.'
$rangeTarget02 = @($rangeResolved.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
Assert-True ([int]$rangeTarget02.PublishReadyDispatchMinDelaySeconds -eq 15) 'target02 should inherit global publish-ready min delay.'
Assert-True ([int]$rangeTarget02.PublishReadyDispatchMaxDelaySeconds -eq 30) 'target02 should inherit global publish-ready max delay.'

Write-Host 'target autoloop config ok'
