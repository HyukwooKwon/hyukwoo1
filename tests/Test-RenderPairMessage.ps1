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

    $result = if ($Condition -is [System.Array]) {
        ($Condition.Count -gt 0)
    }
    else {
        [bool]$Condition
    }

    if (-not $result) {
        throw $Message
    }
}

function Invoke-RenderPairMessage {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'render-pair-message.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $RunRoot,
        '-PairId', $PairId,
        '-TargetId', $TargetId,
        '-Mode', $Mode,
        '-OutputRoot', $OutputRoot,
        '-WriteOutputs',
        '-AsJson'
    )

    $powershellPath = (Get-Command -Name 'powershell.exe' -ErrorAction Stop | Select-Object -First 1).Source
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("render-pair-message failed: " + (($result | Out-String).Trim()))
    }

    return ($result | ConvertFrom-Json)
}

function Invoke-ScriptJson {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $powershellPath = (Get-Command -Name 'powershell.exe' -ErrorAction Stop | Select-Object -First 1).Source
    $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' (Join-Path $Root $ScriptName) @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw (($result | Out-String).Trim())
    }

    return ($result | ConvertFrom-Json)
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_render_message_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$outputRoot = Join-Path $root ('_tmp\render-pair-message\pair01_target01_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$queuePath = Join-Path $root ('runtime\one-time-queue\' + [string]$config.LaneName + '\pair01.queue.json')
$queueBackup = if (Test-Path -LiteralPath $queuePath) { ($queuePath + '.bak_test_' + (Get-Date -Format 'yyyyMMddHHmmssfff')) } else { '' }

if ($queueBackup) {
    Copy-Item -LiteralPath $queuePath -Destination $queueBackup -Force
}

try {
    if (Test-Path -LiteralPath $queuePath) {
        Remove-Item -LiteralPath $queuePath -Force
    }

    $queueItem = Invoke-ScriptJson -Root $root -ScriptName 'enqueue-one-time-message.ps1' -Arguments @(
        '-ConfigPath', $resolvedConfigPath,
        '-PairId', 'pair01',
        '-Role', 'top',
        '-TargetId', 'target01',
        '-AppliesTo', 'handoff',
        '-Placement', 'one-time-prefix',
        '-Text', '테스트용 1회성 handoff 지시문',
        '-AsJson'
    )

    & (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -IncludePairId pair01 | Out-Null

    $both = Invoke-RenderPairMessage `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -PairId 'pair01' `
        -TargetId 'target01' `
        -Mode 'both' `
        -OutputRoot $outputRoot

    Assert-True ($both.SchemaVersion -eq '1.0.0') 'SchemaVersion mismatch.'
    Assert-True (@($both.Messages).Count -eq 2) 'Expected both initial and handoff outputs.'
    Assert-True ((Test-Path -LiteralPath (Join-Path $outputRoot 'initial.envelope.json'))) 'Expected initial envelope json file.'
    Assert-True ((Test-Path -LiteralPath (Join-Path $outputRoot 'initial.rendered.txt'))) 'Expected initial rendered txt file.'
    Assert-True ((Test-Path -LiteralPath (Join-Path $outputRoot 'handoff.envelope.json'))) 'Expected handoff envelope json file.'
    Assert-True ((Test-Path -LiteralPath (Join-Path $outputRoot 'handoff.rendered.txt'))) 'Expected handoff rendered txt file.'
    Assert-True ($both.Messages[0].Envelope.PSObject.Properties['MessagePlan'] -ne $null) 'Expected MessagePlan in envelope.'
    Assert-True (@($both.Messages[0].Envelope.MessagePlan.Order).Count -gt 0) 'Expected MessagePlan.Order values in envelope.'
    Assert-True ($both.Messages[0].Envelope.PSObject.Properties['ConfiguredPaths'] -ne $null) 'Expected ConfiguredPaths in envelope.'
    Assert-True ($both.Messages[0].Envelope.PSObject.Properties['PathState'] -ne $null) 'Expected PathState in envelope.'
    Assert-True ($both.Messages[0].Envelope.PSObject.Properties['OneTimeItems'] -ne $null) 'Expected OneTimeItems in envelope.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$both.Messages[0].Envelope.RenderedText)) 'Expected rendered text in envelope.'
    $handoffEnvelope = @($both.Messages | Where-Object { [string]$_.MessageType -eq 'handoff' })[0].Envelope
    Assert-True (@($handoffEnvelope.OneTimeItems).Count -eq 1) 'Expected one matching handoff one-time item.'
    Assert-True ([string]$handoffEnvelope.OneTimeItems[0].Id -eq [string]$queueItem.Item.Id) 'Expected queue item id in handoff envelope.'
    Assert-True ([string]$handoffEnvelope.RenderedText -match '테스트용 1회성 handoff 지시문') 'Expected one-time text in handoff rendered text.'

    $initialOnlyOutputRoot = Join-Path $root ('_tmp\render-pair-message\pair01_target05_initial_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $initial = Invoke-RenderPairMessage `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -PairId 'pair01' `
        -TargetId 'target05' `
        -Mode 'initial' `
        -OutputRoot $initialOnlyOutputRoot

    Assert-True (@($initial.Messages).Count -eq 1) 'Expected one initial output.'
    Assert-True ([string]$initial.Messages[0].MessageType -eq 'initial') 'Expected initial message type.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $initialOnlyOutputRoot 'initial.rendered.txt') -Raw -Encoding UTF8) -match 'paired exchange 테스트용 창') 'Expected Korean initial rendered text.'

    Write-Host ('render-pair-message contract ok: runRoot=' + $contractRunRoot)
}
finally {
    if ($queueBackup) {
        Move-Item -LiteralPath $queueBackup -Destination $queuePath -Force
    }
    elseif (Test-Path -LiteralPath $queuePath) {
        Remove-Item -LiteralPath $queuePath -Force
    }
}
