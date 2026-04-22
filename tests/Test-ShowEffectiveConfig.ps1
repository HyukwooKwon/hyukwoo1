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

function Invoke-ShowEffectiveConfig {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [string]$RunRoot,
        [string]$PairId = '',
        [string]$TargetId = '',
        [ValidateSet('both', 'initial', 'handoff')][string]$Mode = 'both',
        [int]$StaleRunThresholdSec = 1800
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'show-effective-config.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-Mode', $Mode,
        '-StaleRunThresholdSec', [string]$StaleRunThresholdSec,
        '-AsJson'
    )
    if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
        $arguments += @('-RunRoot', $RunRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($PairId)) {
        $arguments += @('-PairId', $PairId)
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetId)) {
        $arguments += @('-TargetId', $TargetId)
    }

    $powershellPath = (Get-Command -Name 'powershell.exe' -ErrorAction Stop | Select-Object -First 1).Source
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("show-effective-config failed: " + (($result | Out-String).Trim()))
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
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_show_effective_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$previewOnlyRunRoot = Join-Path $root ('_tmp\show-effective-config\requested_no_manifest_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $previewOnlyRunRoot -Force | Out-Null

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$requestedPreview = Invoke-ShowEffectiveConfig `
    -Root $root `
    -ResolvedConfigPath $resolvedConfigPath `
    -RunRoot $previewOnlyRunRoot `
    -PairId 'pair01' `
    -Mode 'both'

Assert-True ($requestedPreview.SchemaVersion -eq '1.0.0') 'SchemaVersion mismatch.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$requestedPreview.GeneratedAt)) 'GeneratedAt missing.'
Assert-True ($requestedPreview.PairDefinitionSource -eq 'fallback') 'Expected fallback pair definition for preview-only run root.'
Assert-True ($requestedPreview.RunContext.SelectedRunRootSource -eq 'requested') 'Expected requested run root source.'
Assert-True ($requestedPreview.RunContext.ManifestExists -eq $false) 'Expected manifest missing for preview-only run root.'
Assert-True (@($requestedPreview.Warnings).Count -ge 1) 'Expected warnings for preview-only run root.'
Assert-True (@($requestedPreview.WarningDetails).Count -ge 1) 'Expected warning detail records for preview-only run root.'
Assert-True ($requestedPreview.WarningDetails[0].PSObject.Properties['Decision'] -ne $null) 'Expected warning decision metadata.'
Assert-True ($requestedPreview.WarningDetails[0].PSObject.Properties['Priority'] -ne $null) 'Expected warning priority metadata.'
Assert-True ($requestedPreview.PSObject.Properties['WarningSummary'] -ne $null) 'Expected WarningSummary property.'
Assert-True ($requestedPreview.PSObject.Properties['EvidencePolicy'] -ne $null) 'Expected EvidencePolicy property.'
Assert-True ($requestedPreview.PSObject.Properties['OperationalPolicy'] -ne $null) 'Expected OperationalPolicy property.'
Assert-True ($requestedPreview.EvidencePolicy.Recommended -eq $false) 'Expected preview-only run root to be not recommended for evidence.'
Assert-True (@($requestedPreview.EvidencePolicy.ReasonCodes).Count -ge 1) 'Expected evidence reason codes for preview-only run root.'
Assert-True (@($requestedPreview.PreviewRows).Count -eq 2) 'Expected 2 preview rows for pair01.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$requestedPreview.Config.ConfigHash)) 'ConfigHash missing.'
Assert-True ([int]$requestedPreview.RequestedFilters.StaleRunThresholdSec -gt 0) 'Expected stale threshold in requested filters.'
Assert-True ([bool]$requestedPreview.RunContext.SelectedRunRootExists -eq $true) 'Expected selected requested run root to exist.'
Assert-True ($requestedPreview.PreviewRows[0].PSObject.Properties['PathState'] -ne $null) 'Expected PathState property for preview rows.'
Assert-True ($requestedPreview.PreviewRows[0].Initial.PSObject.Properties['MessagePlan'] -ne $null) 'Expected Initial.MessagePlan property.'
Assert-True (@($requestedPreview.PreviewRows[0].Initial.MessagePlan.Blocks).Count -gt 0) 'Expected Initial.MessagePlan blocks.'
Assert-True ($requestedPreview.PreviewRows[0].Initial.PSObject.Properties['SlotOrder'] -ne $null) 'Expected Initial.SlotOrder property.'
Assert-True ($requestedPreview.PreviewRows[0].Initial.PSObject.Properties['PendingOneTimeItems'] -ne $null) 'Expected Initial.PendingOneTimeItems property.'
Assert-True ($requestedPreview.PSObject.Properties['OneTimeQueueSummary'] -ne $null) 'Expected OneTimeQueueSummary property.'
Assert-True ($requestedPreview.PSObject.Properties['PairActivationSummary'] -ne $null) 'Expected PairActivationSummary property.'
Assert-True (@($requestedPreview.PairActivationSummary).Count -ge 1) 'Expected pair activation rows.'
Assert-True (($requestedPreview.PairActivationSummary | Select-Object -First 1).PSObject.Properties['EffectiveEnabled'] -ne $null) 'Expected pair activation effective enabled field.'

$contractBoth = Invoke-ShowEffectiveConfig `
    -Root $root `
    -ResolvedConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -PairId 'pair01' `
    -Mode 'both'

Assert-True ($contractBoth.PairDefinitionSource -eq 'manifest') 'Expected manifest pair definition for prepared run root.'
Assert-True ($contractBoth.RunContext.SelectedRunRootSource -eq 'requested') 'Expected requested run root source for prepared run.'
Assert-True ($contractBoth.RunContext.ManifestExists -eq $true) 'Expected manifest for prepared run.'
Assert-True (@($contractBoth.OverviewPairs).Count -eq 1) 'Expected 1 overview pair for pair01.'
Assert-True (@($contractBoth.PreviewRows).Count -eq 2) 'Expected 2 preview rows for pair01.'
Assert-True ($null -ne $contractBoth.PreviewRows[0].Initial) 'Expected Initial block in both mode.'
Assert-True ($null -ne $contractBoth.PreviewRows[0].Handoff) 'Expected Handoff block in both mode.'
Assert-True ($contractBoth.PreviewRows[0].Handoff.PSObject.Properties['MessagePlan'] -ne $null) 'Expected Handoff.MessagePlan property.'
Assert-True ($contractBoth.PreviewRows[0].Handoff.PSObject.Properties['SlotOrder'] -ne $null) 'Expected Handoff.SlotOrder property.'
Assert-True ($contractBoth.PreviewRows[0].PathState.PairTargetFolder.PSObject.Properties['Exists'] -ne $null) 'Expected PathState.PairTargetFolder.Exists.'
Assert-True ($contractBoth.PreviewRows[0].Handoff.PSObject.Properties['PendingOneTimeItems'] -ne $null) 'Expected Handoff.PendingOneTimeItems property.'
Assert-True (@($contractBoth.OneTimeQueueSummary).Count -eq 1) 'Expected one one-time queue summary row for pair01.'
Assert-True ($contractBoth.PreviewRows[0].PSObject.Properties['PairActivation'] -ne $null) 'Expected PairActivation on preview row.'
Assert-True ($contractBoth.PreviewRows[0].PairActivation.EffectiveEnabled -eq $true) 'Expected pair01 to be enabled by default.'
Assert-True ($contractBoth.PSObject.Properties['WarningDetails'] -ne $null) 'Expected WarningDetails property in both mode.'
Assert-True ($contractBoth.EvidencePolicy.Recommended -eq $true) 'Expected prepared manifest-backed run root to be evidence-recommended.'
Assert-True (@($contractBoth.EvidencePolicy.ReasonCodes).Count -eq 0) 'Expected no evidence reason codes for prepared manifest-backed run root.'

$contractInitial = Invoke-ShowEffectiveConfig `
    -Root $root `
    -ResolvedConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -PairId 'pair01' `
    -TargetId 'target01' `
    -Mode 'initial'

Assert-True (@($contractInitial.PreviewRows).Count -eq 1) 'Expected 1 preview row for target01 initial mode.'
Assert-True ($contractInitial.PreviewRows[0].PSObject.Properties['Initial'] -ne $null) 'Expected Initial property in initial mode.'
Assert-True ($contractInitial.PreviewRows[0].PSObject.Properties['Handoff'] -eq $null) 'Did not expect Handoff property in initial mode.'

$contractHandoff = Invoke-ShowEffectiveConfig `
    -Root $root `
    -ResolvedConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -PairId 'pair01' `
    -TargetId 'target05' `
    -Mode 'handoff'

Assert-True (@($contractHandoff.PreviewRows).Count -eq 1) 'Expected 1 preview row for target05 handoff mode.'
Assert-True ($contractHandoff.PreviewRows[0].PSObject.Properties['Handoff'] -ne $null) 'Expected Handoff property in handoff mode.'
Assert-True ($contractHandoff.PreviewRows[0].PSObject.Properties['Initial'] -eq $null) 'Did not expect Initial property in handoff mode.'

$latestExisting = Invoke-ShowEffectiveConfig `
    -Root $root `
    -ResolvedConfigPath $resolvedConfigPath `
    -PairId 'pair01' `
    -Mode 'both'

Assert-True ($latestExisting.RunContext.SelectedRunRootSource -eq 'latest-existing') 'Expected latest-existing run root source when RunRoot is omitted.'
Assert-True (Test-Path -LiteralPath ([string]$latestExisting.RunContext.SelectedRunRoot)) 'Expected latest-existing run root to exist.'
Assert-True ([bool]$latestExisting.RunContext.ManifestExists -eq $true) 'Expected latest-existing run root to have manifest.'
Assert-True ($latestExisting.RunContext.SelectedRunRootAgeSeconds -ge 0) 'Expected selected run root age seconds.'
Assert-True ($latestExisting.RunContext.StaleRunThresholdSec -gt 0) 'Expected stale threshold in run context.'

$forcedStale = Invoke-ShowEffectiveConfig `
    -Root $root `
    -ResolvedConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -PairId 'pair01' `
    -Mode 'both' `
    -StaleRunThresholdSec 0

Assert-True ($forcedStale.RunContext.SelectedRunRootIsStale -eq $true) 'Expected forced stale run root.'
Assert-True ('runroot-stale' -in @($forcedStale.WarningSummary.OrderedCodes)) 'Expected runroot-stale warning code.'
Assert-True ($forcedStale.EvidencePolicy.Recommended -eq $false) 'Expected stale run root to be not recommended for evidence.'

Write-Host ('show-effective-config contract ok: runRoot=' + $contractRunRoot)
