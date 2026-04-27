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

$sourcePath = Join-Path $root 'tests\Run-PairTransportClosureAcceptance.ps1'
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
foreach ($functionName in @('Test-NonEmptyString', 'Resolve-PairTransportClosureSelection')) {
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

$configPath = Join-Path $root '_tmp\run-pair-transport-closure-selection.psd1'
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

$selection = Resolve-PairTransportClosureSelection -Root $root -ConfigPath $configPath -PairId '' -InitialTargetId ''
Assert-True ([string]$selection.PairId -eq 'pair02') 'transport closure selection should default to configured default pair id.'
Assert-True ([string]$selection.InitialTargetId -eq 'target11') 'transport closure selection should default to the resolved seed target.'

$explicitSelection = Resolve-PairTransportClosureSelection -Root $root -ConfigPath $configPath -PairId 'pair02' -InitialTargetId 'target21'
Assert-True ([string]$explicitSelection.PairId -eq 'pair02') 'explicit pair id should be preserved.'
Assert-True ([string]$explicitSelection.InitialTargetId -eq 'target21') 'explicit initial target should be preserved.'

$invalidInitialFailed = $false
try {
    $null = Resolve-PairTransportClosureSelection -Root $root -ConfigPath $configPath -PairId 'pair02' -InitialTargetId 'target99'
}
catch {
    $invalidInitialFailed = ($_.Exception.Message -like '*initial target does not belong to pair*')
}
Assert-True $invalidInitialFailed 'transport closure selection should reject an initial target that is not part of the pair.'

Write-Host 'run pair transport closure selection helper ok'
