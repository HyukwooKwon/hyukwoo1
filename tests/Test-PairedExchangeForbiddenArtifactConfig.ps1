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

    if (-not [bool]$Condition) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath

Assert-True (@($pairTest.ForbiddenArtifactLiterals).Count -ge 1) 'forbidden artifact literal list should be populated.'
Assert-True (@($pairTest.ForbiddenArtifactRegexes).Count -ge 1) 'forbidden artifact regex list should be populated.'
Assert-True (@($pairTest.ForbiddenArtifactLiterals) -contains '여기에 고정문구 입력') 'placeholder literal should remain blocked by config.'
Assert-True ((@($pairTest.ForbiddenArtifactRegexes | Where-Object { [string]$_ -match '이렇게 계획개선해봤어' }).Count) -gt 0) 'regex list should include contamination phrase coverage.'
Assert-True ((@($pairTest.ForbiddenArtifactRegexes | Where-Object { [string]$_ -match '더 개선해야될 부분이 있어' }).Count) -gt 0) 'regex list should include the plan-review contamination phrase.'

Write-Host 'paired-exchange forbidden artifact config ok'
