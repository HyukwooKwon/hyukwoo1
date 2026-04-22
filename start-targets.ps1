[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ReplaceExisting,
    [switch]$UnsafeForceKillManagedTargets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config\settings.psd1'
}

& (Join-Path $PSScriptRoot 'launcher\Start-Targets.ps1') @PSBoundParameters
