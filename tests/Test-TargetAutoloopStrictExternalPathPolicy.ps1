[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
    }
    catch {
        if ([string]$_.Exception.Message -match $Pattern) {
            return
        }

        throw ($Message + ' actual=' + [string]$_.Exception.Message)
    }

    throw ($Message + ' actual=<no exception>')
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\TargetAutoloopConfig.ps1')

$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopStrictExternalPathPolicy'
$externalRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'relay-target-autoloop-strict-external-policy'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
if (Test-Path -LiteralPath $externalRoot) {
    Remove-Item -LiteralPath $externalRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
New-Item -ItemType Directory -Path $externalRoot -Force | Out-Null

$externalRunRootBase = Join-Path $externalRoot '.relay-runs\bottest-live-visible\target-autoloop'
$externalStatusRoot = Join-Path $externalRoot '.relay-bookkeeping\bottest-live-visible\target-autoloop\status'
$externalQueueRoot = Join-Path $externalRoot '.relay-bookkeeping\bottest-live-visible\target-autoloop\queue'
$externalWorkRepoRoot = Join-Path $externalRoot 'target-work-repo'
New-Item -ItemType Directory -Path $externalWorkRepoRoot -Force | Out-Null

$strictInternalDefaultsConfigPath = Join-Path $tmpRoot 'strict-internal-defaults.psd1'
[System.IO.File]::WriteAllText($strictInternalDefaultsConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        ExternalPathPolicy = 'strict'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); WorkRepoRoot = '$($externalWorkRepoRoot.Replace("'", "''"))' }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

Assert-ThrowsLike `
    -Action { Resolve-TargetAutoloopConfig -Root $root -ConfigPath $strictInternalDefaultsConfigPath | Out-Null } `
    -Pattern 'TargetAutoloop\.RunRootBase must be outside automation repo' `
    -Message 'strict policy should reject default automation-repo RunRootBase.'

$strictMissingWorkRepoConfigPath = Join-Path $tmpRoot 'strict-missing-workrepo.psd1'
[System.IO.File]::WriteAllText($strictMissingWorkRepoConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        ExternalPathPolicy = 'strict'
        RunRootBase = '$($externalRunRootBase.Replace("'", "''"))'
        StatusRoot = '$($externalStatusRoot.Replace("'", "''"))'
        QueueRoot = '$($externalQueueRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

Assert-ThrowsLike `
    -Action { Resolve-TargetAutoloopConfig -Root $root -ConfigPath $strictMissingWorkRepoConfigPath | Out-Null } `
    -Pattern 'TargetAutoloop\.Targets\.target01\.WorkRepoRoot must be an explicit external path' `
    -Message 'strict policy should require enabled target WorkRepoRoot.'

$strictValidConfigPath = Join-Path $tmpRoot 'strict-valid.psd1'
[System.IO.File]::WriteAllText($strictValidConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        ExternalPathPolicy = 'strict'
        RunRootBase = '$($externalRunRootBase.Replace("'", "''"))'
        StatusRoot = '$($externalStatusRoot.Replace("'", "''"))'
        QueueRoot = '$($externalQueueRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); WorkRepoRoot = '$($externalWorkRepoRoot.Replace("'", "''"))' }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$resolved = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $strictValidConfigPath
Assert-True ([string]$resolved.ExternalPathPolicy -eq 'strict') 'strict config should preserve ExternalPathPolicy.'
Assert-True ([string]$resolved.RunRootBase -eq [System.IO.Path]::GetFullPath($externalRunRootBase)) 'strict config should resolve external RunRootBase.'

$internalRunRoot = Join-Path $tmpRoot 'run_internal'
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $output = @(
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
            -ConfigPath $strictValidConfigPath `
            -RunRoot $internalRunRoot `
            -Targets target01 `
            -AsJson 2>&1
    )
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
$detail = ($output | Out-String)
Assert-True ($exitCode -ne 0) 'strict start should reject automation-repo RunRoot override.'
Assert-True ($detail.Contains('TargetAutoloop.RunRoot must be outside automation repo')) 'strict start failure should explain the RunRoot policy.'

Write-Host 'target autoloop strict external path policy ok'
