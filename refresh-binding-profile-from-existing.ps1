[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$BindingsPath,
    [ValidateSet('Full', 'Pairs')][string]$ReuseMode = 'Full',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config\settings.psd1'
}

& (Join-Path $PSScriptRoot 'launcher\Refresh-BindingProfileFromExisting.ps1') @PSBoundParameters
