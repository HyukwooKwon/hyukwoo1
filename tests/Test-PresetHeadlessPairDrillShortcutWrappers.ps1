[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

function Assert-Match {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot

$genericLaunchText = Get-Content -LiteralPath (Join-Path $root 'launch-preset-headless-pair-drill.cmd') -Raw -Encoding UTF8
Assert-Match -Text $genericLaunchText -Pattern 'run-preset-headless-pair-drill\.ps1' -Message 'generic launch wrapper should call the preset runner.'
Assert-Match -Text $genericLaunchText -Pattern '-PairId' -Message 'generic launch wrapper should forward PairId.'

$genericOpenText = Get-Content -LiteralPath (Join-Path $root 'open-preset-headless-pair-drill.vbs') -Raw -Encoding UTF8
Assert-Match -Text $genericOpenText -Pattern 'launch-preset-headless-pair-drill\.cmd' -Message 'generic open wrapper should call the generic launch wrapper.'

foreach ($ordinal in 1..4) {
    $pairId = ('pair{0:d2}' -f $ordinal)
    $pairRunText = Get-Content -LiteralPath (Join-Path $root ('run-{0}-headless-drill.ps1' -f $pairId)) -Raw -Encoding UTF8
    Assert-Match -Text $pairRunText -Pattern 'run-preset-headless-pair-drill\.ps1' -Message ("{0} runner should delegate to the preset runner." -f $pairId)
    Assert-Match -Text $pairRunText -Pattern ([regex]::Escape("-PairId '" + $pairId + "'")) -Message ("{0} runner should pin its preset pair id." -f $pairId)

    $pairLaunchText = Get-Content -LiteralPath (Join-Path $root ('launch-run-{0}-headless-drill.cmd' -f $pairId)) -Raw -Encoding UTF8
    Assert-Match -Text $pairLaunchText -Pattern 'launch-preset-headless-pair-drill\.cmd' -Message ("{0} launch wrapper should delegate to the generic launch wrapper." -f $pairId)
    Assert-Match -Text $pairLaunchText -Pattern $pairId -Message ("{0} launch wrapper should pin its preset pair id." -f $pairId)

    $pairOpenText = Get-Content -LiteralPath (Join-Path $root ('open-run-{0}-headless-drill.vbs' -f $pairId)) -Raw -Encoding UTF8
    Assert-Match -Text $pairOpenText -Pattern 'open-preset-headless-pair-drill\.vbs' -Message ("{0} open wrapper should delegate to the generic open wrapper." -f $pairId)
    Assert-Match -Text $pairOpenText -Pattern $pairId -Message ("{0} open wrapper should pin its preset pair id." -f $pairId)
}

Write-Host 'preset headless pair drill shortcut wrappers ok'
