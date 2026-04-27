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

$sourcePath = Join-Path $root 'tests\Confirm-SharedVisiblePairAcceptance.ps1'
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
foreach ($functionName in @('Test-NonEmptyString', 'Resolve-ConfirmPairSelection')) {
    $functionAst = @(
        $scriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) |
            Select-Object -First 1
    )
    Assert-True (@($functionAst).Count -eq 1) ("missing function: " + $functionName)
    Invoke-Expression $functionAst[0].Extent.Text
}

$configPath = Join-Path $root '_tmp\confirm-shared-visible-pair-selection.psd1'
@"
@{
    Targets = @(
        @{ Id = 'target10'; Folder = 'C:\tmp\target10'; WindowTitle = 'Target10'; EnterCount = 1 }
        @{ Id = 'target11'; Folder = 'C:\tmp\target11'; WindowTitle = 'Target11'; EnterCount = 1 }
        @{ Id = 'target20'; Folder = 'C:\tmp\target20'; WindowTitle = 'Target20'; EnterCount = 1 }
        @{ Id = 'target21'; Folder = 'C:\tmp\target21'; WindowTitle = 'Target21'; EnterCount = 1 }
    )
    PairTest = @{
        RunRootBase = 'C:\tmp\pair-test'
        DefaultPairId = 'pair02'
    }
}
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

$selection = Resolve-ConfirmPairSelection -Root $root -ConfigPath $configPath -PairId '' -SeedTargetId ''
Assert-True ([string]$selection.PairId -eq 'pair02') 'selection should default to configured default pair id.'
Assert-True ([string]$selection.SeedTargetId -eq 'target11') 'selection should default to the resolved seed target.'
Assert-True ([string]$selection.PartnerTargetId -eq 'target21') 'selection should resolve the partner target from pair definition.'

$reverseSelection = Resolve-ConfirmPairSelection -Root $root -ConfigPath $configPath -PairId 'pair02' -SeedTargetId 'target21'
Assert-True ([string]$reverseSelection.PairId -eq 'pair02') 'explicit pair id should be preserved.'
Assert-True ([string]$reverseSelection.SeedTargetId -eq 'target21') 'explicit seed target should be preserved.'
Assert-True ([string]$reverseSelection.PartnerTargetId -eq 'target11') 'reverse selection should resolve the opposite target as partner.'

$invalidSeedFailed = $false
try {
    $null = Resolve-ConfirmPairSelection -Root $root -ConfigPath $configPath -PairId 'pair02' -SeedTargetId 'target99'
}
catch {
    $invalidSeedFailed = ($_.Exception.Message -like '*seed target does not belong to pair*')
}
Assert-True $invalidSeedFailed 'selection should reject a seed target that is not part of the pair.'

Write-Host 'confirm shared visible pair selection helper ok'
