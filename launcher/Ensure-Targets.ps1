[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DiagnosticOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

if ($DiagnosticOnly) {
    & (Join-Path $PSScriptRoot 'Attach-Targets.ps1') -ConfigPath $ConfigPath -DiagnosticOnly
    return
}

try {
    & (Join-Path $PSScriptRoot 'Attach-Targets.ps1') -ConfigPath $ConfigPath
}
catch {
    Write-Host ("attach failed, launching new targets without cleanup: {0}" -f $_.Exception.Message)
    & (Join-Path $PSScriptRoot 'Start-Targets.ps1') -ConfigPath $ConfigPath
}
