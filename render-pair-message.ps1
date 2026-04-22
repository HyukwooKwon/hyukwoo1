[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [Parameter(Mandatory)][string]$PairId,
    [Parameter(Mandatory)][string]$TargetId,
    [ValidateSet('both', 'initial', 'handoff')][string]$Mode = 'both',
    [string]$OutputRoot,
    [switch]$WriteOutputs,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Render-PairMessage.ps1') @PSBoundParameters
