[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$PairId = 'pair01',
    [string]$InitialTargetId,
    [int]$MaxForwardCount = 2,
    [int]$RunDurationSec = 900,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Run-HeadlessPairDrill.ps1') @PSBoundParameters
