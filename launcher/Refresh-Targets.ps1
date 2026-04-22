[CmdletBinding()]
param(
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

try {
    & (Join-Path $PSScriptRoot 'Ensure-Targets.ps1') -ConfigPath $ConfigPath
}
catch {
    throw
}
