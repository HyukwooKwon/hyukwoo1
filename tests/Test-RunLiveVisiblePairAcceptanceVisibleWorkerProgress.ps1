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
    'Get-IsoTimestampAgeSeconds',
    'Test-VisibleWorkerTargetProgress'
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

foreach ($name in @('Test-NonEmptyString', 'Get-IsoTimestampAgeSeconds', 'Test-VisibleWorkerTargetProgress')) {
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

Write-Host 'run-live-visible-pair-acceptance visible worker progress freshness ok'
