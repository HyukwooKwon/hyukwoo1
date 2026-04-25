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
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

$pairTestSmoke = [pscustomobject]@{
    AcceptanceProfile = 'smoke'
    MessageTemplates = [pscustomobject]@{
        Initial = [pscustomobject]@{
            SlotOrder = @('prefix', 'extra', 'body', 'suffix')
            PrefixBlocks = @('prefix')
            SuffixBlocks = @('suffix')
        }
    }
    PairOverrides = [pscustomobject]@{
        pair01 = [pscustomobject]@{
            InitialExtraBlocks = @('pair extra')
        }
    }
    RoleOverrides = [pscustomobject]@{
        top = [pscustomobject]@{
            InitialExtraBlocks = @('role extra')
        }
    }
    TargetOverrides = [pscustomobject]@{
        target01 = [pscustomobject]@{
            InitialExtraBlocks = @('target extra')
        }
    }
}

$blocksSmoke = Get-PairTemplateBlocks -PairTest $pairTestSmoke -TemplateName 'Initial' -PairId 'pair01' -RoleName 'top' -TargetId 'target01'
Assert-True (@($blocksSmoke.ExtraBlocks).Count -eq 0) 'smoke profile should suppress override extra blocks for initial prompts.'

$pairTestProject = [pscustomobject]@{
    AcceptanceProfile = 'project-review'
    MessageTemplates = $pairTestSmoke.MessageTemplates
    PairOverrides = $pairTestSmoke.PairOverrides
    RoleOverrides = $pairTestSmoke.RoleOverrides
    TargetOverrides = $pairTestSmoke.TargetOverrides
}

$blocksProject = Get-PairTemplateBlocks -PairTest $pairTestProject -TemplateName 'Initial' -PairId 'pair01' -RoleName 'top' -TargetId 'target01'
Assert-True (@($blocksProject.ExtraBlocks).Count -eq 3) 'project-review profile should keep override extra blocks.'

Write-Host 'pair template blocks smoke profile ok'
