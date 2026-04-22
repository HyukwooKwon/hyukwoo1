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
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    $actualItems = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $expectedItems = @($Expected | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $difference = @(Compare-Object -ReferenceObject $expectedItems -DifferenceObject $actualItems)
    if ($difference.Count -gt 0 -or $actualItems.Count -ne $expectedItems.Count) {
        throw ($Message + " expected=[" + ($expectedItems -join ', ') + "] actual=[" + ($actualItems -join ', ') + "]")
    }
}

function Get-TargetRowById {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]$TargetId
    )

    return @($Rows | Where-Object { [string]$_.TargetId -eq $TargetId })[0]
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'router\BindingRefreshReuseScope.ps1')

$completePairWithOrphanTargets = @(
    [pscustomobject]@{
        TargetId = 'target01'; PairId = 'pair01'; RoleName = 'top'; Matched = $true; MatchMethod = 'hwnd'; Reason = ''; ShellPid = '201'; WindowPid = '101'; Hwnd = '0x101'
    },
    [pscustomobject]@{
        TargetId = 'target05'; PairId = 'pair01'; RoleName = 'bottom'; Matched = $true; MatchMethod = 'title'; Reason = ''; ShellPid = '205'; WindowPid = '105'; Hwnd = '0x105'
    },
    [pscustomobject]@{
        TargetId = 'target03'; PairId = 'pair03'; RoleName = 'top'; Matched = $true; MatchMethod = 'hwnd'; Reason = ''; ShellPid = '203'; WindowPid = '103'; Hwnd = '0x103'
    },
    [pscustomobject]@{
        TargetId = 'target07'; PairId = 'pair03'; RoleName = 'bottom'; Matched = $false; MatchMethod = 'title'; Reason = 'window-missing'; ShellPid = '207'; WindowPid = ''; Hwnd = ''
    }
)

$pairScope = Resolve-BindingRefreshReuseScope `
    -Targets $completePairWithOrphanTargets `
    -ExpectedTargetIds @('target01', 'target05', 'target03', 'target07') `
    -ReuseMode 'Pairs'

Assert-True ($pairScope.Success -eq $true) 'Expected complete pair + orphan scenario to succeed.'
Assert-SetEqual -Actual $pairScope.ActivePairIds -Expected @('pair01') -Message 'ActivePairIds mismatch.'
Assert-SetEqual -Actual $pairScope.InactivePairIds -Expected @('pair03') -Message 'InactivePairIds mismatch.'
Assert-SetEqual -Actual $pairScope.IncompletePairIds -Expected @('pair03') -Message 'IncompletePairIds mismatch.'
Assert-SetEqual -Actual $pairScope.ActiveTargetIds -Expected @('target01', 'target05') -Message 'ActiveTargetIds mismatch.'
Assert-SetEqual -Actual $pairScope.InactiveTargetIds -Expected @('target03', 'target07') -Message 'InactiveTargetIds mismatch.'
Assert-SetEqual -Actual $pairScope.OrphanMatchedTargetIds -Expected @('target03') -Message 'OrphanMatchedTargetIds mismatch.'
Assert-SetEqual -Actual $pairScope.HardFailures -Expected @() -Message 'HardFailures mismatch.'
Assert-SetEqual -Actual $pairScope.SoftFindings -Expected @('incomplete-pair:pair03:1/2', 'orphan-target:target03:pair03', 'window-missing:target07:title') -Message 'SoftFindings mismatch.'

$target01 = Get-TargetRowById -Rows $pairScope.AnnotatedTargets -TargetId 'target01'
$target03 = Get-TargetRowById -Rows $pairScope.AnnotatedTargets -TargetId 'target03'
$target07 = Get-TargetRowById -Rows $pairScope.AnnotatedTargets -TargetId 'target07'

Assert-True ($target01.CountedAsReused -eq $true) 'Expected target01 to count as reused.'
Assert-True ($target01.InSessionScope -eq $true) 'Expected target01 to be in scope.'
Assert-True ($target01.ScopeState -eq 'active') 'Expected target01 scope state active.'
Assert-True ($target01.PairCompletionState -eq 'complete') 'Expected target01 pair completion state complete.'

Assert-True ($target03.CountedAsReused -eq $false) 'Expected target03 not to count as reused.'
Assert-True ($target03.InSessionScope -eq $false) 'Expected target03 out of session scope.'
Assert-True ($target03.ScopeState -eq 'orphan') 'Expected target03 scope state orphan.'
Assert-True ($target03.PairCompletionState -eq 'incomplete') 'Expected target03 pair completion state incomplete.'

Assert-True ($target07.ScopeState -eq 'inactive') 'Expected target07 scope state inactive.'
Assert-True ($target07.PairCompletionState -eq 'incomplete') 'Expected target07 pair completion state incomplete.'

$orphanOnlyScope = Resolve-BindingRefreshReuseScope `
    -Targets @(
        [pscustomobject]@{
            TargetId = 'target03'; PairId = 'pair03'; RoleName = 'top'; Matched = $true; MatchMethod = 'hwnd'; Reason = ''; ShellPid = '203'; WindowPid = '103'; Hwnd = '0x103'
        },
        [pscustomobject]@{
            TargetId = 'target07'; PairId = 'pair03'; RoleName = 'bottom'; Matched = $false; MatchMethod = 'title'; Reason = 'window-missing'; ShellPid = '207'; WindowPid = ''; Hwnd = ''
        }
    ) `
    -ExpectedTargetIds @('target03', 'target07') `
    -ReuseMode 'Pairs'

Assert-True ($orphanOnlyScope.Success -eq $false) 'Expected orphan-only scenario to fail.'
Assert-SetEqual -Actual $orphanOnlyScope.ActivePairIds -Expected @() -Message 'Expected no active pairs for orphan-only scenario.'
Assert-SetEqual -Actual $orphanOnlyScope.HardFailures -Expected @('no-complete-pair') -Message 'HardFailures mismatch for orphan-only scenario.'
Assert-SetEqual -Actual $orphanOnlyScope.OrphanMatchedTargetIds -Expected @('target03') -Message 'OrphanMatchedTargetIds mismatch for orphan-only scenario.'

Write-Host 'binding refresh reuse scope contract ok'
