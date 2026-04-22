[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'launcher\Check-TargetWindowVisibility.ps1') @PSBoundParameters
