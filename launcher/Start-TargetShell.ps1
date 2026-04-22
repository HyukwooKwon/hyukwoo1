[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$WindowTitle,
    [Parameter(Mandatory)][string]$RootPath,
    [Parameter(Mandatory)][string]$ManagedMarker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:RELAY_TARGET_ID = $TargetId
$env:RELAY_MANAGED_MARKER = $ManagedMarker
$Host.UI.RawUI.WindowTitle = $WindowTitle
Set-Location $RootPath
Write-Host "READY: $WindowTitle" -ForegroundColor Green
