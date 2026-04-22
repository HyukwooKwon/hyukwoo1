[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$PairId,
    [ValidateSet('', 'top', 'bottom')][string]$Role = '',
    [string]$TargetId,
    [ValidateSet('initial', 'handoff', 'both')][string]$AppliesTo = 'both',
    [ValidateSet('one-time-prefix', 'one-time-suffix')][string]$Placement = 'one-time-prefix',
    [Parameter(Mandatory)][string]$Text,
    [int]$Priority = 100,
    [string]$Notes,
    [string]$CreatedBy,
    [string]$ExpiresAt,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Enqueue-OneTimeMessage.ps1') @PSBoundParameters
