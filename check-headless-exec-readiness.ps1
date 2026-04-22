[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$TargetId,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'executor\Check-HeadlessExecReadiness.ps1') @PSBoundParameters
