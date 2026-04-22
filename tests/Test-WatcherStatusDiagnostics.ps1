[CmdletBinding()]
param(
    [string]$ConfigPath
)

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

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }
        if ($command.Source) {
            return [string]$command.Source
        }
        if ($command.Path) {
            return [string]$command.Path
        }
        return [string]$name
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Invoke-ShowPairedStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'show-paired-exchange-status.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $RunRoot,
        '-AsJson'
    )
    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("show-paired-exchange-status failed: " + (($result | Out-String).Trim()))
    }
    return ($result | ConvertFrom-Json)
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_watcher_status_diag_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$stateRoot = Join-Path $contractRunRoot '.state'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$controlPath = Join-Path $stateRoot 'watcher-control.json'
$statusPath = Join-Path $stateRoot 'watcher-status.json'
Set-Content -LiteralPath $controlPath -Value '{"Action": "stop",' -Encoding UTF8
Set-Content -LiteralPath $statusPath -Value '{"State": "running",' -Encoding UTF8

$status = Invoke-ShowPairedStatus -Root $root -ResolvedConfigPath $resolvedConfigPath -RunRoot $contractRunRoot

Assert-True ($status.Watcher.ControlExists -eq $true) 'Expected control file to exist.'
Assert-True ($status.Watcher.StatusExists -eq $true) 'Expected status file to exist.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$status.Watcher.ControlParseError)) 'Expected control parse error.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$status.Watcher.StatusParseError)) 'Expected status parse error.'
Assert-True ($status.Watcher.ControlPath -eq $controlPath) 'Expected control path echo.'
Assert-True ($status.Watcher.StatusPath -eq $statusPath) 'Expected status path echo.'

Write-Host ('watcher-status diagnostics contract ok: runRoot=' + $contractRunRoot)
