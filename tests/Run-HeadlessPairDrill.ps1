[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$PairId,
    [string]$InitialTargetId,
    [int]$MaxForwardCount = 2,
    [int]$RunDurationSec = 900,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

function Format-CommandLine {
    param([Parameter(Mandatory)][string[]]$Parts)

    return (($Parts | ForEach-Object {
        if ($_ -match '\s') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join ' ')
}

function ConvertTo-CommandArgumentList {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath
    )

    foreach ($entry in $Parameters.GetEnumerator()) {
        $parameterName = '-' + [string]$entry.Key
        $value = $entry.Value

        if ($value -is [switch]) {
            if ($value.IsPresent) {
                $argumentList += $parameterName
            }
            continue
        }

        if ($value -is [bool]) {
            if ($value) {
                $argumentList += $parameterName
            }
            continue
        }

        if ($value -is [System.Array]) {
            $argumentList += $parameterName
            foreach ($item in $value) {
                $argumentList += [string]$item
            }
            continue
        }

        $argumentList += $parameterName
        $argumentList += [string]$value
    }

    return @($argumentList)
}

function Resolve-PowerShellExecutable {
    $candidates = @('pwsh.exe', 'powershell.exe')
    foreach ($name in $candidates) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            if ($command.Source) {
                return [string]$command.Source
            }
            if ($command.Path) {
                return [string]$command.Path
            }
            return [string]$name
        }
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Invoke-ScriptAndCaptureOutput {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $powershellPath = Resolve-PowerShellExecutable
    $argumentList = ConvertTo-CommandArgumentList -ScriptPath $ScriptPath -Parameters $Parameters
    $scriptOutput = @()
    foreach ($line in @(& $powershellPath @argumentList 2>&1)) {
        $scriptOutput += [string]$line
    }

    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = ($scriptOutput -join [Environment]::NewLine)
        throw "스크립트 실행 실패 exitCode=$exitCode file=$ScriptPath output=$detail"
    }

    return @($scriptOutput)
}

function Resolve-PreparedRunRootFromOutput {
    param([Parameter(Mandatory)][string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -match '^prepared pair test root:\s*(.+)$') {
            return [string]$Matches[1].Trim()
        }
    }

    return ''
}

function Resolve-FullPathFromCurrentLocation {
    param([Parameter(Mandatory)][string]$PathValue)

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PathValue))
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')
. (Join-Path $PSScriptRoot 'PairActivation.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
if (-not (Test-NonEmptyString $PairId)) {
    $PairId = Get-DefaultPairId -PairTest $pairTest
}
$pairDefinition = Get-PairDefinition -PairTest $pairTest -PairId $PairId
$pairActivation = Assert-PairActivationEnabled -Root $root -Config $config -PairId $PairId
if (-not (Test-NonEmptyString $InitialTargetId)) {
    $InitialTargetId = [string]$pairDefinition.TopTargetId
}

$startScriptPath = Join-Path $root 'tests\Start-PairedExchangeTest.ps1'
$watchScriptPath = Join-Path $root 'tests\Watch-PairedExchange.ps1'
$statusScriptPath = Join-Path $root 'show-paired-exchange-status.ps1'

$startParams = @{
    ConfigPath                             = $resolvedConfigPath
    IncludePairId                          = @($PairId)
    InitialTargetId                        = @($InitialTargetId)
    SendInitialMessages                    = $true
    UseHeadlessDispatch                    = $true
    AllowHeadlessDispatchInTypedWindowLane = $true
}
if (Test-NonEmptyString $RunRoot) {
    $startParams.RunRoot = $RunRoot
}

$startOutput = Invoke-ScriptAndCaptureOutput -ScriptPath $startScriptPath -Parameters $startParams
$resolvedRunRoot = Resolve-PreparedRunRootFromOutput -Lines $startOutput
if (-not (Test-NonEmptyString $resolvedRunRoot)) {
    if (Test-NonEmptyString $RunRoot) {
        $resolvedRunRoot = Resolve-FullPathFromCurrentLocation -PathValue $RunRoot
    }
    else {
        throw 'Start-PairedExchangeTest 출력에서 prepared pair test root를 찾지 못했습니다.'
    }
}

$watchParams = @{
    ConfigPath                             = $resolvedConfigPath
    RunRoot                                = $resolvedRunRoot
    UseHeadlessDispatch                    = $true
    AllowHeadlessDispatchInTypedWindowLane = $true
    MaxForwardCount                        = $MaxForwardCount
    RunDurationSec                         = $RunDurationSec
}
$watchOutput = Invoke-ScriptAndCaptureOutput -ScriptPath $watchScriptPath -Parameters $watchParams

$statusRaw = & $statusScriptPath -ConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -AsJson
$pairedStatus = $statusRaw | ConvertFrom-Json

$donePresentCount = [int]($pairedStatus.Counts.DonePresentCount)
$errorPresentCount = [int]($pairedStatus.Counts.ErrorPresentCount)
$forwardedStateCount = [int]($pairedStatus.Counts.ForwardedStateCount)
$watcherStatus = [string]$pairedStatus.Watcher.Status

$startCommandParts = @(
    'powershell',
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $startScriptPath,
    '-ConfigPath', $resolvedConfigPath,
    '-IncludePairId', $PairId,
    '-InitialTargetId', $InitialTargetId,
    '-SendInitialMessages',
    '-UseHeadlessDispatch',
    '-AllowHeadlessDispatchInTypedWindowLane'
)
if (Test-NonEmptyString $RunRoot) {
    $startCommandParts += @('-RunRoot', (Resolve-FullPathFromCurrentLocation -PathValue $RunRoot))
}

$result = [pscustomobject]@{
    GeneratedAt       = (Get-Date).ToString('o')
    ConfigPath        = $resolvedConfigPath
    PairId            = $PairId
    PairActivation    = $pairActivation
    InitialTargetId   = $InitialTargetId
    RunRoot           = $resolvedRunRoot
    MaxForwardCount   = $MaxForwardCount
    RunDurationSec    = $RunDurationSec
    Commands          = [pscustomobject]@{
        Start  = Format-CommandLine -Parts $startCommandParts
        Watch  = Format-CommandLine -Parts @('pwsh', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watchScriptPath, '-ConfigPath', $resolvedConfigPath, '-RunRoot', $resolvedRunRoot, '-UseHeadlessDispatch', '-AllowHeadlessDispatchInTypedWindowLane', '-MaxForwardCount', [string]$MaxForwardCount, '-RunDurationSec', [string]$RunDurationSec)
        Status = Format-CommandLine -Parts @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $statusScriptPath, '-ConfigPath', $resolvedConfigPath, '-RunRoot', $resolvedRunRoot, '-AsJson')
    }
    StartOutput       = @($startOutput)
    WatchOutput       = @($watchOutput)
    SuccessCriteria   = [pscustomobject]@{
        RequiredDonePresentCount    = 2
        RequiredForwardedStateCount = $MaxForwardCount
        RequiredErrorPresentCount   = 0
    }
    ObservedCounts    = [pscustomobject]@{
        DonePresentCount    = $donePresentCount
        ErrorPresentCount   = $errorPresentCount
        ForwardedStateCount = $forwardedStateCount
        WatcherStatus       = $watcherStatus
    }
    PairedStatus      = $pairedStatus
}

if ($errorPresentCount -gt 0 -or $donePresentCount -lt 2 -or $forwardedStateCount -lt $MaxForwardCount) {
    $message = "headless pair drill 성공 기준을 만족하지 못했습니다 runRoot=$resolvedRunRoot done=$donePresentCount error=$errorPresentCount forwarded=$forwardedStateCount watcher=$watcherStatus"
    throw $message
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 12
    return
}

Write-Host ("headless pair drill 완료 pair={0} initial={1}" -f $PairId, $InitialTargetId)
Write-Host ("run root: {0}" -f $resolvedRunRoot)
Write-Host ("done 개수: {0}" -f $donePresentCount)
Write-Host ("error 개수: {0}" -f $errorPresentCount)
Write-Host ("forwarded 개수: {0}" -f $forwardedStateCount)
Write-Host ("watcher 상태: {0}" -f $watcherStatus)
