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

function Invoke-PowerShellJson {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $ScriptPath @Arguments
    $exitCode = $LASTEXITCODE
    $raw = ($result | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "script returned no output: $ScriptPath"
    }

    try {
        $json = $raw | ConvertFrom-Json
    }
    catch {
        throw "json parse failed: $ScriptPath raw=$raw"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Raw      = $raw
        Json     = $json
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_headless_dispatch_status_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$dispatchRoot = Join-Path $contractRunRoot '.state\headless-dispatch'
New-Item -ItemType Directory -Path $dispatchRoot -Force | Out-Null

([ordered]@{
        SchemaVersion = '1.0.0'
        TargetId      = 'target01'
        State         = 'running'
        Reason        = ''
        StartedAt     = (Get-Date).AddSeconds(-15).ToString('o')
        CompletedAt   = ''
        ExitCode      = $null
        UpdatedAt     = (Get-Date).AddSeconds(-1).ToString('o')
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $dispatchRoot 'dispatch_target01.json') -Encoding UTF8

([ordered]@{
        SchemaVersion = '1.0.0'
        TargetId      = 'target01'
        State         = 'completed'
        Reason        = ''
        StartedAt     = (Get-Date).AddSeconds(-20).ToString('o')
        CompletedAt   = (Get-Date).AddSeconds(-5).ToString('o')
        ExitCode      = 0
        UpdatedAt     = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $dispatchRoot 'current_target01.json') -Encoding UTF8

([ordered]@{
        SchemaVersion = '1.0.0'
        TargetId      = 'target05'
        State         = 'completed'
        Reason        = ''
        StartedAt     = (Get-Date).AddSeconds(-45).ToString('o')
        CompletedAt   = (Get-Date).AddSeconds(-30).ToString('o')
        ExitCode      = 0
        UpdatedAt     = (Get-Date).AddSeconds(-30).ToString('o')
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $dispatchRoot 'current_target05.json') -Encoding UTF8

$status = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'show-paired-exchange-status.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-AsJson'
)

Assert-True ($status.ExitCode -eq 0) 'show paired exchange status should succeed for dispatch status contract test.'
Assert-True ([int]$status.Json.HeadlessDispatch.StatusFileCount -eq 2) 'dispatch status contract should count both neutral and legacy status files.'
Assert-True ([int]$status.Json.HeadlessDispatch.CurrentFileCount -eq 2) 'current file count bridge should remain aligned with status file count.'
Assert-True ([int]$status.Json.HeadlessDispatch.RunningCount -eq 1) 'dispatch status contract should count one running dispatch.'
Assert-True ([int]$status.Json.HeadlessDispatch.CompletedCount -eq 1) 'dispatch status contract should count one completed dispatch.'
Assert-True ([int]$status.Json.HeadlessDispatch.FailedCount -eq 0) 'dispatch status contract should count zero failed dispatches.'

$target01 = @($status.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$target05 = @($status.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target05' } | Select-Object -First 1)[0]
Assert-True ([string]$target01.DispatchState -eq 'running') 'target01 should surface running dispatch state from dispatch_ status file.'
Assert-True ([string]$target05.DispatchState -eq 'completed') 'target05 should surface completed dispatch state from legacy current_ status file.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target01.DispatchUpdatedAt)) 'target01 should surface dispatch updated timestamp.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target05.DispatchUpdatedAt)) 'target05 should surface dispatch updated timestamp.'
Assert-True ([string]$target01.DispatchState -ne 'completed') 'dispatch_ status file must win over newer legacy current_ status for the same target.'

Write-Host ('show-paired-exchange headless dispatch status contract ok: runRoot=' + $contractRunRoot)
