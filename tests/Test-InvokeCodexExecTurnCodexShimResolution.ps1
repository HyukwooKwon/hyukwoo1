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

function Resolve-NodeExecutable {
    foreach ($name in @('node.exe', 'node')) {
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

    throw 'node executable을 찾지 못했습니다.'
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

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return $Value.Replace("'", "''")
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_exec_codex_shim_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$shimRoot = Join-Path $contractRunRoot 'fake-npm'
$shimPath = Join-Path $shimRoot 'codex.ps1'
$codexEntryPath = Join-Path $shimRoot 'node_modules\@openai\codex\bin\codex.js'
New-Item -ItemType Directory -Path (Split-Path -Parent $codexEntryPath) -Force | Out-Null
[System.IO.File]::WriteAllText($shimPath, "# fake codex powershell shim`n", (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($codexEntryPath, "// fake codex js entry`n", (New-Utf8NoBomEncoding))

$shimConfigPath = Join-Path $contractRunRoot 'settings.headless-codex-shim.psd1'
$shimConfigRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$shimConfigRaw = [System.Text.RegularExpressions.Regex]::Replace(
    $shimConfigRaw,
    "(?m)(CodexExecutable\s*=\s*)'[^']*'",
    ('$1' + "'" + (ConvertTo-PowerShellSingleQuotedLiteral -Value $shimPath) + "'")
)
[System.IO.File]::WriteAllText($shimConfigPath, $shimConfigRaw, (New-Utf8NoBomEncoding))

$dryRun = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $shimConfigPath,
    '-RunRoot', $contractRunRoot,
    '-TargetId', 'target01',
    '-DryRun',
    '-AsJson'
)

$expectedNodePath = Resolve-NodeExecutable

Assert-True ($dryRun.ExitCode -eq 0) 'codex shim dry-run should succeed.'
Assert-True ([string]$dryRun.Json.CodexResolvedPath -eq $shimPath) 'dry-run should report the resolved shim path.'
Assert-True ([string]$dryRun.Json.LaunchFilePath -eq $expectedNodePath) 'dry-run should bypass the powershell shim and launch node directly.'
Assert-True (@($dryRun.Json.ArgumentList).Count -ge 1) 'dry-run should report an argument list.'
Assert-True ([string]$dryRun.Json.ArgumentList[0] -eq $codexEntryPath) 'first launch argument should be the codex.js entrypoint.'
Assert-True (@($dryRun.Json.ArgumentList) -contains 'exec') 'launch arguments should preserve the codex exec subcommand.'

Write-Host ('invoke-codex-exec-turn codex shim resolution ok: runRoot=' + $contractRunRoot)
