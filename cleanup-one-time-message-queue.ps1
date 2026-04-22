[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$PairId,
    [ValidateSet('all', 'cancelled', 'expired')][string]$State = 'all',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Cleanup-OneTimeMessageQueue.ps1') @PSBoundParameters
