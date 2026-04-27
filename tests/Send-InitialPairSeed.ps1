[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [string[]]$TargetId,
    [string]$MessageTextFilePath,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Import-ConfigDataFile {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $importCommand = Get-Command -Name Import-PowerShellDataFile -ErrorAction SilentlyContinue
    if ($null -ne $importCommand) {
        return Import-PowerShellDataFile -Path $resolvedPath
    }

    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
    return [scriptblock]::Create($raw).InvokeReturnAsIs()
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "json file is empty: $Path"
    }
    return ($raw | ConvertFrom-Json)
}

function Convert-ProducerOutputToRawText {
    param([Parameter(Mandatory)][object[]]$ProducerOutput)

    $lines = @(
        $ProducerOutput |
            ForEach-Object { [string]$_ }
    )
    return (($lines -join [Environment]::NewLine).Trim())
}

function Invoke-ProducerReadyFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$TextFilePath
    )

    $producerScriptPath = Join-Path $Root 'producer-example.ps1'
    $producerOutput = & {
        & $producerScriptPath `
            -ConfigPath $ConfigPath `
            -TargetId $TargetKey `
            -TextFilePath $TextFilePath
    } 6>&1

    $producerRaw = Convert-ProducerOutputToRawText -ProducerOutput @($producerOutput)
    if ([string]::IsNullOrWhiteSpace($producerRaw)) {
        throw "producer returned no output for target: $TargetKey"
    }

    $readyPath = ''
    $match = [regex]::Match($producerRaw, 'created ready file:\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        $readyPath = [string]$match.Groups[1].Value.Trim()
    }

    return [pscustomobject]@{
        ReadyPath      = $readyPath
        ProducerOutput = $producerRaw
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$resolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "manifest not found: $manifestPath"
}

$config = Import-ConfigDataFile -Path $resolvedConfigPath
$manifest = Read-JsonObject -Path $manifestPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath -ManifestPairTest (Get-ConfigValue -Object $manifest -Name 'PairTest' -DefaultValue $null)
$executionPathMode = [string](Get-ConfigValue -Object $pairTest -Name 'ExecutionPathMode' -DefaultValue $(if ([bool]$pairTest.VisibleWorker.Enabled) { 'visible-worker' } else { 'typed-window' }))
$visibleWorkerTransport = ($executionPathMode -eq 'visible-worker')
$typedWindowTransport = ($executionPathMode -eq 'typed-window')
if (-not $visibleWorkerTransport -and -not $typedWindowTransport) {
    throw "unsupported PairTest.ExecutionPathMode: $executionPathMode"
}
if ($visibleWorkerTransport -and -not [bool]$pairTest.VisibleWorker.Enabled) {
    throw 'PairTest.ExecutionPathMode is visible-worker but PairTest.VisibleWorker.Enabled is false.'
}
$manifestTargets = @($manifest.Targets)
if ($manifestTargets.Count -eq 0) {
    throw "manifest contains no targets: $manifestPath"
}

$requestedTargetIds = @($TargetId | Where-Object { Test-NonEmptyString $_ } | ForEach-Object { [string]$_ })
if ($requestedTargetIds.Count -eq 0) {
    $requestedTargetIds = @($manifest.SeedTargetIds | Where-Object { Test-NonEmptyString $_ } | ForEach-Object { [string]$_ })
}
if ($requestedTargetIds.Count -eq 0) {
    $requestedTargetIds = @(
        $manifestTargets |
            Where-Object { ($_.SeedEnabled -eq $true) -or ([string]$_.InitialRoleMode -eq 'seed') } |
            ForEach-Object { [string]$_.TargetId }
    )
}
if ($requestedTargetIds.Count -eq 0) {
    throw "no seed targets could be resolved from manifest: $manifestPath"
}

$selectedTargets = @()
foreach ($id in $requestedTargetIds) {
    $row = @($manifestTargets | Where-Object { [string]$_.TargetId -eq $id } | Select-Object -First 1)
    if ($row.Count -eq 0) {
        throw "target not found in manifest: $id"
    }
    $selectedTargets += $row[0]
}

$results = @()
$resolvedExplicitMessageTextFilePath = ''
if (Test-NonEmptyString $MessageTextFilePath) {
    $resolvedExplicitMessageTextFilePath = (Resolve-Path -LiteralPath $MessageTextFilePath).Path
}

foreach ($row in $selectedTargets) {
    $targetKey = [string]$row.TargetId
    $messagePath = $resolvedExplicitMessageTextFilePath
    if (-not (Test-NonEmptyString $messagePath)) {
        $messagePath = [string]$row.MessagePath
        if (-not (Test-NonEmptyString $messagePath) -and (Test-NonEmptyString ([string]$row.RequestPath)) -and (Test-Path -LiteralPath ([string]$row.RequestPath) -PathType Leaf)) {
            $request = Read-JsonObject -Path ([string]$row.RequestPath)
            $messagePath = [string]$request.MessagePath
        }
    }
    if (-not (Test-NonEmptyString $messagePath)) {
        throw "message path missing for target: $targetKey"
    }
    $resolvedMessagePath = (Resolve-Path -LiteralPath $messagePath).Path

    $targetConfig = @($config.Targets | Where-Object { [string]$_.Id -eq $targetKey } | Select-Object -First 1)
    if ($targetConfig.Count -eq 0) {
        throw "target relay config not found: $targetKey"
    }

    if ($visibleWorkerTransport) {
        $workerRaw = & (Join-Path $root 'visible\Queue-VisibleWorkerCommand.ps1') `
            -ConfigPath $resolvedConfigPath `
            -RunRoot $resolvedRunRoot `
            -TargetId $targetKey `
            -PromptFilePath $resolvedMessagePath `
            -Mode 'seed' `
            -AsJson
        $workerResult = $workerRaw | ConvertFrom-Json

        $results += [pscustomobject]@{
            TargetId        = $targetKey
            MessagePath     = $resolvedMessagePath
            ReadyPath       = [string]$workerResult.CommandPath
            ProducerOutput  = 'visible-worker-enqueued'
            TransportMode   = 'visible-worker'
            CommandId       = [string]$workerResult.CommandId
            WorkerStarted   = [bool]$workerResult.WorkerStarted
            WorkerStatusPath = [string]$workerResult.WorkerStatusPath
        }
    }
    elseif ($typedWindowTransport) {
        $producerResult = Invoke-ProducerReadyFile `
            -Root $root `
            -ConfigPath $resolvedConfigPath `
            -TargetKey $targetKey `
            -TextFilePath $resolvedMessagePath

        $results += [pscustomobject]@{
            TargetId       = $targetKey
            MessagePath    = $resolvedMessagePath
            ReadyPath      = [string]$producerResult.ReadyPath
            ProducerOutput = [string]$producerResult.ProducerOutput
            TransportMode  = 'router-ready-file'
            CommandId      = ''
            WorkerStarted  = $false
            WorkerStatusPath = ''
        }
    }
    else {
        throw "unsupported PairTest.ExecutionPathMode: $executionPathMode"
    }
}

$result = [pscustomobject]@{
    RunRoot        = $resolvedRunRoot
    ConfigPath     = $resolvedConfigPath
    RequestedTargets = @($requestedTargetIds)
    Results          = @($results)
}

if ($AsJson) {
    Write-Output ($result | ConvertTo-Json -Depth 6)
}
else {
    Write-Output $result
}
