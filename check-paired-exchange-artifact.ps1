[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$SummarySourcePath,
    [Parameter(Mandatory)][string]$ReviewZipSourcePath,
    [switch]$KeepZipFileName,
    [switch]$Overwrite,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invokeParams = @{}
foreach ($key in $PSBoundParameters.Keys) {
    $invokeParams[$key] = $PSBoundParameters[$key]
}
$invokeParams['DryRun'] = $true

& (Join-Path $PSScriptRoot 'tests\Import-PairedExchangeArtifact.ps1') @invokeParams
