[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'tests\Test-CreateRefactorCloseoutReview.ps1') @PSBoundParameters
