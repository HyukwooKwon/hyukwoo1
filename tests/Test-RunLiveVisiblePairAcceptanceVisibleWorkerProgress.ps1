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

function Load-FunctionText {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Names
    )

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ('parse failed for ' + $ScriptPath)
    }

    $functions = @{}
    foreach ($name in $Names) {
        $match = @(
            $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $name
                }, $true) | Select-Object -First 1
        )
        if (@($match).Count -ne 1) {
            throw ('function not found: ' + $name)
        }
        $functions[$name] = $match[0].Extent.Text
    }

    return $functions
}

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1'
$functions = Load-FunctionText -ScriptPath $scriptPath -Names @(
    'Test-NonEmptyString',
    'Get-ResultPropertyValue',
    'Get-IsoTimestampAgeSeconds',
    'Test-VisibleWorkerTargetProgress',
    'Test-LiveAcceptanceTargetProgress',
    'Resolve-AcceptanceWatcherMaxForwardCount',
    'Get-SourceOutboxPendingReadySummary',
    'Test-PublishPrimitiveLateGraceCandidate'
)

function Get-ConfigValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }
        return $DefaultValue
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
}

foreach ($name in @('Test-NonEmptyString', 'Get-ResultPropertyValue', 'Get-IsoTimestampAgeSeconds', 'Test-VisibleWorkerTargetProgress', 'Test-LiveAcceptanceTargetProgress', 'Resolve-AcceptanceWatcherMaxForwardCount', 'Get-SourceOutboxPendingReadySummary', 'Test-PublishPrimitiveLateGraceCandidate')) {
    Invoke-Expression $functions[$name]
}

$pairTest = [pscustomobject]@{
    VisibleWorker = [pscustomobject]@{
        DispatchAcceptedStaleSeconds = 15
        DispatchRunningStaleSeconds = 30
    }
}

$freshAccepted = [pscustomobject]@{
    LatestState = ''
    SourceOutboxState = ''
    SourceOutboxContractLatestState = ''
    SourceOutboxNextAction = ''
    DispatchState = 'accepted'
    DispatchHeartbeatAt = ''
    DispatchUpdatedAt = (Get-Date).AddSeconds(-5).ToString('o')
}
Assert-True (Test-VisibleWorkerTargetProgress -Row $freshAccepted -PairTest $pairTest) 'fresh accepted dispatch should count as progress.'

$staleAccepted = [pscustomobject]@{
    LatestState = ''
    SourceOutboxState = ''
    SourceOutboxContractLatestState = ''
    SourceOutboxNextAction = ''
    DispatchState = 'accepted'
    DispatchHeartbeatAt = ''
    DispatchUpdatedAt = (Get-Date).AddSeconds(-40).ToString('o')
}
Assert-True (-not (Test-VisibleWorkerTargetProgress -Row $staleAccepted -PairTest $pairTest)) 'stale accepted dispatch should not count as progress.'

$freshRunning = [pscustomobject]@{
    LatestState = ''
    SourceOutboxState = ''
    SourceOutboxContractLatestState = ''
    SourceOutboxNextAction = ''
    DispatchState = 'running'
    DispatchHeartbeatAt = (Get-Date).AddSeconds(-10).ToString('o')
    DispatchUpdatedAt = (Get-Date).AddSeconds(-20).ToString('o')
}
Assert-True (Test-VisibleWorkerTargetProgress -Row $freshRunning -PairTest $pairTest) 'fresh running dispatch should count as progress.'

$staleRunning = [pscustomobject]@{
    LatestState = ''
    SourceOutboxState = ''
    SourceOutboxContractLatestState = ''
    SourceOutboxNextAction = ''
    DispatchState = 'running'
    DispatchHeartbeatAt = (Get-Date).AddSeconds(-45).ToString('o')
    DispatchUpdatedAt = (Get-Date).AddSeconds(-45).ToString('o')
}
Assert-True (-not (Test-VisibleWorkerTargetProgress -Row $staleRunning -PairTest $pairTest)) 'stale running dispatch should not count as progress.'

$outboxProgress = [pscustomobject]@{
    LatestState = ''
    SourceOutboxState = 'publish-started'
    SourceOutboxContractLatestState = ''
    SourceOutboxNextAction = ''
    DispatchState = ''
    DispatchHeartbeatAt = ''
    DispatchUpdatedAt = ''
}
Assert-True (Test-VisibleWorkerTargetProgress -Row $outboxProgress -PairTest $pairTest) 'source-outbox publish-started should still count as progress.'

$typedWindowReadyToForward = [pscustomobject]@{
    LatestState = 'ready-to-forward'
    SourceOutboxState = 'imported'
    SourceOutboxContractLatestState = 'ready-to-forward'
    SourceOutboxNextAction = 'handoff-ready'
    DispatchState = ''
    DispatchHeartbeatAt = ''
    DispatchUpdatedAt = ''
}
Assert-True (Test-LiveAcceptanceTargetProgress -Row $typedWindowReadyToForward -PairTest $pairTest) 'typed-window imported handoff-ready target should extend acceptance grace.'

$acceptanceCap = Resolve-AcceptanceWatcherMaxForwardCount -ConfiguredMaxForwardCount 0 -TargetForwardedStateCount 2 -KeepRunning:$false
Assert-True ($acceptanceCap -eq 2) 'acceptance watcher should default to the target forward count when not kept running.'

$explicitCap = Resolve-AcceptanceWatcherMaxForwardCount -ConfiguredMaxForwardCount 4 -TargetForwardedStateCount 2 -KeepRunning:$false
Assert-True ($explicitCap -eq 4) 'explicit watcher max forward count should be preserved.'

$keepRunningCap = Resolve-AcceptanceWatcherMaxForwardCount -ConfiguredMaxForwardCount 0 -TargetForwardedStateCount 2 -KeepRunning:$true
Assert-True ($keepRunningCap -eq 0) 'keep-running acceptance should not add an implicit max forward count.'

$pendingReadySummary = Get-SourceOutboxPendingReadySummary -Status ([pscustomobject]@{
        Counts = [pscustomobject]@{
            SourceOutboxPendingReadyCount = 1
        }
        Targets = @(
            [pscustomobject]@{
                TargetId = 'target04'
                PublishReadyPresent = $true
                PublishReadyPath = 'C:\repo\.relay-runs\run\target04\publish.ready.json'
            },
            [pscustomobject]@{
                TargetId = 'target08'
                PublishReadyPresent = $false
                PublishReadyPath = 'C:\repo\.relay-runs\run\target08\publish.ready.json'
            }
        )
    })
Assert-True ([int]$pendingReadySummary.PendingReadyCount -eq 1) 'source-outbox closeout summary should preserve pending-ready count.'
Assert-True (@($pendingReadySummary.PendingReadyTargets).Count -eq 1) 'source-outbox closeout summary should list pending-ready targets.'

$publishStartedPrimitive = [pscustomobject]@{
    PrimitiveSuccess = $false
    PrimitiveState = 'missing'
    PrimitiveReason = 'publish-started/(none)/no-zip'
    SourceOutboxState = 'publish-started'
    PairedTargetStatus = [pscustomobject]@{
        SourceOutboxState = 'publish-started'
    }
}
Assert-True (Test-PublishPrimitiveLateGraceCandidate -PublishPrimitive $publishStartedPrimitive) 'publish-started primitive should get a late-marker grace window.'

$missingPrimitive = [pscustomobject]@{
    PrimitiveSuccess = $false
    PrimitiveState = 'missing'
    PrimitiveReason = '(none)/(none)/(none)'
    SourceOutboxState = ''
    PairedTargetStatus = [pscustomobject]@{
        SourceOutboxState = ''
    }
}
Assert-True (-not (Test-PublishPrimitiveLateGraceCandidate -PublishPrimitive $missingPrimitive)) 'empty missing primitive should not wait in late-marker grace.'

$alreadyObservedPrimitive = [pscustomobject]@{
    PrimitiveSuccess = $true
    PrimitiveState = 'observed'
    PrimitiveReason = 'publish-started/(none)/ready-to-forward'
    SourceOutboxState = 'publish-started'
}
Assert-True (-not (Test-PublishPrimitiveLateGraceCandidate -PublishPrimitive $alreadyObservedPrimitive)) 'already observed primitive should not enter late-marker grace.'

Write-Host 'run-live-visible-pair-acceptance visible worker progress freshness ok'
