[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$PairId,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Show-PairActivationStatus.ps1') @PSBoundParameters
