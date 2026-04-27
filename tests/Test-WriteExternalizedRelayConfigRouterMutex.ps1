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
$fixtureRoot = 'C:\dev\python\_relay-test-fixtures'
$tempRoot = Join-Path $fixtureRoot 'Test-WriteExternalizedRelayConfigRouterMutex'
$workRepoRoot = Join-Path $tempRoot 'external-repo-a'
$outputConfigPath = Join-Path $workRepoRoot '.relay-config\bottest-live-visible\settings.externalized.psd1'

if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $workRepoRoot -Force | Out-Null

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$baseConfig = Import-PowerShellDataFile -Path $baseConfigPath

$result = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath $baseConfigPath `
    -WorkRepoRoot $workRepoRoot `
    -OutputConfigPath $outputConfigPath `
    -AsJson | ConvertFrom-Json

$externalConfig = Import-PowerShellDataFile -Path $outputConfigPath
$baseMutex = [string]$baseConfig.RouterMutexName
$externalMutex = [string]$externalConfig.RouterMutexName

Assert-True (Test-Path -LiteralPath $outputConfigPath -PathType Leaf) 'externalized config should be written.'
Assert-True (-not [string]::IsNullOrWhiteSpace($externalMutex)) 'externalized config should contain RouterMutexName.'
Assert-True ($externalMutex -ne $baseMutex) 'externalized config must use a different router mutex from the automation/base config.'
Assert-True ($externalMutex -match '_ext_') 'externalized router mutex should carry an externalized suffix.'
Assert-True ([string]$result.RouterMutexName -eq $externalMutex) 'json result should surface the effective externalized router mutex.'

Write-Host 'write-externalized-relay-config router mutex ok'
