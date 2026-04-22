[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$PairId = 'pair01',
    [string]$SeedTargetId = 'target01',
    [int]$RecentRelayCount = 5,
    [switch]$RequireVisibleReceipt,
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

function Invoke-JsonScript {
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
    $outputText = ($lines -join [Environment]::NewLine)
    if ($exitCode -ne 0) {
        throw "스크립트 실행 실패 exitCode=$exitCode file=$ScriptPath output=$outputText"
    }

    return ($outputText | ConvertFrom-Json)
}

function Get-PairDefinition {
    param([Parameter(Mandatory)][string]$PairId)

    $pairs = @{
        pair01 = [pscustomobject]@{ PairId = 'pair01'; TopTargetId = 'target01'; BottomTargetId = 'target05' }
        pair02 = [pscustomobject]@{ PairId = 'pair02'; TopTargetId = 'target02'; BottomTargetId = 'target06' }
        pair03 = [pscustomobject]@{ PairId = 'pair03'; TopTargetId = 'target03'; BottomTargetId = 'target07' }
        pair04 = [pscustomobject]@{ PairId = 'pair04'; TopTargetId = 'target04'; BottomTargetId = 'target08' }
    }

    if (-not $pairs.ContainsKey($PairId)) {
        throw "알 수 없는 pair id입니다: $PairId"
    }

    return $pairs[$PairId]
}

function New-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][bool]$Required,
        [string]$Summary = '',
        [string]$Detail = ''
    )

    return [pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Required = $Required
        Summary = $Summary
        Detail = $Detail
    }
}

$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}
if (-not (Test-NonEmptyString $RunRoot)) {
    throw 'RunRoot가 필요합니다.'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$resolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$pairDefinition = Get-PairDefinition -PairId $PairId
$partnerTargetId = if ([string]$SeedTargetId -eq [string]$pairDefinition.TopTargetId) {
    [string]$pairDefinition.BottomTargetId
}
elseif ([string]$SeedTargetId -eq [string]$pairDefinition.BottomTargetId) {
    [string]$pairDefinition.TopTargetId
}
else {
    throw "seed target does not belong to pair: seed=$SeedTargetId pair=$PairId"
}

$pairedStatus = Invoke-JsonScript -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -Parameters @{
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    AsJson = $true
}
$relayStatus = Invoke-JsonScript -ScriptPath (Join-Path $root 'show-relay-status.ps1') -Parameters @{
    ConfigPath = $resolvedConfigPath
    RecentCount = $RecentRelayCount
    AsJson = $true
}
$runSummary = Invoke-JsonScript -ScriptPath (Join-Path $root 'show-paired-run-summary.ps1') -Parameters @{
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    AsJson = $true
}

$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pairManifestRows = @($manifest.Targets | Where-Object { [string]$_.PairId -eq $PairId })
$seedManifestRow = @($pairManifestRows | Where-Object { [string]$_.TargetId -eq $SeedTargetId } | Select-Object -First 1)
$partnerManifestRow = @($pairManifestRows | Where-Object { [string]$_.TargetId -eq $partnerTargetId } | Select-Object -First 1)
$seedStatusRow = @($pairedStatus.Targets | Where-Object { [string]$_.TargetId -eq $SeedTargetId } | Select-Object -First 1)
$partnerStatusRow = @($pairedStatus.Targets | Where-Object { [string]$_.TargetId -eq $partnerTargetId } | Select-Object -First 1)

$checks = @()
$checks += New-CheckResult -Name 'run-summary-readable' -Passed (Test-NonEmptyString ([string]$runSummary.SummaryLine)) -Required $true -Summary ([string]$runSummary.SummaryLine) -Detail ''
$checks += New-CheckResult -Name 'run-summary-success' -Passed ([string]$runSummary.OverallState -eq 'success') -Required ([bool]$RequireVisibleReceipt) -Summary ("overall={0}" -f [string]$runSummary.OverallState) -Detail ([string]$runSummary.SummaryLine)
$checks += New-CheckResult -Name 'pair-manifest-shape' -Passed (@($pairManifestRows).Count -eq 2 -and [int]$pairedStatus.Manifest.TargetCount -eq 2 -and [int]$pairedStatus.Manifest.PairCount -eq 1) -Required $true -Summary ("manifestTargets={0} manifestPairs={1}" -f [int]$pairedStatus.Manifest.TargetCount, [int]$pairedStatus.Manifest.PairCount) -Detail ("pairRows={0}" -f @($pairManifestRows).Count)
$checks += New-CheckResult -Name 'seed-target-role-contract' -Passed (@($seedManifestRow).Count -eq 1 -and [string]$seedManifestRow[0].InitialRoleMode -eq 'seed' -and [bool]$seedManifestRow[0].SeedEnabled) -Required $true -Summary ("seedInitialRoleMode={0}" -f $(if (@($seedManifestRow).Count -eq 1) { [string]$seedManifestRow[0].InitialRoleMode } else { '' })) -Detail ("seedEnabled={0}" -f $(if (@($seedManifestRow).Count -eq 1) { [bool]$seedManifestRow[0].SeedEnabled } else { $false }))
$checks += New-CheckResult -Name 'partner-target-role-contract' -Passed (@($partnerManifestRow).Count -eq 1 -and [string]$partnerManifestRow[0].InitialRoleMode -eq 'handoff_wait' -and -not [bool]$partnerManifestRow[0].SeedEnabled) -Required $true -Summary ("partnerInitialRoleMode={0}" -f $(if (@($partnerManifestRow).Count -eq 1) { [string]$partnerManifestRow[0].InitialRoleMode } else { '' })) -Detail ("seedEnabled={0}" -f $(if (@($partnerManifestRow).Count -eq 1) { [bool]$partnerManifestRow[0].SeedEnabled } else { $false }))
$checks += New-CheckResult -Name 'pair-status-rows-present' -Passed (@($seedStatusRow).Count -eq 1 -and @($partnerStatusRow).Count -eq 1) -Required $true -Summary ("seedRow={0} partnerRow={1}" -f @($seedStatusRow).Count, @($partnerStatusRow).Count) -Detail ("seed={0} partner={1}" -f $SeedTargetId, $partnerTargetId)
$checks += New-CheckResult -Name 'pair-roundtrip-closed' -Passed ([int]$pairedStatus.Counts.DonePresentCount -ge 2 -and [int]$pairedStatus.Counts.ErrorPresentCount -eq 0 -and [int]$pairedStatus.Counts.ForwardedStateCount -ge 2) -Required $true -Summary ("done={0} error={1} forwarded={2}" -f [int]$pairedStatus.Counts.DonePresentCount, [int]$pairedStatus.Counts.ErrorPresentCount, [int]$pairedStatus.Counts.ForwardedStateCount) -Detail ''
$checks += New-CheckResult -Name 'source-outbox-imported' -Passed ([int]$pairedStatus.Counts.SourceOutboxImportedCount -ge 2 -and [int]$pairedStatus.Counts.HandoffReadyCount -ge 2) -Required $true -Summary ("imported={0} handoffReady={1}" -f [int]$pairedStatus.Counts.SourceOutboxImportedCount, [int]$pairedStatus.Counts.HandoffReadyCount) -Detail ''
$checks += New-CheckResult -Name 'dispatch-clean' -Passed ([int]$pairedStatus.Counts.DispatchRunningCount -eq 0 -and [int]$pairedStatus.Counts.DispatchFailedCount -eq 0) -Required $true -Summary ("running={0} failed={1}" -f [int]$pairedStatus.Counts.DispatchRunningCount, [int]$pairedStatus.Counts.DispatchFailedCount) -Detail ''
$checks += New-CheckResult -Name 'router-metadata-contract' -Passed ([bool]$relayStatus.Router.RequireReadyDeliveryMetadata -and [bool]$relayStatus.Router.RequirePairTransportMetadata) -Required $true -Summary ("ready={0} pair={1}" -f [bool]$relayStatus.Router.RequireReadyDeliveryMetadata, [bool]$relayStatus.Router.RequirePairTransportMetadata) -Detail ''
$checks += New-CheckResult -Name 'router-preexisting-policy' -Passed ([bool]$relayStatus.Router.IgnorePreexistingReadyFiles -and [string]$relayStatus.Router.PreexistingHandlingMode -eq 'ignore-archive') -Required $true -Summary ("ignorePreexisting={0} mode={1}" -f [bool]$relayStatus.Router.IgnorePreexistingReadyFiles, [string]$relayStatus.Router.PreexistingHandlingMode) -Detail ("startupCutoffAt={0}" -f [string]$relayStatus.Router.StartupCutoffAt)
$checks += New-CheckResult -Name 'watcher-terminal-state' -Passed ([string]$pairedStatus.Watcher.Status -eq 'stopped' -and [string]$pairedStatus.Watcher.StopCategory -in @('manual-stop', 'expected-limit') -and [int]$pairedStatus.Watcher.ForwardedCount -ge 2) -Required $true -Summary ("status={0} stopCategory={1}" -f [string]$pairedStatus.Watcher.Status, [string]$pairedStatus.Watcher.StopCategory) -Detail ("forwardedCount={0}" -f [int]$pairedStatus.Watcher.ForwardedCount)

$receiptPassed = [bool]$pairedStatus.AcceptanceReceipt.Exists -and [string]$pairedStatus.AcceptanceReceipt.AcceptanceState -eq 'roundtrip-confirmed' -and [string]$runSummary.Acceptance.Stage -eq 'completed' -and [bool]$runSummary.Acceptance.SeedOutboxPublished
$checks += New-CheckResult -Name 'visible-receipt-roundtrip' -Passed $receiptPassed -Required ([bool]$RequireVisibleReceipt) -Summary ("receiptExists={0} acceptance={1} stage={2}" -f [bool]$pairedStatus.AcceptanceReceipt.Exists, [string]$pairedStatus.AcceptanceReceipt.AcceptanceState, [string]$runSummary.Acceptance.Stage) -Detail ("seedFinal={0} seedSubmit={1} outboxPublished={2}" -f [string]$runSummary.Acceptance.SeedFinalState, [string]$runSummary.Acceptance.SeedSubmitState, [bool]$runSummary.Acceptance.SeedOutboxPublished)

$failedRequiredChecks = @($checks | Where-Object { $_.Required -and -not $_.Passed })
$overall = if (@($failedRequiredChecks).Count -eq 0) { 'success' } else { 'failing' }
$mode = if ($RequireVisibleReceipt) { 'shared-visible-receipt-required' } else { 'passive-runroot-verification' }

$payload = [pscustomobject][ordered]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = (Get-Date).ToString('o')
    Mode = $mode
    Overall = $overall
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    PairId = $PairId
    SeedTargetId = $SeedTargetId
    PartnerTargetId = $partnerTargetId
    SummaryLine = [string]$runSummary.SummaryLine
    Summary = $runSummary
    PairedStatus = [pscustomobject]@{
        Watcher = $pairedStatus.Watcher
        Counts = $pairedStatus.Counts
        AcceptanceReceipt = $pairedStatus.AcceptanceReceipt
        Targets = @($pairedStatus.Targets)
    }
    Relay = [pscustomobject]@{
        Router = $relayStatus.Router
        Counts = $relayStatus.Counts
        IgnoredReasonCounts = @($relayStatus.IgnoredReasonCounts)
    }
    Manifest = [pscustomobject]@{
        Path = $manifestPath
        PairTargets = @($pairManifestRows | Select-Object PairId, TargetId, RoleName, PartnerTargetId, InitialRoleMode, SeedEnabled)
    }
    Checks = @($checks)
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
}
else {
    Write-Host ("overall={0} mode={1} pair={2} runRoot={3}" -f $overall, $mode, $PairId, $resolvedRunRoot)
    Write-Host ("summary: {0}" -f [string]$runSummary.SummaryLine)
    foreach ($check in $checks) {
        $state = if ($check.Passed) { 'PASS' } else { 'FAIL' }
        $requiredLabel = if ($check.Required) { 'required' } else { 'optional' }
        Write-Host ("- [{0}] {1} ({2}) {3}" -f $state, [string]$check.Name, $requiredLabel, [string]$check.Summary)
        if (Test-NonEmptyString ([string]$check.Detail)) {
            Write-Host ("  {0}" -f [string]$check.Detail)
        }
    }
}

if (@($failedRequiredChecks).Count -gt 0) {
    exit 1
}
