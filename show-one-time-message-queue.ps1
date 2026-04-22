[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$PairId,
    [ValidateSet('', 'queued', 'previewed', 'consumed', 'cancelled', 'expired')][string]$State = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Show-OneTimeMessageQueue.ps1') @PSBoundParameters
