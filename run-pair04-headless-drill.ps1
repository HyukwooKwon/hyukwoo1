[CmdletBinding()]
param(
    [string]$RunRoot,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'run-preset-headless-pair-drill.ps1') -PairId 'pair04' @PSBoundParameters
