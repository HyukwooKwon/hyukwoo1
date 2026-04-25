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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-start-targets-replace-existing-blocked'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$runtimeRoot = Join-Path $testRoot 'runtime'
$logsRoot = Join-Path $testRoot 'logs'
New-Item -ItemType Directory -Path $runtimeRoot,$logsRoot -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    Root = '$($testRoot.Replace("'", "''"))'
    LaneName = 'bottest-live-visible'
    LauncherWrapperPath = 'C:\dummy\wrapper.py'
    WindowLaunch = @{
        DirectStartAllowed = `$true
        AllowReplaceExisting = `$false
        DirectStartAllowEnvVar = 'TEST_ALLOW_DIRECT_START_VISIBLE'
        ReplaceExistingAllowEnvVar = 'TEST_ALLOW_REPLACE_EXISTING_VISIBLE'
    }
    RuntimeRoot = '$($runtimeRoot.Replace("'", "''"))'
    LogsRoot = '$($logsRoot.Replace("'", "''"))'
    RuntimeMapPath = '$($(Join-Path $runtimeRoot 'target-runtime.json').Replace("'", "''"))'
    ShellPath = 'powershell.exe'
    Targets = @()
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$startTargetsPath = (Join-Path $root 'launcher\Start-Targets.ps1').Replace("'", "''")
$escapedConfigPath = $configPath.Replace("'", "''")
$stdoutPath = Join-Path $testRoot 'replace-existing.stdout.log'
$stderrPath = Join-Path $testRoot 'replace-existing.stderr.log'
$process = Start-Process -FilePath 'pwsh.exe' -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-Command',
    @"
`$env:TEST_ALLOW_DIRECT_START_VISIBLE = '1'
`$env:TEST_ALLOW_REPLACE_EXISTING_VISIBLE = '1'
`$env:RELAY_ALLOW_UNSAFE_FORCE_KILL = '1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File '$startTargetsPath' -ConfigPath '$escapedConfigPath' -ReplaceExisting -UnsafeForceKillManagedTargets
exit `$LASTEXITCODE
"@
) -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

Assert-True ($process.ExitCode -ne 0) 'Start-Targets -ReplaceExisting should still fail when the wrapper-managed lane disallows replace-existing.'
$text = ((Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8) + [Environment]::NewLine + (Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8)) -replace '\x1b\[[0-9;]*m', ''
Assert-True ($text.Contains('ReplaceExisting is blocked for wrapper-managed lanes')) 'ReplaceExisting block message should mention wrapper-managed shared lane policy.'

Write-Host 'start-targets replace-existing blocked for shared wrapper lane ok'
