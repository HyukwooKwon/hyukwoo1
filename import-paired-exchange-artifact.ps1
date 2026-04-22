[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$SummarySourcePath,
    [Parameter(Mandatory)][string]$ReviewZipSourcePath,
    [string]$ImportMode = 'manual-import',
    [switch]$KeepZipFileName,
    [switch]$Overwrite,
    [switch]$DryRun,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Import-PairedExchangeArtifact.ps1') @PSBoundParameters
