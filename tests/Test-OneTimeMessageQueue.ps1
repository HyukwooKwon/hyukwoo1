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
$pairId = ('pair-contract-' + (Get-Date -Format 'yyyyMMddHHmmssfff'))

$enqueue = Invoke-ScriptJson -Root $root -ScriptName 'enqueue-one-time-message.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-Role', 'top',
    '-TargetId', 'target01',
    '-AppliesTo', 'handoff',
    '-Placement', 'one-time-prefix',
    '-Text', '테스트용 1회성 문구',
    '-AsJson'
)

Assert-True ($enqueue.SchemaVersion -eq '1.0.0') 'Queue enqueue schema mismatch.'
Assert-True (Test-Path -LiteralPath ([string]$enqueue.QueuePath)) 'Queue file should exist.'
Assert-True ([string]$enqueue.Item.State -eq 'queued') 'Expected queued state.'

$shown = Invoke-ScriptJson -Root $root -ScriptName 'show-one-time-message-queue.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-AsJson'
)

Assert-True ($shown.SchemaVersion -eq '1.0.0') 'Queue show schema mismatch.'
Assert-True (@($shown.Items).Count -eq 1) 'Expected one queue item.'
Assert-True ([string]$shown.Items[0].Placement -eq 'one-time-prefix') 'Expected placement one-time-prefix.'
Assert-True ([string]$shown.Items[0].Scope.Role -eq 'top') 'Expected role scope top.'
Assert-True ([string]$shown.Items[0].Scope.AppliesTo -eq 'handoff') 'Expected applies_to handoff.'

$consumeEnqueue = Invoke-ScriptJson -Root $root -ScriptName 'enqueue-one-time-message.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-Role', 'top',
    '-TargetId', 'target01',
    '-AppliesTo', 'initial',
    '-Placement', 'one-time-suffix',
    '-Text', 'manual consume test',
    '-AsJson'
)

$consumed = Invoke-ScriptJson -Root $root -ScriptName 'consume-one-time-message.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-ItemId', [string]$consumeEnqueue.Item.Id,
    '-AsJson'
)

Assert-True ($consumed.ConsumedCount -eq 1) 'Expected one consumed item.'
Assert-True (@($consumed.ArchivePaths).Count -eq 1) 'Expected one consumed archive path.'
Assert-True (Test-Path -LiteralPath ([string]$consumed.ArchivePaths[0])) 'Expected consumed archive file.'

$expiredEnqueue = Invoke-ScriptJson -Root $root -ScriptName 'enqueue-one-time-message.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-Role', 'bottom',
    '-TargetId', 'target05',
    '-AppliesTo', 'initial',
    '-Placement', 'one-time-suffix',
    '-Text', '만료 테스트 문구',
    '-ExpiresAt', ([datetimeoffset]::Now.AddMinutes(-5).ToString('o')),
    '-AsJson'
)

Assert-True ([string]$expiredEnqueue.Item.State -eq 'queued') 'Expected queued state for expired item before effective-state evaluation.'

$cancelled = Invoke-ScriptJson -Root $root -ScriptName 'cancel-one-time-message.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-ItemId', [string]$enqueue.Item.Id,
    '-AsJson'
)

Assert-True (Test-Path -LiteralPath ([string]$cancelled.ArchivePath)) 'Expected cancel archive file.'

$cancelledView = Invoke-ScriptJson -Root $root -ScriptName 'show-one-time-message-queue.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-State', 'cancelled',
    '-AsJson'
)

Assert-True (@($cancelledView.Items).Count -eq 1) 'Expected one cancelled item.'
Assert-True ([string]$cancelledView.Items[0].State -eq 'cancelled') 'Expected cancelled effective state.'

$expiredView = Invoke-ScriptJson -Root $root -ScriptName 'show-one-time-message-queue.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-State', 'expired',
    '-AsJson'
)

Assert-True (@($expiredView.Items).Count -eq 1) 'Expected one expired item.'
Assert-True ([string]$expiredView.Items[0].State -eq 'expired') 'Expected expired effective state.'

$cleanup = Invoke-ScriptJson -Root $root -ScriptName 'cleanup-one-time-message-queue.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-State', 'all',
    '-AsJson'
)

Assert-True ($cleanup.RemovedCount -eq 2) 'Expected two removed queue items.'
Assert-True (@($cleanup.ArchivePaths).Count -eq 2) 'Expected two cleanup archive files.'
Assert-True ($cleanup.QueueSummary.ItemCount -eq 0) 'Expected empty queue after cleanup.'

$postCleanup = Invoke-ScriptJson -Root $root -ScriptName 'show-one-time-message-queue.ps1' -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-PairId', $pairId,
    '-AsJson'
)

Assert-True (@($postCleanup.Items).Count -eq 0) 'Expected empty queue view after cleanup.'

Write-Host ('one-time-message-queue contract ok: pair=' + $pairId)
