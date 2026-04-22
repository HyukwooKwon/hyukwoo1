[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [int]$RecentFailureCount = 10,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Show-PairedExchangeStatus.ps1') @PSBoundParameters
