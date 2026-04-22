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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
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
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_target_submit_wrappers_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$sourceRoot = Join-Path $contractRunRoot '_external_wrapper_source'
New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null

$summarySourcePath = Join-Path $sourceRoot 'wrapper-summary.md'
$zipNotePath = Join-Path $sourceRoot 'wrapper-note.txt'
$zipSourcePath = Join-Path $sourceRoot 'wrapper-review.zip'

[System.IO.File]::WriteAllText($summarySourcePath, 'wrapper smoke summary', (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($zipNotePath, 'wrapper smoke zip content', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $zipSourcePath -Force

$target01Root = Join-Path $contractRunRoot 'pair01\target01'
$target05Root = Join-Path $contractRunRoot 'pair01\target05'
$target01CheckPath = Join-Path $target01Root 'check-artifact.ps1'
$target01SubmitPath = Join-Path $target01Root 'submit-artifact.ps1'
$target05CheckPath = Join-Path $target05Root 'check-artifact.ps1'

$commonArgs = @(
    '-SummarySourcePath', $summarySourcePath,
    '-ReviewZipSourcePath', $zipSourcePath,
    '-AsJson'
)

$target01Check = Invoke-PowerShellJson -ScriptPath $target01CheckPath -Arguments $commonArgs
Assert-True ($target01Check.ExitCode -eq 0) 'target01 check wrapper should succeed.'
Assert-True ([bool]$target01Check.Json.Validation.Ok) 'target01 check wrapper validation should be ok.'
Assert-True ([string]$target01Check.Json.Target.TargetId -eq 'target01') 'target01 check wrapper should pin target01.'

$target05Check = Invoke-PowerShellJson -ScriptPath $target05CheckPath -Arguments $commonArgs
Assert-True ($target05Check.ExitCode -eq 0) 'target05 check wrapper should succeed.'
Assert-True ([bool]$target05Check.Json.Validation.Ok) 'target05 check wrapper validation should be ok.'
Assert-True ([string]$target05Check.Json.Target.TargetId -eq 'target05') 'target05 check wrapper should pin target05.'

$target01Submit = Invoke-PowerShellJson -ScriptPath $target01SubmitPath -Arguments $commonArgs
Assert-True ($target01Submit.ExitCode -eq 0) 'target01 submit wrapper should succeed.'
Assert-True ([bool]$target01Submit.Json.Validation.Ok) 'target01 submit wrapper validation should be ok.'
Assert-True ([string]$target01Submit.Json.Target.TargetId -eq 'target01') 'target01 submit wrapper should pin target01.'
Assert-True ([string]$target01Submit.Json.PostImportStatus.LatestState -eq 'ready-to-forward') 'target01 submit wrapper should drive ready-to-forward state.'
Assert-True ((Test-Path -LiteralPath ([string]$target01Submit.Json.Contract.SummaryPath) -PathType Leaf)) 'target01 submit wrapper should write summary to contract path.'
Assert-True ((Test-Path -LiteralPath ([string]$target01Submit.Json.Contract.DestinationZipPath) -PathType Leaf)) 'target01 submit wrapper should write review zip to contract path.'

$repeatSubmit = Invoke-PowerShellJson -ScriptPath $target01SubmitPath -Arguments $commonArgs
Assert-True ($repeatSubmit.ExitCode -ne 0) 'target01 submit wrapper should preserve overwrite guard.'
$repeatIssues = @($repeatSubmit.Json.Validation.Issues | ForEach-Object { [string]$_ })
Assert-True ('overwrite-required-existing-target-state' -in $repeatIssues) 'wrapper repeat submit should block on existing target state.'

Write-Host ('paired-exchange target submit wrappers ok: runRoot=' + $contractRunRoot)
