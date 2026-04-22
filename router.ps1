[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$RunDurationMs = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config\settings.psd1'
}

& (Join-Path $PSScriptRoot 'router\Start-Router.ps1') @PSBoundParameters
