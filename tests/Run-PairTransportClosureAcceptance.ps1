[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$PairId = 'pair01',
    [string]$InitialTargetId = 'target01',
    [int]$MaxForwardCount = 2,
    [int]$RunDurationSec = 900,
    [switch]$ReuseExistingRunRoot,
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

function Invoke-ScriptCapture {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $powershellPath = Resolve-PowerShellExecutable
    $argumentList = ConvertTo-CommandArgumentList -ScriptPath $ScriptPath -Parameters $Parameters
    $lines = @()
    foreach ($line in @(& $powershellPath @argumentList 2>&1)) {
        $lines += [string]$line
    }

    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ScriptPath = $ScriptPath
        Parameters = $Parameters
        OutputLines = @($lines)
        OutputText = ($lines -join [Environment]::NewLine)
        ExitCode = [int]$exitCode
        Succeeded = ($exitCode -eq 0)
    }
}

function Invoke-RequiredScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $result = Invoke-ScriptCapture -ScriptPath $ScriptPath -Parameters $Parameters
    if (-not $result.Succeeded) {
        throw "스크립트 실행 실패 exitCode=$($result.ExitCode) file=$ScriptPath output=$($result.OutputText)"
    }

    return $result
}

function Get-ExistingHeadlessDrillPayload {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$InitialTargetId,
        [Parameter(Mandatory)][int]$MaxForwardCount,
        [Parameter(Mandatory)][int]$RunDurationSec
    )

    $statusInvocation = Invoke-RequiredScript -ScriptPath (Join-Path $Root 'show-paired-exchange-status.ps1') -Parameters @{
        ConfigPath = $ConfigPath
        RunRoot = $RunRoot
        AsJson = $true
    }
    $pairedStatus = $statusInvocation.OutputText | ConvertFrom-Json
    $observedCounts = [pscustomobject]@{
        DonePresentCount = [int]$pairedStatus.Counts.DonePresentCount
        ErrorPresentCount = [int]$pairedStatus.Counts.ErrorPresentCount
        ForwardedStateCount = [int]$pairedStatus.Counts.ForwardedStateCount
        WatcherStatus = [string]$pairedStatus.Watcher.Status
    }

    if ($observedCounts.ErrorPresentCount -gt 0 -or $observedCounts.DonePresentCount -lt 2 -or $observedCounts.ForwardedStateCount -lt $MaxForwardCount) {
        throw ("existing run root does not satisfy headless closure criteria runRoot={0} done={1} error={2} forwarded={3} watcher={4}" -f `
            $RunRoot,
            $observedCounts.DonePresentCount,
            $observedCounts.ErrorPresentCount,
            $observedCounts.ForwardedStateCount,
            $observedCounts.WatcherStatus)
    }

    return [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('o')
        ConfigPath = $ConfigPath
        PairId = $PairId
        InitialTargetId = $InitialTargetId
        RunRoot = $RunRoot
        MaxForwardCount = $MaxForwardCount
        RunDurationSec = $RunDurationSec
        ReusedExistingRunRoot = $true
        SuccessCriteria = [pscustomobject]@{
            RequiredDonePresentCount = 2
            RequiredForwardedStateCount = $MaxForwardCount
            RequiredErrorPresentCount = 0
        }
        ObservedCounts = $observedCounts
        PairedStatus = $pairedStatus
    }
}

function New-StepResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Invocation,
        [string]$Summary = ''
    )

    return [pscustomobject]@{
        Name = $Name
        ScriptPath = [string]$Invocation.ScriptPath
        ExitCode = [int]$Invocation.ExitCode
        Succeeded = [bool]$Invocation.Succeeded
        Summary = [string]$Summary
        OutputText = [string]$Invocation.OutputText
    }
}

$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$steps = @()

$drillSummary = ''
if ($ReuseExistingRunRoot) {
    if (-not (Test-NonEmptyString $RunRoot)) {
        throw 'ReuseExistingRunRoot를 사용할 때는 RunRoot가 필요합니다.'
    }
    $resolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
    $drillPayload = Get-ExistingHeadlessDrillPayload -Root $root -ConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -PairId $PairId -InitialTargetId $InitialTargetId -MaxForwardCount $MaxForwardCount -RunDurationSec $RunDurationSec
    $drillSummary = "reused runRoot=$resolvedRunRoot forwarded=$([string]$drillPayload.ObservedCounts.ForwardedStateCount) done=$([string]$drillPayload.ObservedCounts.DonePresentCount) error=$([string]$drillPayload.ObservedCounts.ErrorPresentCount)"
    $steps += [pscustomobject]@{
        Name = 'headless-pair-drill'
        ScriptPath = (Join-Path $root 'show-paired-exchange-status.ps1')
        ExitCode = 0
        Succeeded = $true
        Summary = $drillSummary
        OutputText = ''
    }
}
else {
    $drillParams = @{
        ConfigPath = $resolvedConfigPath
        PairId = $PairId
        InitialTargetId = $InitialTargetId
        MaxForwardCount = $MaxForwardCount
        RunDurationSec = $RunDurationSec
        AsJson = $true
    }
    if (Test-NonEmptyString $RunRoot) {
        $drillParams.RunRoot = $RunRoot
    }

    $drillInvocation = Invoke-RequiredScript -ScriptPath (Join-Path $root 'run-headless-pair-drill.ps1') -Parameters $drillParams
    $drillPayload = $drillInvocation.OutputText | ConvertFrom-Json
    $drillSummary = "runRoot=$([string]$drillPayload.RunRoot) forwarded=$([string]$drillPayload.ObservedCounts.ForwardedStateCount) done=$([string]$drillPayload.ObservedCounts.DonePresentCount) error=$([string]$drillPayload.ObservedCounts.ErrorPresentCount)"
    $steps += (New-StepResult -Name 'headless-pair-drill' -Invocation $drillInvocation -Summary $drillSummary)
}

$routerPositive = Invoke-RequiredScript -ScriptPath (Join-Path $root 'tests\Test-RouterProcessValidPairTransport.ps1') -Parameters @{}
$steps += (New-StepResult -Name 'router-valid-pair-transport' -Invocation $routerPositive -Summary 'valid pair transport ready file processed successfully')

$routerNegative = Invoke-RequiredScript -ScriptPath (Join-Path $root 'tests\Test-RouterRequirePairTransportMetadata.ps1') -Parameters @{}
$steps += (New-StepResult -Name 'router-rejects-missing-pair-metadata' -Invocation $routerNegative -Summary 'invalid pair transport metadata moved to ignored')

$producerNegative = Invoke-RequiredScript -ScriptPath (Join-Path $root 'tests\Test-ProducerRequirePairSourceMetadataForTextFile.ps1') -Parameters @{}
$steps += (New-StepResult -Name 'producer-rejects-missing-source-metadata' -Invocation $producerNegative -Summary 'TextFilePath pair metadata is enforced before ready creation')

$seedContract = Invoke-RequiredScript -ScriptPath (Join-Path $root 'tests\Test-SendInitialPairSeed.ps1') -Parameters @{}
$steps += (New-StepResult -Name 'seed-single-target-contract' -Invocation $seedContract -Summary 'initial seed queues only the configured seed target with pair metadata')

$payload = [pscustomobject][ordered]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = (Get-Date).ToString('o')
    Overall = 'success'
    ConfigPath = $resolvedConfigPath
    PairId = $PairId
    InitialTargetId = $InitialTargetId
    RunRoot = [string]$drillPayload.RunRoot
    HeadlessDrill = $drillPayload
    Steps = @($steps)
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
    return
}

Write-Host ("overall=success pair={0} runRoot={1}" -f $PairId, [string]$drillPayload.RunRoot)
foreach ($step in $steps) {
    Write-Host ("- {0}: {1}" -f [string]$step.Name, [string]$step.Summary)
}
