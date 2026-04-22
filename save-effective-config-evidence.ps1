[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string[]]$PairId,
    [string]$TargetId,
    [ValidateSet('both', 'initial', 'handoff')][string]$Mode = 'both',
    [int]$StaleRunThresholdSec = 1800,
    [switch]$Force,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Save-EffectiveConfigEvidence.ps1') @PSBoundParameters
