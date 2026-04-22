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
. (Join-Path $root 'router\BindingSessionScope.ps1')

$config = [pscustomobject]@{
    Targets = @(
        [pscustomobject]@{ Id = 'target01' },
        [pscustomobject]@{ Id = 'target05' },
        [pscustomobject]@{ Id = 'target03' },
        [pscustomobject]@{ Id = 'target07' }
    )
}

$bindingData = [pscustomobject]@{
    reuse_mode                = 'pairs'
    partial_reuse             = $true
    configured_target_count   = 4
    active_pair_ids           = @('pair01')
    inactive_pair_ids         = @('pair03')
    incomplete_pair_ids       = @('pair03')
    active_target_ids         = @('target01', 'target05')
    inactive_target_ids       = @('target03', 'target07')
    orphan_matched_target_ids = @('target03')
    soft_findings             = @('incomplete-pair:pair03', 'orphan-target:target03')
    configured_targets        = @(
        [pscustomobject]@{ target_id = 'target01'; pair_id = 'pair01'; role_name = 'top' },
        [pscustomobject]@{ target_id = 'target05'; pair_id = 'pair01'; role_name = 'bottom' },
        [pscustomobject]@{ target_id = 'target03'; pair_id = 'pair03'; role_name = 'top' },
        [pscustomobject]@{ target_id = 'target07'; pair_id = 'pair03'; role_name = 'bottom' }
    )
    windows                   = @(
        [pscustomobject]@{ target_id = 'target01'; pair_id = 'pair01' },
        [pscustomobject]@{ targetId = 'target05'; pairId = 'pair01' },
        [pscustomobject]@{ TargetId = 'target03'; PairId = 'pair03' }
    )
}

$bindingDocument = [pscustomobject]@{
    Data    = $bindingData
    Windows = @($bindingData.windows)
}

$scope = Get-BindingSessionScope -Config $config -BindingDocument $bindingDocument

Assert-True ($scope.PartialReuse -eq $true) 'Expected partial reuse session scope.'
Assert-True ($scope.ReuseMode -eq 'pairs') 'Expected reuse mode pairs.'
Assert-True ($scope.ConfiguredTargetCount -eq 4) 'Expected configured target count 4.'
Assert-True ($scope.ExpectedTargetCount -eq 2) 'Expected active target count 2.'
Assert-True ($scope.BindingWindowCount -eq 3) 'Expected total binding window count 3.'
Assert-True ($scope.ScopedBindingWindowCount -eq 2) 'Expected scoped binding window count 2.'

Assert-SetEqual -Actual $scope.ActivePairIds -Expected @('pair01') -Message 'ActivePairIds mismatch.'
Assert-SetEqual -Actual $scope.InactivePairIds -Expected @('pair03') -Message 'InactivePairIds mismatch.'
Assert-SetEqual -Actual $scope.IncompletePairIds -Expected @('pair03') -Message 'IncompletePairIds mismatch.'
Assert-SetEqual -Actual $scope.ActiveTargetIds -Expected @('target01', 'target05') -Message 'ActiveTargetIds mismatch.'
Assert-SetEqual -Actual $scope.InactiveTargetIds -Expected @('target03', 'target07') -Message 'InactiveTargetIds mismatch.'
Assert-SetEqual -Actual $scope.BindingWindowTargetIds -Expected @('target01', 'target03', 'target05') -Message 'BindingWindowTargetIds mismatch.'
Assert-SetEqual -Actual $scope.ScopedBindingTargetIds -Expected @('target01', 'target05') -Message 'ScopedBindingTargetIds mismatch.'
Assert-SetEqual -Actual $scope.OutOfScopeBindingTargetIds -Expected @('target03') -Message 'OutOfScopeBindingTargetIds mismatch.'
Assert-SetEqual -Actual $scope.OrphanMatchedTargetIds -Expected @('target03') -Message 'OrphanMatchedTargetIds mismatch.'
Assert-SetEqual -Actual $scope.SoftFindings -Expected @('incomplete-pair:pair03', 'orphan-target:target03') -Message 'SoftFindings mismatch.'

$scopedWindowTargetIds = @($scope.ScopedBindingWindows | ForEach-Object { Get-BindingSessionScopeTargetId -Entry $_ })
Assert-SetEqual -Actual $scopedWindowTargetIds -Expected @('target01', 'target05') -Message 'ScopedBindingWindows should align with active target scope.'
Assert-True (@($scope.ScopedBindingWindows).Count -eq 2) 'Expected two scoped binding window records.'

Write-Host 'binding session scope contract ok'
