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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

$testRoot = Join-Path $root '_tmp\test-pair-config-visible-worker-preflight'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$explicitConfigPath = Join-Path $testRoot 'settings.explicit.psd1'
$explicitConfigText = @"
@{
    Targets = @(
        @{ Id = 'target01'; Folder = '$($testRoot.Replace("'", "''"))\inbox\target01'; WindowTitle = 'VisibleWorkerTarget01'; EnterCount = 1 }
        @{ Id = 'target05'; Folder = '$($testRoot.Replace("'", "''"))\inbox\target05'; WindowTitle = 'VisibleWorkerTarget05'; EnterCount = 1 }
    )
    PairTest = @{
        ExecutionPathMode = 'visible-worker'
        AcceptanceProfile = 'smoke'
        SmokeSeedTaskText = 'smoke task text'
        HeadlessExec = @{
            MaxRunSeconds = 700
        }
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($testRoot.Replace("'", "''"))\queue-explicit'
            StatusRoot = '$($testRoot.Replace("'", "''"))\status-explicit'
            LogRoot = '$($testRoot.Replace("'", "''"))\logs-explicit'
            CommandTimeoutSeconds = 321
            DispatchTimeoutSeconds = 222
            PreflightTimeoutSeconds = 123
            WorkerReadyFreshnessSeconds = 22
            DispatchAcceptedStaleSeconds = 11
            DispatchRunningStaleSeconds = 44
            AcceptanceSeedSoftTimeoutSeconds = 66
        }
    }
}
"@
[System.IO.File]::WriteAllText($explicitConfigPath, $explicitConfigText, (New-Utf8NoBomEncoding))

$explicitPairTest = Resolve-PairTestConfig -Root $root -ConfigPath $explicitConfigPath
Assert-True ([bool]$explicitPairTest.VisibleWorker.Enabled) 'visible worker should be enabled for explicit config.'
Assert-True ([string]$explicitPairTest.ExecutionPathMode -eq 'visible-worker') 'explicit execution path mode should be preserved.'
Assert-True ([string]$explicitPairTest.AcceptanceProfile -eq 'smoke') 'explicit acceptance profile should be preserved.'
Assert-True ([string]$explicitPairTest.SmokeSeedTaskText -eq 'smoke task text') 'explicit smoke seed task text should be preserved.'
Assert-True ([int]$explicitPairTest.VisibleWorker.CommandTimeoutSeconds -eq 321) 'explicit command timeout should be preserved.'
Assert-True ([int]$explicitPairTest.VisibleWorker.DispatchTimeoutSeconds -eq 222) 'explicit dispatch timeout should be preserved.'
Assert-True ([int]$explicitPairTest.VisibleWorker.PreflightTimeoutSeconds -eq 123) 'explicit preflight timeout should be preserved.'
Assert-True ([int]$explicitPairTest.VisibleWorker.WorkerReadyFreshnessSeconds -eq 22) 'explicit worker readiness freshness should be preserved.'
Assert-True ([int]$explicitPairTest.VisibleWorker.DispatchAcceptedStaleSeconds -eq 11) 'explicit accepted stale threshold should be preserved.'
Assert-True ([int]$explicitPairTest.VisibleWorker.DispatchRunningStaleSeconds -eq 44) 'explicit running stale threshold should be preserved.'
Assert-True ([int]$explicitPairTest.VisibleWorker.AcceptanceSeedSoftTimeoutSeconds -eq 66) 'explicit seed soft timeout should be preserved.'

$typedVisibleConfigPath = Join-Path $testRoot 'settings.typed-visible.psd1'
$typedVisibleConfigText = @"
@{
    Targets = @(
        @{ Id = 'target01'; Folder = '$($testRoot.Replace("'", "''"))\inbox\target01'; WindowTitle = 'VisibleWorkerTarget01'; EnterCount = 1 }
        @{ Id = 'target05'; Folder = '$($testRoot.Replace("'", "''"))\inbox\target05'; WindowTitle = 'VisibleWorkerTarget05'; EnterCount = 1 }
    )
    PairTest = @{
        ExecutionPathMode = 'typed-window'
        RequireUserVisibleCellExecution = `$true
        AllowedWindowVisibilityMethods = @('hwnd')
        TypedWindow = @{
            SubmitProbeSeconds = 12
            SubmitProbePollMs = 750
            SubmitRetryLimit = 1
            ProgressCpuDeltaThresholdSeconds = 0.125
        }
        VisibleWorker = @{
            Enabled = `$true
        }
    }
}
"@
[System.IO.File]::WriteAllText($typedVisibleConfigPath, $typedVisibleConfigText, (New-Utf8NoBomEncoding))

$typedVisiblePairTest = Resolve-PairTestConfig -Root $root -ConfigPath $typedVisibleConfigPath
Assert-True ([string]$typedVisiblePairTest.ExecutionPathMode -eq 'typed-window') 'typed-window execution path mode should be preserved.'
Assert-True ([bool]$typedVisiblePairTest.RequireUserVisibleCellExecution) 'typed-window visible-cell requirement should be preserved.'
Assert-True (@($typedVisiblePairTest.AllowedWindowVisibilityMethods).Count -eq 1 -and [string]@($typedVisiblePairTest.AllowedWindowVisibilityMethods)[0] -eq 'hwnd') 'allowed window visibility methods should be preserved.'
Assert-True ([int]$typedVisiblePairTest.TypedWindow.SubmitProbeSeconds -eq 12) 'typed-window submit probe seconds should be preserved.'
Assert-True ([int]$typedVisiblePairTest.TypedWindow.SubmitProbePollMs -eq 750) 'typed-window submit probe poll milliseconds should be preserved.'
Assert-True ([int]$typedVisiblePairTest.TypedWindow.SubmitRetryLimit -eq 1) 'typed-window submit retry limit should be preserved.'
Assert-True ([double]$typedVisiblePairTest.TypedWindow.ProgressCpuDeltaThresholdSeconds -eq 0.125) 'typed-window progress CPU delta threshold should be preserved.'

$invalidConfigPath = Join-Path $testRoot 'settings.invalid-visible-worker.psd1'
$invalidConfigText = @"
@{
    Targets = @(
        @{ Id = 'target01'; Folder = '$($testRoot.Replace("'", "''"))\inbox\target01'; WindowTitle = 'VisibleWorkerTarget01'; EnterCount = 1 }
        @{ Id = 'target05'; Folder = '$($testRoot.Replace("'", "''"))\inbox\target05'; WindowTitle = 'VisibleWorkerTarget05'; EnterCount = 1 }
    )
    PairTest = @{
        ExecutionPathMode = 'visible-worker'
        RequireUserVisibleCellExecution = `$true
        VisibleWorker = @{
            Enabled = `$true
        }
    }
}
"@
[System.IO.File]::WriteAllText($invalidConfigPath, $invalidConfigText, (New-Utf8NoBomEncoding))

$invalidFailed = $false
try {
    $null = Resolve-PairTestConfig -Root $root -ConfigPath $invalidConfigPath
}
catch {
    $invalidFailed = ($_.Exception.Message -like '*RequireUserVisibleCellExecution*typed-window*')
}
Assert-True $invalidFailed 'visible-worker execution path should be rejected when user-visible cell execution is required.'

$defaultConfigPath = Join-Path $testRoot 'settings.default.psd1'
$defaultConfigText = @"
@{
    Targets = @(
        @{ Id = 'target01'; Folder = '$($testRoot.Replace("'", "''"))\inbox\target01'; WindowTitle = 'VisibleWorkerTarget01'; EnterCount = 1 }
        @{ Id = 'target05'; Folder = '$($testRoot.Replace("'", "''"))\inbox\target05'; WindowTitle = 'VisibleWorkerTarget05'; EnterCount = 1 }
    )
    PairTest = @{
        HeadlessExec = @{
            MaxRunSeconds = 480
        }
        VisibleWorker = @{
            Enabled = `$true
        }
    }
}
"@
[System.IO.File]::WriteAllText($defaultConfigPath, $defaultConfigText, (New-Utf8NoBomEncoding))

$defaultPairTest = Resolve-PairTestConfig -Root $root -ConfigPath $defaultConfigPath
Assert-True ([int]$defaultPairTest.VisibleWorker.CommandTimeoutSeconds -eq 540) 'default visible worker command timeout should follow headless max run + 60.'
Assert-True ([int]$defaultPairTest.VisibleWorker.DispatchTimeoutSeconds -eq 540) 'default visible worker dispatch timeout should follow visible worker command timeout.'
Assert-True ([int]$defaultPairTest.VisibleWorker.PreflightTimeoutSeconds -eq 180) 'default visible worker preflight timeout should be 180 seconds.'
Assert-True ([string]$defaultPairTest.ExecutionPathMode -eq 'visible-worker') 'default execution path mode should follow visible worker enablement.'
Assert-True ([string]$defaultPairTest.AcceptanceProfile -eq 'project-review') 'default acceptance profile should remain project-review.'
Assert-True ([string]$defaultPairTest.SmokeSeedTaskText -eq '') 'default smoke seed task text should be empty.'
Assert-True ([int]$defaultPairTest.VisibleWorker.WorkerReadyFreshnessSeconds -eq 30) 'default worker readiness freshness should be 30 seconds.'
Assert-True ([int]$defaultPairTest.VisibleWorker.DispatchAcceptedStaleSeconds -eq 15) 'default accepted stale threshold should be 15 seconds.'
Assert-True ([int]$defaultPairTest.VisibleWorker.DispatchRunningStaleSeconds -eq 30) 'default running stale threshold should be 30 seconds.'
Assert-True ([int]$defaultPairTest.VisibleWorker.AcceptanceSeedSoftTimeoutSeconds -eq 120) 'default seed soft timeout should be 120 seconds.'
Assert-True ([int]$defaultPairTest.TypedWindow.SubmitProbeSeconds -eq 10) 'default typed-window submit probe seconds should be 10 seconds.'
Assert-True ([int]$defaultPairTest.TypedWindow.SubmitProbePollMs -eq 1000) 'default typed-window submit probe poll should be 1000 ms.'
Assert-True ([int]$defaultPairTest.TypedWindow.SubmitRetryLimit -eq 1) 'default typed-window submit retry limit should be 1.'
Assert-True ([double]$defaultPairTest.TypedWindow.ProgressCpuDeltaThresholdSeconds -eq 0.05) 'default typed-window progress CPU delta threshold should be 0.05.'

Write-Host 'pair-exchange-config visible worker preflight ok'
