[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimePath,
    [Parameter(Mandatory)][string]$TargetId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RuntimePath)) {
    exit 2
}

try {
    $raw = Get-Content -LiteralPath $RuntimePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        exit 2
    }

    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        $items = @()
    }
    elseif ($parsed -is [System.Array]) {
        $items = $parsed
    }
    else {
        $items = ,$parsed
    }
}
catch {
    exit 5
}

foreach ($item in $items) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.TargetId)) {
        exit 5
    }
}

$matches = @($items | Where-Object { $_.TargetId -eq $TargetId })
if ($matches.Count -gt 1) {
    exit 5
}

$target = $matches | Select-Object -First 1

if ($null -eq $target) {
    exit 3
}

$hwnd = if ($null -ne $target.Hwnd) { [string]$target.Hwnd } else { '' }
$windowPid = if ($null -ne $target.WindowPid) { [string]$target.WindowPid } else { '' }
$shellPid = if ($null -ne $target.ShellPid) { [string]$target.ShellPid } else { '' }
$title = if ($null -ne $target.Title) { [string]$target.Title } else { '' }

if ([string]::IsNullOrWhiteSpace($hwnd) -and [string]::IsNullOrWhiteSpace($windowPid) -and [string]::IsNullOrWhiteSpace($shellPid) -and [string]::IsNullOrWhiteSpace($title)) {
    exit 4
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Output ($hwnd + '|' + $windowPid + '|' + $shellPid + '|' + $title)
exit 0
