[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$scriptPath = Join-Path $root 'relay_operator_panel.py'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "relay_operator_panel.py 파일을 찾지 못했습니다: $scriptPath"
}

$candidates = @(
    @{ Name = 'pyw'; Args = @('-3', $scriptPath) }
    @{ Name = 'pythonw'; Args = @($scriptPath) }
    @{ Name = 'py'; Args = @('-3', $scriptPath) }
    @{ Name = 'python'; Args = @($scriptPath) }
)

foreach ($candidate in $candidates) {
    $command = Get-Command -Name ([string]$candidate.Name) -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        continue
    }

    $filePath = if ($command.Source) { [string]$command.Source } elseif ($command.Path) { [string]$command.Path } else { [string]$candidate.Name }
    Start-Process -FilePath $filePath -ArgumentList @($candidate.Args) | Out-Null
    exit 0
}

throw 'PATH에서 pyw/pythonw/py/python을 찾지 못했습니다.'
