[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [string]$PromptFilePath,
    [int]$TimeoutSec = 0,
    [switch]$DryRun,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'executor\Invoke-CodexExecTurn.ps1') @PSBoundParameters
