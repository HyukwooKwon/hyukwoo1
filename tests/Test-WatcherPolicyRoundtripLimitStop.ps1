[CmdletBinding()]
param(
    [string]$ConfigPath
)

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

function Invoke-ShowPairedStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot
    )

    $powershellPath = Resolve-PowerShellExecutable
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'tests\Show-PairedExchangeStatus.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $RunRoot,
        '-AsJson'
    )
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("show-paired-exchange-status failed: " + (($result | Out-String).Trim()))
    }
    return ($result | ConvertFrom-Json)
}

function Wait-ForWatcherStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][scriptblock]$Predicate,
        [int]$TimeoutSec = 20,
        [int]$PollMs = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastStatus = $null
    while ((Get-Date) -lt $deadline) {
        $lastStatus = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        if (& $Predicate $lastStatus) {
            return $lastStatus
        }
        Start-Sleep -Milliseconds $PollMs
    }

    throw ('watcher status timeout: ' + (($lastStatus | ConvertTo-Json -Depth 8) | Out-String))
}

function Set-ManifestPairPolicyLimit {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$PairId,
        [int]$RoundtripLimit
    )

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $manifest.PairTest.PairPolicies) {
        $manifest.PairTest | Add-Member -MemberType NoteProperty -Name PairPolicies -Value ([pscustomobject]@{})
    }
    if ($null -eq $manifest.PairTest.PairPolicies.PSObject.Properties[$PairId]) {
        $manifest.PairTest.PairPolicies | Add-Member -MemberType NoteProperty -Name $PairId -Value ([pscustomobject]@{})
    }
    $manifest.PairTest.PairPolicies.$PairId | Add-Member -MemberType NoteProperty -Name DefaultPairMaxRoundtripCount -Value $RoundtripLimit -Force

    foreach ($pairRow in @($manifest.Pairs)) {
        if ([string]$pairRow.PairId -ne $PairId) {
            continue
        }
        if ($null -eq $pairRow.Policy) {
            $pairRow | Add-Member -MemberType NoteProperty -Name Policy -Value ([pscustomobject]@{})
        }
        $pairRow.Policy | Add-Member -MemberType NoteProperty -Name DefaultPairMaxRoundtripCount -Value $RoundtripLimit -Force
    }

    foreach ($targetRow in @($manifest.Targets)) {
        if ([string]$targetRow.PairId -ne $PairId) {
            continue
        }
        if ($null -eq $targetRow.PairPolicy) {
            $targetRow | Add-Member -MemberType NoteProperty -Name PairPolicy -Value ([pscustomobject]@{})
        }
        $targetRow.PairPolicy | Add-Member -MemberType NoteProperty -Name DefaultPairMaxRoundtripCount -Value $RoundtripLimit -Force
    }

    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_watcher_policy_limit_stop_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01,pair02 | Out-Null

$manifestPath = Join-Path $contractRunRoot 'manifest.json'
Set-ManifestPairPolicyLimit -ManifestPath $manifestPath -PairId 'pair01' -RoundtripLimit 1
Set-ManifestPairPolicyLimit -ManifestPath $manifestPath -PairId 'pair02' -RoundtripLimit 1

$stateRoot = Join-Path $contractRunRoot '.state'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
}

[ordered]@{
    'target01|policy-stop-01' = (Get-Date).ToString('o')
    'target05|policy-stop-02' = (Get-Date).AddSeconds(1).ToString('o')
    'target02|policy-stop-03' = (Get-Date).AddSeconds(2).ToString('o')
    'target06|policy-stop-04' = (Get-Date).AddSeconds(3).ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stateRoot 'forwarded.json') -Encoding UTF8

$powershellPath = Resolve-PowerShellExecutable
$stdoutLog = Join-Path $root ('_tmp\watcher-policy-limit-stop-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.stdout.log')
$stderrLog = ($stdoutLog + '.stderr')
$watchArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-PollIntervalMs', '250',
    '-MaxForwardCount', '0',
    '-PairMaxRoundtripCount', '0',
    '-RunDurationSec', '20'
)

$process = Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

try {
    $stoppedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            if ([string]$status.Watcher.Status -ne 'stopped' -or [string]$status.Watcher.StatusReason -ne 'pair-roundtrip-limit-reached') {
                return $false
            }
            $pair01 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
            $pair02 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)
            return (
                @($pair01).Count -eq 1 -and
                @($pair02).Count -eq 1 -and
                [string]$pair01[0].CurrentPhase -eq 'limit-reached' -and
                [string]$pair02[0].CurrentPhase -eq 'limit-reached' -and
                [int]$pair01[0].ConfiguredMaxRoundtripCount -eq 1 -and
                [int]$pair02[0].ConfiguredMaxRoundtripCount -eq 1
            )
        }

    $pair01 = @($stoppedStatus.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)[0]
    $pair02 = @($stoppedStatus.Pairs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)[0]
    Assert-True ([string]$stoppedStatus.Watcher.StatusReason -eq 'pair-roundtrip-limit-reached') 'watcher should stop on pair policy roundtrip limit when all limited pairs reach their threshold.'
    Assert-True ([bool]$pair01.ReachedRoundtripLimit) 'pair01 should mark policy roundtrip limit reached.'
    Assert-True ([bool]$pair02.ReachedRoundtripLimit) 'pair02 should mark policy roundtrip limit reached.'
}
finally {
    if ($null -ne $process) {
        [void]$process.WaitForExit(12000)
    }
}

Write-Host ('watcher policy roundtrip limit stop ok: runRoot=' + $contractRunRoot)
