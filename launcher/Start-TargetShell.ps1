[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$WindowTitle,
    [Parameter(Mandatory)][string]$RootPath,
    [Parameter(Mandatory)][string]$ManagedMarker,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
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

function Start-VisibleWorkerBootstrap {
    param(
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath
    )

    $pairConfigScript = Join-Path $Root 'tests\PairedExchangeConfig.ps1'
    if (-not (Test-Path -LiteralPath $pairConfigScript -PathType Leaf)) {
        return
    }

    . $pairConfigScript
    $pairTest = Resolve-PairTestConfig -Root $Root -ConfigPath $ResolvedConfigPath
    if (-not [bool]$pairTest.VisibleWorker.Enabled) {
        return
    }

    $statusPath = Join-Path (Join-Path ([string]$pairTest.VisibleWorker.StatusRoot) 'workers') ("worker_{0}.json" -f $TargetKey)
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
    if ($existingPid -gt 0) {
        try {
            $null = Get-Process -Id $existingPid -ErrorAction Stop
            Write-Host ("VISIBLE_WORKER: already-running target={0} pid={1}" -f $TargetKey, $existingPid) -ForegroundColor DarkCyan
            return
        }
        catch {
        }
    }

    $logRoot = Join-Path ([string]$pairTest.VisibleWorker.LogRoot) 'bootstrap'
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $stdoutLogPath = Join-Path $logRoot ("worker_{0}_{1}.stdout.log" -f $TargetKey, $timestamp)
    $stderrLogPath = Join-Path $logRoot ("worker_{0}_{1}.stderr.log" -f $TargetKey, $timestamp)
    $workerScriptPath = Join-Path $Root 'visible\Start-VisibleTargetWorker.ps1'
    $powershellPath = Resolve-PowerShellExecutable
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $workerScriptPath,
        '-ConfigPath', $ResolvedConfigPath,
        '-TargetId', $TargetKey
    )

    $workerProcess = Start-Process -FilePath $powershellPath -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath
    Write-Host ("VISIBLE_WORKER: started target={0} pid={1}" -f $TargetKey, $workerProcess.Id) -ForegroundColor DarkCyan
}

$env:RELAY_TARGET_ID = $TargetId
$env:RELAY_MANAGED_MARKER = $ManagedMarker
$Host.UI.RawUI.WindowTitle = $WindowTitle
Set-Location $RootPath

if (Test-NonEmptyString $ConfigPath) {
    try {
        $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
        Start-VisibleWorkerBootstrap -TargetKey $TargetId -Root (Split-Path -Parent $PSScriptRoot) -ResolvedConfigPath $resolvedConfigPath
    }
    catch {
        Write-Warning ("visible worker bootstrap skipped target={0} reason={1}" -f $TargetId, $_.Exception.Message)
    }
}

Write-Host "READY: $WindowTitle" -ForegroundColor Green
