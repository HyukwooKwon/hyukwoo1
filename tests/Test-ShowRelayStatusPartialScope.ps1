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

function Assert-SetEqual {
    param(
        [Parameter(Mandatory)][object[]]$Actual,
        [Parameter(Mandatory)][object[]]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    $actualItems = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $expectedItems = @($Expected | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $difference = @(Compare-Object -ReferenceObject $expectedItems -DifferenceObject $actualItems)
    if ($difference.Count -gt 0 -or $actualItems.Count -ne $expectedItems.Count) {
        throw ($Message + " expected=[" + ($expectedItems -join ', ') + "] actual=[" + ($actualItems -join ', ') + "]")
    }
}

$root = Split-Path -Parent $PSScriptRoot
$powershellPath = (Get-Command -Name 'powershell.exe' -ErrorAction Stop | Select-Object -First 1).Source
$tmpRoot = Join-Path $root ('_tmp\show-relay-status-partial-scope-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$runtimeMapPath = Join-Path $tmpRoot 'runtime-map.json'
$routerStatePath = Join-Path $tmpRoot 'router-state.json'
$bindingProfilePath = Join-Path $tmpRoot 'bindings.json'
$logsRoot = Join-Path $tmpRoot 'logs'
$processedRoot = Join-Path $tmpRoot 'processed'
$failedRoot = Join-Path $tmpRoot 'failed'
$retryPendingRoot = Join-Path $tmpRoot 'retry'
foreach ($path in @($logsRoot, $processedRoot, $failedRoot, $retryPendingRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$targetSpecs = @(
    @{ Id = 'target01'; PairId = 'pair01'; RoleName = 'top' },
    @{ Id = 'target05'; PairId = 'pair01'; RoleName = 'bottom' },
    @{ Id = 'target03'; PairId = 'pair03'; RoleName = 'top' },
    @{ Id = 'target07'; PairId = 'pair03'; RoleName = 'bottom' }
)

$targetEntries = foreach ($targetSpec in $targetSpecs) {
    $targetFolder = Join-Path (Join-Path $tmpRoot 'inbox') $targetSpec.Id
    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
    [pscustomobject]@{
        TargetId = $targetSpec.Id
        Folder   = $targetFolder
        PairId   = $targetSpec.PairId
        RoleName = $targetSpec.RoleName
    }
}

$runtimeItems = @(
    [pscustomobject]@{
        TargetId          = 'target01'
        WindowPid         = 101
        ShellPid          = 201
        Hwnd              = '0x101'
        ResolvedBy        = 'binding-file'
        RegistrationMode  = 'attached'
        LauncherSessionId = 'session-a'
    },
    [pscustomobject]@{
        TargetId          = 'target05'
        WindowPid         = 105
        ShellPid          = 205
        Hwnd              = '0x105'
        ResolvedBy        = 'binding-file'
        RegistrationMode  = 'attached'
        LauncherSessionId = 'session-a'
    }
)
$runtimeItems | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $runtimeMapPath -Encoding UTF8
'{}' | Set-Content -LiteralPath $routerStatePath -Encoding UTF8

$bindingDocument = [ordered]@{
    reuse_mode                = 'pairs'
    partial_reuse             = $true
    configured_target_count   = 4
    active_expected_target_count = 2
    active_pair_ids           = @('pair01')
    inactive_pair_ids         = @('pair03')
    incomplete_pair_ids       = @('pair03')
    active_target_ids         = @('target01', 'target05')
    inactive_target_ids       = @('target03', 'target07')
    orphan_matched_target_ids = @('target03')
    soft_findings             = @('incomplete-pair:pair03', 'orphan-target:target03')
    configured_targets        = @(
        $targetEntries | ForEach-Object {
            [ordered]@{
                target_id = $_.TargetId
                pair_id   = $_.PairId
                role_name = $_.RoleName
            }
        }
    )
    windows                   = @(
        [ordered]@{ target_id = 'target01'; pair_id = 'pair01' },
        [ordered]@{ target_id = 'target05'; pair_id = 'pair01' },
        [ordered]@{ target_id = 'target03'; pair_id = 'pair03' }
    )
}
$bindingDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bindingProfilePath -Encoding UTF8

$configPath = Join-Path $tmpRoot 'settings.partial-scope.psd1'
$configLiteral = @(
    "@{"
    "    Root = '$($tmpRoot.Replace("'", "''"))'"
    "    RuntimeMapPath = '$($runtimeMapPath.Replace("'", "''"))'"
    "    RouterStatePath = '$($routerStatePath.Replace("'", "''"))'"
    "    BindingProfilePath = '$($bindingProfilePath.Replace("'", "''"))'"
    "    LogsRoot = '$($logsRoot.Replace("'", "''"))'"
    "    ProcessedRoot = '$($processedRoot.Replace("'", "''"))'"
    "    FailedRoot = '$($failedRoot.Replace("'", "''"))'"
    "    RetryPendingRoot = '$($retryPendingRoot.Replace("'", "''"))'"
    "    Targets = @("
)
foreach ($targetEntry in $targetEntries) {
    $configLiteral += "        @{ Id = '$($targetEntry.TargetId)'; Folder = '$($targetEntry.Folder.Replace("'", "''"))' }"
}
$configLiteral += @(
    "    )"
    "}"
)
$configLiteral -join "`r`n" | Set-Content -LiteralPath $configPath -Encoding UTF8

$raw = & $powershellPath `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File (Join-Path $root 'show-relay-status.ps1') `
    -ConfigPath $configPath `
    -AsJson

if ($LASTEXITCODE -ne 0) {
    throw ("show-relay-status failed: " + (($raw | Out-String).Trim()))
}

$payload = $raw | ConvertFrom-Json

Assert-True ($payload.Runtime.ExpectedTargetCount -eq 2) 'Expected partial scope target count 2.'
Assert-True ($payload.Runtime.ConfiguredTargetCount -eq 4) 'Expected configured target count 4.'
Assert-True ($payload.Runtime.BindingWindowCount -eq 3) 'Expected total binding window count 3.'
Assert-True ($payload.Runtime.BindingScopedWindowCount -eq 2) 'Expected scoped binding window count 2.'

Assert-SetEqual -Actual $payload.Runtime.ActivePairIds -Expected @('pair01') -Message 'ActivePairIds mismatch.'
Assert-SetEqual -Actual $payload.Runtime.IncompletePairIds -Expected @('pair03') -Message 'IncompletePairIds mismatch.'
Assert-SetEqual -Actual $payload.Runtime.InactiveTargetIds -Expected @('target03', 'target07') -Message 'InactiveTargetIds mismatch.'
Assert-SetEqual -Actual $payload.Runtime.OutOfScopeBindingTargetIds -Expected @('target03') -Message 'OutOfScopeBindingTargetIds mismatch.'
Assert-SetEqual -Actual $payload.Runtime.OrphanMatchedTargetIds -Expected @('target03') -Message 'OrphanMatchedTargetIds mismatch.'
Assert-SetEqual -Actual $payload.Runtime.SoftFindings -Expected @('incomplete-pair:pair03', 'orphan-target:target03') -Message 'SoftFindings mismatch.'

$target03 = @($payload.Targets | Where-Object { $_.TargetId -eq 'target03' })[0]
Assert-True ($null -ne $target03) 'Expected target03 row in relay status.'
Assert-True ($target03.RuntimeStatus -eq 'out-of-scope') 'Expected target03 to be reported as out-of-scope.'

Write-Host ('show-relay-status partial scope contract ok: tmpRoot=' + $tmpRoot)
