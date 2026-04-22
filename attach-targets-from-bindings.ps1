[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$BindingsPath,
    [switch]$DiagnosticOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config\settings.psd1'
}

& (Join-Path $PSScriptRoot 'launcher\Attach-TargetsFromBindings.ps1') @PSBoundParameters
