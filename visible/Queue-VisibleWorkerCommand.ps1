[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$PromptFilePath,
    [ValidateSet('seed', 'handoff', 'manual')][string]$Mode = 'seed',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }

        if ($command.Source) {
            return [string]$command.Source
        }
        if ($command.Path) {
            return [string]$command.Path
        }
        return [string]$name
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "json file is empty: $Path"
    }

    return ($raw | ConvertFrom-Json)
}

function Write-JsonFileAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $tempPath = ($Path + '.tmp')
    $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Get-WorkerStatusPath {
    param(
        [Parameter(Mandatory)][string]$StatusRoot,
        [Parameter(Mandatory)][string]$TargetKey
    )

    return (Join-Path (Join-Path $StatusRoot 'workers') ("worker_{0}.json" -f $TargetKey))
}

function Test-WorkerProcessAlive {
    param([int]$WorkerPid)

    if ($WorkerPid -le 0) {
        return $false
    }

    try {
        $null = Get-Process -Id $WorkerPid -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Ensure-VisibleWorkerRunning {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TargetKey
    )

    $statusPath = Get-WorkerStatusPath -StatusRoot ([string]$PairTest.VisibleWorker.StatusRoot) -TargetKey $TargetKey
    $statusDoc = $null
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try {
            $statusDoc = Read-JsonObject -Path $statusPath
        }
        catch {
            $statusDoc = $null
        }
    }

    $existingPid = if ($null -ne $statusDoc -and $null -ne $statusDoc.WorkerPid) { [int]$statusDoc.WorkerPid } else { 0 }
    if (Test-WorkerProcessAlive -WorkerPid $existingPid) {
        return [pscustomobject]@{
            Started         = $false
            WorkerPid       = $existingPid
            WorkerStatusPath = $statusPath
            StdOutLogPath   = [string]$statusDoc.StdOutLogPath
            StdErrLogPath   = [string]$statusDoc.StdErrLogPath
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $workerLogRoot = Join-Path ([string]$PairTest.VisibleWorker.LogRoot) 'workers'
    Ensure-Directory -Path $workerLogRoot
    $stdoutLogPath = Join-Path $workerLogRoot ("worker_{0}_{1}.stdout.log" -f $TargetKey, $timestamp)
    $stderrLogPath = Join-Path $workerLogRoot ("worker_{0}_{1}.stderr.log" -f $TargetKey, $timestamp)

    $powershellPath = Resolve-PowerShellExecutable
    $workerScriptPath = Join-Path $Root 'visible\Start-VisibleTargetWorker.ps1'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $workerScriptPath,
        '-ConfigPath', $ResolvedConfigPath,
        '-TargetId', $TargetKey
    )
    $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath

    return [pscustomobject]@{
        Started          = $true
        WorkerPid        = [int]$process.Id
        WorkerStatusPath = $statusPath
        StdOutLogPath    = $stdoutLogPath
        StdErrLogPath    = $stderrLogPath
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$resolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$resolvedPromptFilePath = (Resolve-Path -LiteralPath $PromptFilePath).Path
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "manifest not found: $manifestPath"
}

$manifest = Read-JsonObject -Path $manifestPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath -ManifestPairTest (Get-ConfigValue -Object $manifest -Name 'PairTest' -DefaultValue $null)
if (-not [bool]$pairTest.VisibleWorker.Enabled) {
    throw "visible worker is not enabled for config: $resolvedConfigPath"
}

$targetEntry = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq $TargetId } | Select-Object -First 1)
if ($targetEntry.Count -eq 0) {
    throw "target not found in manifest: $TargetId"
}

$queueRoot = Join-Path ([string]$pairTest.VisibleWorker.QueueRoot) $TargetId
$queuedRoot = Join-Path $queueRoot 'queued'
Ensure-Directory -Path $queuedRoot
Ensure-Directory -Path (Join-Path $queueRoot 'processing')
Ensure-Directory -Path (Join-Path $queueRoot 'completed')
Ensure-Directory -Path (Join-Path $queueRoot 'failed')

$commandId = [guid]::NewGuid().ToString('N')
$commandPath = Join-Path $queuedRoot ("command_{0}_{1}_{2}.json" -f $TargetId, $Mode, $commandId)
$command = [ordered]@{
    SchemaVersion   = '1.0.0'
    CommandId       = $commandId
    CreatedAt       = (Get-Date).ToString('o')
    RunRoot         = $resolvedRunRoot
    PairId          = [string]$targetEntry[0].PairId
    TargetId        = [string]$targetEntry[0].TargetId
    PartnerTargetId = [string](Get-ConfigValue -Object $targetEntry[0] -Name 'PartnerTargetId' -DefaultValue '')
    RoleName        = [string](Get-ConfigValue -Object $targetEntry[0] -Name 'RoleName' -DefaultValue '')
    Mode            = $Mode
    PromptFilePath  = $resolvedPromptFilePath
    MessagePath     = $resolvedPromptFilePath
}
Write-JsonFileAtomically -Path $commandPath -Payload $command

$workerLaunch = Ensure-VisibleWorkerRunning -Root $root -ResolvedConfigPath $resolvedConfigPath -PairTest $pairTest -TargetKey $TargetId

$result = [pscustomobject]@{
    TransportMode    = 'visible-worker'
    ConfigPath       = $resolvedConfigPath
    RunRoot          = $resolvedRunRoot
    TargetId         = $TargetId
    PairId           = [string]$targetEntry[0].PairId
    Mode             = $Mode
    CommandId        = $commandId
    CommandPath      = $commandPath
    PromptFilePath   = $resolvedPromptFilePath
    WorkerStarted    = [bool]$workerLaunch.Started
    WorkerPid        = [int]$workerLaunch.WorkerPid
    WorkerStatusPath = [string]$workerLaunch.WorkerStatusPath
    WorkerStdOutLogPath = [string]$workerLaunch.StdOutLogPath
    WorkerStdErrLogPath = [string]$workerLaunch.StdErrLogPath
}

if ($AsJson) {
    Write-Output ($result | ConvertTo-Json -Depth 8)
}
else {
    Write-Output $result
}
