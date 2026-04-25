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

$defaultConfigPath = Join-Path $testRoot 'settings.default.psd1'
$defaultConfigText = @"
@{
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

Write-Host 'pair-exchange-config visible worker preflight ok'
