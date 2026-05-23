[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [int]$IdleExitSeconds = 30,
    [switch]$ProcessOnce,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\TargetAutoloopConfig.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
$resolvedRunRoot = if ([System.IO.Path]::IsPathRooted($RunRoot)) {
    [System.IO.Path]::GetFullPath($RunRoot)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $root $RunRoot))
}
$targetConfig = @($config.Targets | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') -eq $TargetId } | Select-Object -First 1)
if (@($targetConfig).Count -eq 0) {
    throw "target autoloop target config not found: $TargetId"
}
$queuePaths = Get-TargetAutoloopQueuePaths -RunRoot $resolvedRunRoot -TargetId $TargetId -Target $targetConfig[0] -Config $config
foreach ($queuePath in @($queuePaths.QueuedRoot, $queuePaths.ProcessingRoot, $queuePaths.CompletedRoot, $queuePaths.FailedRoot)) {
    Ensure-Directory -Path $queuePath
}

$deadline = (Get-Date).AddSeconds([math]::Max(1, $IdleExitSeconds))
$processedCount = 0
$lastResult = $null
do {
    $queuedCommand = Get-ChildItem -LiteralPath $queuePaths.QueuedRoot -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, Name |
        Select-Object -First 1

    if ($null -eq $queuedCommand) {
        if ($ProcessOnce) {
            break
        }
        Start-Sleep -Milliseconds 500
        continue
    }

    $raw = & (Join-Path $root 'tests\Dispatch-TargetAutoloopCommand.ps1') `
        -ConfigPath ([string]$config.ConfigPath) `
        -RunRoot $resolvedRunRoot `
        -TargetId $TargetId `
        -CommandPath $queuedCommand.FullName `
        -AsJson
    $lastResult = ($raw | ConvertFrom-Json)
    $dispatchState = [string](Get-ConfigValue -Object $lastResult -Name 'State' -DefaultValue '')
    if ($dispatchState -in @('blocked-by-controller', 'blocked-by-router-session-mismatch')) {
        if ($ProcessOnce) {
            break
        }
        Start-Sleep -Milliseconds 500
        continue
    }
    $processedCount += 1
    if ($ProcessOnce) {
        break
    }
} while ((Get-Date) -lt $deadline)

$result = [pscustomobject][ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    ConfigPath = [string]$config.ConfigPath
    RunRoot = $resolvedRunRoot
    TargetId = $TargetId
    ProcessedCount = $processedCount
    LastResult = $lastResult
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

$result
