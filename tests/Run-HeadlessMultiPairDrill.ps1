[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string[]]$PairId,
    [string[]]$InitialTargetId,
    [int]$PairMaxRoundtripCount = 1,
    [int]$RunDurationSec = 1800,
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

function Invoke-LocalScriptAndCaptureOutput {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $scriptOutput = @()
    try {
        foreach ($line in @(& $ScriptPath @Parameters 2>&1)) {
            $scriptOutput += [string]$line
        }
    }
    catch {
        $detail = ($scriptOutput -join [Environment]::NewLine)
        throw "스크립트 실행 실패 file=$ScriptPath output=$detail error=$($_.Exception.Message)"
    }

    return @($scriptOutput)
}

function Resolve-PreparedRunRootFromOutput {
    param([string[]]$Lines = @())

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

function Get-RunRootBaseCandidates {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$SelectedPairs
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @($SelectedPairs)) {
        $pairIdValue = [string]$pair.PairId
        $pairPolicy = Get-PairPolicyForPair -PairTest $PairTest -PairId $pairIdValue
        $pairWorkRepoRoot = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')
        $useExternalRunRoot = Test-UseExternalWorkRepoRunRoot -PairTest $PairTest -PairPolicy $pairPolicy -WorkRepoRoot $pairWorkRepoRoot
        $candidate = if ($useExternalRunRoot -and (Test-NonEmptyString $pairWorkRepoRoot)) {
            Resolve-ExternalWorkRepoRunRootBase -PairTest $PairTest -PairPolicy $pairPolicy -WorkRepoRoot $pairWorkRepoRoot
        }
        else {
            Resolve-FullPathFromCurrentLocation -PathValue ([string]$pairTest.RunRootBase)
        }

        if ($null -eq $candidate -or -not (Test-NonEmptyString $candidate)) {
            continue
        }
        if ($candidate -notin $candidates) {
            $candidates.Add([string]$candidate)
        }
    }

    return @($candidates)
}

function Get-DirectoryMapSnapshot {
    param([string[]]$BasePaths = @())

    $snapshot = @{}
    foreach ($basePath in @($BasePaths | Where-Object { Test-NonEmptyString $_ })) {
        $resolvedBasePath = [System.IO.Path]::GetFullPath([string]$basePath)
        $items = @()
        if (Test-Path -LiteralPath $resolvedBasePath -PathType Container) {
            $items = @(Get-ChildItem -LiteralPath $resolvedBasePath -Directory -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.FullName })
        }
        $snapshot[$resolvedBasePath] = @($items)
    }

    return $snapshot
}

function Resolve-NewRunRootFromSnapshots {
    param(
        [hashtable]$BeforeSnapshot,
        [string[]]$BasePaths = @()
    )

    $newCandidates = @()
    foreach ($basePath in @($BasePaths | Where-Object { Test-NonEmptyString $_ })) {
        $resolvedBasePath = [System.IO.Path]::GetFullPath([string]$basePath)
        if (-not (Test-Path -LiteralPath $resolvedBasePath -PathType Container)) {
            continue
        }

        $beforeItems = @()
        if ($null -ne $BeforeSnapshot -and $BeforeSnapshot.ContainsKey($resolvedBasePath)) {
            $beforeItems = @($BeforeSnapshot[$resolvedBasePath])
        }
        $beforeSet = @{}
        foreach ($item in @($beforeItems)) {
            $beforeSet[[string]$item] = $true
        }

        $afterItems = @(Get-ChildItem -LiteralPath $resolvedBasePath -Directory -ErrorAction SilentlyContinue)
        foreach ($item in @($afterItems)) {
            $fullName = [string]$item.FullName
            if ($beforeSet.ContainsKey($fullName)) {
                continue
            }

            $newCandidates += [pscustomobject]@{
                Path = $fullName
                LastWriteTimeUtc = $item.LastWriteTimeUtc
            }
        }
    }

    $selected = @($newCandidates | Sort-Object LastWriteTimeUtc, Path -Descending | Select-Object -First 1)
    if ($selected.Count -gt 0) {
        return [string]$selected[0].Path
    }

    return ''
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

$selectedPairs = if (@($PairId | Where-Object { Test-NonEmptyString $_ }).Count -gt 0) {
    @(Select-PairDefinitions -PairDefinitions @($pairTest.PairDefinitions) -IncludePairId @($PairId))
}
else {
    @($pairTest.PairDefinitions | Select-Object -First 2)
}

if ($selectedPairs.Count -lt 1) {
    throw 'headless multi pair drill에 사용할 pair를 찾지 못했습니다.'
}

$selectedPairIds = @($selectedPairs | ForEach-Object { [string]$_.PairId })
$pairActivationSummaries = @(
    foreach ($pair in @($selectedPairs)) {
        Assert-PairActivationEnabled -Root $root -Config $config -PairId ([string]$pair.PairId)
    }
)

$resolvedInitialTargetIds = if (@($InitialTargetId | Where-Object { Test-NonEmptyString $_ }).Count -gt 0) {
    @($InitialTargetId | Where-Object { Test-NonEmptyString $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
}
else {
    @(
        foreach ($pair in @($selectedPairs)) {
            $pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId ([string]$pair.PairId)
            [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedTargetId' -DefaultValue ([string]$pair.TopTargetId))
        }
    ) | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique
}

$startScriptPath = Join-Path $root 'tests\Start-PairedExchangeTest.ps1'
$watchScriptPath = Join-Path $root 'tests\Watch-PairedExchange.ps1'
$statusScriptPath = Join-Path $root 'show-paired-exchange-status.ps1'
$runRootBaseCandidates = @()
$runRootSnapshot = @{}
if (-not (Test-NonEmptyString $RunRoot)) {
    $runRootBaseCandidates = @(Get-RunRootBaseCandidates -Root $root -PairTest $pairTest -SelectedPairs @($selectedPairs))
    $runRootSnapshot = Get-DirectoryMapSnapshot -BasePaths @($runRootBaseCandidates)
}

$startParams = @{
    ConfigPath          = $resolvedConfigPath
    IncludePairId       = @($selectedPairIds)
    InitialTargetId     = @($resolvedInitialTargetIds)
    SendInitialMessages = $true
    UseHeadlessDispatch = $true
}
if (Test-NonEmptyString $RunRoot) {
    $startParams.RunRoot = $RunRoot
}

$startOutput = @(Invoke-LocalScriptAndCaptureOutput -ScriptPath $startScriptPath -Parameters $startParams)
$resolvedRunRoot = Resolve-PreparedRunRootFromOutput -Lines @($startOutput)
if (-not (Test-NonEmptyString $resolvedRunRoot)) {
    if (Test-NonEmptyString $RunRoot) {
        $resolvedRunRoot = Resolve-FullPathFromCurrentLocation -PathValue $RunRoot
    }
    else {
        $resolvedRunRoot = Resolve-NewRunRootFromSnapshots -BeforeSnapshot $runRootSnapshot -BasePaths @($runRootBaseCandidates)
        if (-not (Test-NonEmptyString $resolvedRunRoot)) {
            throw 'Start-PairedExchangeTest 출력 또는 run root base snapshot에서 prepared pair test root를 찾지 못했습니다.'
        }
    }
}

$watchParams = @{
    ConfigPath          = $resolvedConfigPath
    RunRoot             = $resolvedRunRoot
    UseHeadlessDispatch = $true
    PairMaxRoundtripCount = $PairMaxRoundtripCount
    RunDurationSec      = $RunDurationSec
}
$watchOutput = @(Invoke-LocalScriptAndCaptureOutput -ScriptPath $watchScriptPath -Parameters $watchParams)

$statusRaw = & $statusScriptPath -ConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -AsJson
$pairedStatus = $statusRaw | ConvertFrom-Json
$watcherStatus = [string]$pairedStatus.Watcher.Status

$pairRows = @(
    foreach ($pairIdentifier in @($selectedPairIds)) {
        @($pairedStatus.Pairs | Where-Object { [string]$_.PairId -eq $pairIdentifier } | Select-Object -First 1)
    }
)

$pairResultRows = @()
foreach ($pairRow in @($pairRows)) {
    if ($null -eq $pairRow) {
        continue
    }

    $pairResultRows += [pscustomobject]@{
        PairId               = [string]$pairRow.PairId
        Targets              = [string]$pairRow.Targets
        RoundtripCount       = [int]$pairRow.RoundtripCount
        ForwardedStateCount  = [int]$pairRow.ForwardedStateCount
        DonePresentCount     = [int]$pairRow.DonePresentCount
        ErrorPresentCount    = [int]$pairRow.ErrorPresentCount
        HandoffReadyCount    = [int]$pairRow.HandoffReadyCount
        DispatchRunningCount = [int]$pairRow.DispatchRunningCount
        DispatchFailedCount  = [int]$pairRow.DispatchFailedCount
        CurrentPhase         = [string]$pairRow.CurrentPhase
        NextAction           = [string]$pairRow.NextAction
        ProgressDetail       = [string]$pairRow.ProgressDetail
    }
}

$requiredDonePresentCount = $selectedPairIds.Count * 2
$requiredForwardedStateCount = $selectedPairIds.Count * ($PairMaxRoundtripCount * 2)

$result = [pscustomobject]@{
    GeneratedAt       = (Get-Date).ToString('o')
    ConfigPath        = $resolvedConfigPath
    PairIds           = @($selectedPairIds)
    PairActivations   = @($pairActivationSummaries)
    InitialTargetIds  = @($resolvedInitialTargetIds)
    RunRoot           = $resolvedRunRoot
    PairMaxRoundtripCount = $PairMaxRoundtripCount
    RunDurationSec    = $RunDurationSec
    Commands          = [pscustomobject]@{
        Start  = Format-CommandLine -Parts (@('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScriptPath, '-ConfigPath', $resolvedConfigPath, '-IncludePairId') + @($selectedPairIds) + @('-InitialTargetId') + @($resolvedInitialTargetIds) + @('-SendInitialMessages', '-UseHeadlessDispatch') + $(if (Test-NonEmptyString $RunRoot) { @('-RunRoot', (Resolve-FullPathFromCurrentLocation -PathValue $RunRoot)) } else { @() }))
        Watch  = Format-CommandLine -Parts @('pwsh', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watchScriptPath, '-ConfigPath', $resolvedConfigPath, '-RunRoot', $resolvedRunRoot, '-UseHeadlessDispatch', '-PairMaxRoundtripCount', [string]$PairMaxRoundtripCount, '-RunDurationSec', [string]$RunDurationSec)
        Status = Format-CommandLine -Parts @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $statusScriptPath, '-ConfigPath', $resolvedConfigPath, '-RunRoot', $resolvedRunRoot, '-AsJson')
    }
    StartOutput       = @($startOutput)
    WatchOutput       = @($watchOutput)
    SuccessCriteria   = [pscustomobject]@{
        RequiredPairCount               = $selectedPairIds.Count
        RequiredPairRoundtripCount      = $PairMaxRoundtripCount
        RequiredDonePresentCount        = $requiredDonePresentCount
        RequiredForwardedStateCount     = $requiredForwardedStateCount
        RequiredErrorPresentCount       = 0
    }
    ObservedCounts    = [pscustomobject]@{
        DonePresentCount        = [int]$pairedStatus.Counts.DonePresentCount
        ErrorPresentCount       = [int]$pairedStatus.Counts.ErrorPresentCount
        ForwardedStateCount     = [int]$pairedStatus.Counts.ForwardedStateCount
        WatcherStatus           = $watcherStatus
        PairCount               = @($pairResultRows).Count
    }
    PairResults       = @($pairResultRows)
    PairedStatus      = $pairedStatus
}

$missingPairIds = @($selectedPairIds | Where-Object { $_ -notin @($pairResultRows | ForEach-Object { [string]$_.PairId }) })
if ($missingPairIds.Count -gt 0) {
    throw ("headless multi pair drill 상태에 누락된 pair가 있습니다: {0}" -f ($missingPairIds -join ', '))
}

$globalDonePresentCount = [int]$pairedStatus.Counts.DonePresentCount
$globalErrorPresentCount = [int]$pairedStatus.Counts.ErrorPresentCount
$globalForwardedStateCount = [int]$pairedStatus.Counts.ForwardedStateCount

$failedPairRows = @(
    $pairResultRows | Where-Object {
        ([int]$_.ErrorPresentCount -gt 0) -or
        ([int]$_.DonePresentCount -lt 2) -or
        ([int]$_.RoundtripCount -lt $PairMaxRoundtripCount)
    }
)

if ($globalErrorPresentCount -gt 0 -or
    $globalDonePresentCount -lt $requiredDonePresentCount -or
    $globalForwardedStateCount -lt $requiredForwardedStateCount -or
    $failedPairRows.Count -gt 0) {
    $failedPairsSummary = @(
        foreach ($pairRow in @($failedPairRows)) {
            '{0}(roundtrip={1},done={2},error={3})' -f [string]$pairRow.PairId, [int]$pairRow.RoundtripCount, [int]$pairRow.DonePresentCount, [int]$pairRow.ErrorPresentCount
        }
    ) -join '; '
    $message = "headless multi pair drill 성공 기준을 만족하지 못했습니다 runRoot=$resolvedRunRoot done=$globalDonePresentCount error=$globalErrorPresentCount forwarded=$globalForwardedStateCount watcher=$watcherStatus failedPairs=$failedPairsSummary"
    throw $message
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 12
    return
}

Write-Host ("headless multi pair drill 완료 pairs={0}" -f ($selectedPairIds -join ', '))
Write-Host ("initial targets: {0}" -f ($resolvedInitialTargetIds -join ', '))
Write-Host ("run root: {0}" -f $resolvedRunRoot)
Write-Host ("done 개수: {0}" -f $globalDonePresentCount)
Write-Host ("error 개수: {0}" -f $globalErrorPresentCount)
Write-Host ("forwarded 개수: {0}" -f $globalForwardedStateCount)
Write-Host ("watcher 상태: {0}" -f $watcherStatus)
