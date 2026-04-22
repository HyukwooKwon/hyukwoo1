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
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_exec_dryrun_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$targetRoot = Join-Path $contractRunRoot 'pair01\target01'
$headlessPromptPath = Join-Path $targetRoot 'headless-prompt.txt'
$donePath = Join-Path $targetRoot 'done.json'
$errorPath = Join-Path $targetRoot 'error.json'
$resultPath = Join-Path $targetRoot 'result.json'

$dryRun = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-TargetId', 'target01',
    '-DryRun',
    '-AsJson'
)

Assert-True ($dryRun.ExitCode -eq 0) 'dry-run should succeed even when headless exec is disabled.'
Assert-True ([bool]$dryRun.Json.DryRun) 'dry-run payload should report DryRun=true.'
Assert-True (-not [bool]$dryRun.Json.HeadlessExecEnabled) 'default settings should keep headless exec disabled for this contract.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$dryRun.Json.CompletedAt)) 'dry-run should populate CompletedAt.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$dryRun.Json.RequestPath)) 'dry-run should resolve request path.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$dryRun.Json.PromptSourcePath)) 'dry-run should resolve prompt source path.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$dryRun.Json.HeadlessPromptPath)) 'dry-run should report headless prompt path.'
Assert-True (-not (Test-Path -LiteralPath $headlessPromptPath)) 'dry-run should not write headless prompt files.'
Assert-True (-not (Test-Path -LiteralPath $donePath)) 'dry-run should not create done.json.'
Assert-True (-not (Test-Path -LiteralPath $errorPath)) 'dry-run should not create error.json.'
Assert-True (-not (Test-Path -LiteralPath $resultPath)) 'dry-run should not create result.json.'

$invalidConfigPath = Join-Path $contractRunRoot 'settings.invalid-headless.psd1'
$invalidConfigRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw
$invalidConfigRaw = [System.Text.RegularExpressions.Regex]::Replace(
    $invalidConfigRaw,
    "(?m)(CodexExecutable\s*=\s*)'[^']*'",
    "`$1'__missing_codex_executable_for_dryrun__'"
)
Set-Content -LiteralPath $invalidConfigPath -Value $invalidConfigRaw -Encoding UTF8

$dryRunMissingLaunch = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $invalidConfigPath,
    '-RunRoot', $contractRunRoot,
    '-TargetId', 'target01',
    '-DryRun',
    '-AsJson'
)

Assert-True ($dryRunMissingLaunch.ExitCode -eq 0) 'dry-run should stay successful when launch command resolution fails.'
Assert-True ([bool]$dryRunMissingLaunch.Json.DryRun) 'launch resolve failure dry-run should still report DryRun=true.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$dryRunMissingLaunch.Json.LaunchResolveError)) 'dry-run should surface LaunchResolveError for missing executable.'
Assert-True ([string]$dryRunMissingLaunch.Json.CodexResolvedPath -eq '') 'launch resolve failure dry-run should not report a resolved executable path.'
Assert-True (-not (Test-Path -LiteralPath $headlessPromptPath)) 'launch resolve failure dry-run should not write headless prompt files.'
Assert-True (-not (Test-Path -LiteralPath $donePath)) 'launch resolve failure dry-run should not create done.json.'
Assert-True (-not (Test-Path -LiteralPath $errorPath)) 'launch resolve failure dry-run should not create error.json.'
Assert-True (-not (Test-Path -LiteralPath $resultPath)) 'launch resolve failure dry-run should not create result.json.'

Write-Host ('invoke-codex-exec-turn dry-run contract ok: runRoot=' + $contractRunRoot)
