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

$configPath = Join-Path $root '_tmp\resolve-pair-target-selection.psd1'
@"
@{
    Targets = @(
        @{ Id = 'target11'; Folder = 'C:\tmp\target11'; WindowTitle = 'Target11'; EnterCount = 1 }
        @{ Id = 'target21'; Folder = 'C:\tmp\target21'; WindowTitle = 'Target21'; EnterCount = 1 }
        @{ Id = 'target31'; Folder = 'C:\tmp\target31'; WindowTitle = 'Target31'; EnterCount = 1 }
        @{ Id = 'target41'; Folder = 'C:\tmp\target41'; WindowTitle = 'Target41'; EnterCount = 1 }
    )
    PairTest = @{
        RunRootBase = 'C:\tmp\pair-test'
        DefaultPairId = 'pair02'
        PairDefinitions = @(
            @{ PairId = 'pair02'; TopTargetId = 'target11'; BottomTargetId = 'target21'; SeedTargetId = 'target21' }
            @{ PairId = 'pair03'; TopTargetId = 'target31'; BottomTargetId = 'target41'; SeedTargetId = 'target31' }
        )
    }
}
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $configPath

$defaultSelection = Resolve-PairTargetSelection -PairTest $pairTest -PairId '' -TargetId ''
Assert-True ([string]$defaultSelection.PairId -eq 'pair02') 'selection should default to configured pair id.'
Assert-True ([string]$defaultSelection.TargetId -eq 'target21') 'selection should default to configured seed target.'
Assert-True ([string]$defaultSelection.PartnerTargetId -eq 'target11') 'selection should resolve partner target.'

$targetDrivenSelection = Resolve-PairTargetSelection -PairTest $pairTest -PairId '' -TargetId 'target31'
Assert-True ([string]$targetDrivenSelection.PairId -eq 'pair03') 'selection should infer pair id from target id.'
Assert-True ([string]$targetDrivenSelection.TargetId -eq 'target31') 'selection should preserve explicit target id.'
Assert-True ([string]$targetDrivenSelection.PartnerTargetId -eq 'target41') 'selection should resolve partner target from inferred pair.'

$explicitSelection = Resolve-PairTargetSelection -PairTest $pairTest -PairId 'pair02' -TargetId 'target11'
Assert-True ([string]$explicitSelection.PairId -eq 'pair02') 'explicit pair id should be preserved.'
Assert-True ([string]$explicitSelection.TargetId -eq 'target11') 'explicit target id should be preserved.'
Assert-True ([string]$explicitSelection.PartnerTargetId -eq 'target21') 'explicit pair selection should resolve opposite target as partner.'

$invalidTargetFailed = $false
try {
    $null = Resolve-PairTargetSelection -PairTest $pairTest -PairId 'pair02' -TargetId 'target99'
}
catch {
    $invalidTargetFailed = ($_.Exception.Message -like '*does not belong to pair*')
}
Assert-True $invalidTargetFailed 'selection should reject target ids that are outside the pair.'

Write-Host 'resolve pair target selection ok'
