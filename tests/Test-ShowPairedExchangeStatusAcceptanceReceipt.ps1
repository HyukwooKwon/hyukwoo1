[CmdletBinding()]
param()

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

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-ShowPairedExchangeStatusAcceptanceReceipt'
$runRoot = Join-Path $tmpRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$stateRoot = Join-Path $runRoot '.state'
$receiptPath = Join-Path $stateRoot 'live-acceptance-result.json'

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

$receipt = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    RunRoot = $runRoot
    PairId = 'pair01'
    SeedTargetId = 'target01'
    PartnerTargetId = 'target05'
    Outcome = [pscustomobject]@{
        AcceptanceState = 'manual_attention_required'
        AcceptanceReason = 'user_active_hold'
        Diagnostics = [pscustomobject]@{
            Seed = [pscustomobject]@{
                TargetId = 'target01'
                SeedAttemptCount = 3
                SeedMaxAttempts = 3
                SeedRetryReason = 'user_active_hold'
            }
            Partner = [pscustomobject]@{
                TargetId = 'target05'
                LatestState = 'no-zip'
            }
        }
    }
}
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8

$statusRaw = & (Resolve-Path (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1')).Path `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$status = $statusRaw | ConvertFrom-Json

Assert-True ([bool]$status.AcceptanceReceipt.Exists) 'status should report acceptance receipt exists.'
Assert-True ([string]$status.AcceptanceReceipt.Path -eq $receiptPath) 'status should surface receipt path.'
Assert-True ([string]$status.AcceptanceReceipt.AcceptanceState -eq 'manual_attention_required') 'status should surface receipt acceptance state.'
Assert-True ([string]$status.AcceptanceReceipt.AcceptanceReason -eq 'user_active_hold') 'status should surface receipt acceptance reason.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$status.AcceptanceReceipt.GeneratedAt)) 'status should surface receipt generated at.'

Write-Host ('show paired exchange status acceptance receipt ok: runRoot=' + $runRoot)
