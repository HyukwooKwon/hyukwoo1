[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Text = "manual-e2e target01`r`n이 문장이 target01 창에 그대로 들어가야 합니다.",
    [switch]$StartTargets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

$root = Split-Path -Parent $PSScriptRoot
$config = Import-PowerShellDataFile -Path $ConfigPath

if ($StartTargets) {
    & (Join-Path $root 'launcher\Ensure-Targets.ps1') -ConfigPath $ConfigPath
}

if (-not (Test-Path -LiteralPath ([string]$config.RuntimeMapPath))) {
    throw "Runtime map not found: $($config.RuntimeMapPath)"
}

$runtimeParsed = Get-Content -LiteralPath ([string]$config.RuntimeMapPath) -Raw -Encoding UTF8 | ConvertFrom-Json
$runtime = if ($null -eq $runtimeParsed) {
    @()
}
elseif ($runtimeParsed -is [System.Array]) {
    $runtimeParsed
}
else {
    ,$runtimeParsed
}
$target = $runtime | Where-Object { $_.TargetId -eq 'target01' } | Select-Object -First 1

if ($null -eq $target) {
    throw 'target01 runtime entry not found'
}

$payloadPath = Join-Path ([string]$config.LogsRoot) ('manual_e2e_target01_' + [guid]::NewGuid().ToString('N') + '.txt')
[System.IO.File]::WriteAllText($payloadPath, $Text, [System.Text.UTF8Encoding]::new($false))

try {
    $proc = Start-Process -FilePath ([string]$config.AhkExePath) -ArgumentList @(
        [string]$config.AhkScriptPath,
        '--runtime', [string]$config.RuntimeMapPath,
        '--targetId', 'target01',
        '--resolverShell', [string]$config.ResolverShellPath,
        '--file', $payloadPath,
        '--enter', '1',
        '--timeoutMs', [string]$config.SendTimeoutMs
    ) -Wait -PassThru

    Write-Host ("target01 hwnd={0} windowPid={1} shellPid={2} resolvedBy={3}" -f $target.Hwnd, $target.WindowPid, $target.ShellPid, $target.ResolvedBy)
    if ($target.LookupSucceededAt) {
        Write-Host ("lookup succeeded at: {0}" -f $target.LookupSucceededAt)
    }
    Write-Host ("sender exit code: {0}" -f $proc.ExitCode)
    Write-Host '화면에서 target01 창에 본문과 Enter가 실제로 들어갔는지 확인하세요.'
}
finally {
    if (Test-Path -LiteralPath $payloadPath) {
        Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
    }
}
