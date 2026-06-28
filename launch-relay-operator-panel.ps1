[CmdletBinding()]
param(
    [switch]$KeepExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$scriptPath = Join-Path $root 'relay_operator_panel.py'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "relay_operator_panel.py 파일을 찾지 못했습니다: $scriptPath"
}

$scriptItem = Get-Item -LiteralPath $scriptPath
$scriptFullPath = [System.IO.Path]::GetFullPath($scriptItem.FullName)
$scriptLastWriteTime = $scriptItem.LastWriteTime

function Test-PanelProcessForThisScript {
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][string]$PanelScriptPath
    )

    $commandLine = [string]$Process.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }
    return ($commandLine.IndexOf($PanelScriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

if (-not $KeepExisting) {
    $existingPanelProcesses = @(
        Get-CimInstance Win32_Process |
            Where-Object { Test-PanelProcessForThisScript -Process $_ -PanelScriptPath $scriptFullPath }
    )
    $stalePanelProcesses = @(
        $existingPanelProcesses |
            Where-Object {
                $null -ne $_.CreationDate -and $_.CreationDate -lt $scriptLastWriteTime
            }
    )

    foreach ($process in $stalePanelProcesses) {
        Write-Host ("stopping stale relay operator panel pid={0} started={1} sourceModified={2}" -f $process.ProcessId, $process.CreationDate, $scriptLastWriteTime)
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

$tkProbeCode = 'import tkinter as tk; root = tk.Tk(); root.withdraw(); root.update_idletasks(); root.destroy()'

function Get-CommandPathCandidates {
    param(
        [Parameter(Mandatory)][string]$Name
    )

    @(
        Get-Command -Name $Name -All -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.Source) {
                    [string]$_.Source
                } elseif ($_.Path) {
                    [string]$_.Path
                } else {
                    [string]$_.Name
                }
            } |
            Select-Object -Unique
    )
}

function Get-SiblingConsolePython {
    param(
        [Parameter(Mandatory)][string]$PythonwPath
    )

    $candidate = Join-Path (Split-Path -Parent $PythonwPath) 'python.exe'
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    return $null
}

function Test-PythonTkUsable {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Args = @()
    )

    $probeArgs = @()
    if ($null -ne $Args) {
        $probeArgs += $Args
    }
    $probeArgs += @('-c', $script:tkProbeCode)

    try {
        $probeOutput = & $FilePath @probeArgs 2>&1
        $exitCode = [int]$LASTEXITCODE
    } catch {
        return [pscustomobject]@{
            Ok = $false
            Detail = $_.Exception.Message
        }
    }

    if ($exitCode -eq 0) {
        return [pscustomobject]@{
            Ok = $true
            Detail = ''
        }
    }

    $detail = (($probeOutput | Out-String).Trim() -replace '\s+', ' ')
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = "exit code $exitCode"
    } elseif ($detail.Length -gt 240) {
        $detail = $detail.Substring(0, 240) + '...'
    }

    return [pscustomobject]@{
        Ok = $false
        Detail = $detail
    }
}

$candidates = @()
$pyPaths = Get-CommandPathCandidates -Name 'py'

foreach ($pythonwPath in Get-CommandPathCandidates -Name 'pythonw') {
    $probePath = Get-SiblingConsolePython -PythonwPath $pythonwPath
    if ([string]::IsNullOrWhiteSpace($probePath)) {
        continue
    }
    $candidates += [pscustomobject]@{
        Label = $pythonwPath
        LaunchPath = $pythonwPath
        LaunchArgs = @($scriptPath)
        ProbePath = $probePath
        ProbeArgs = @()
    }
}

foreach ($pywPath in Get-CommandPathCandidates -Name 'pyw') {
    foreach ($pyPath in $pyPaths) {
        $candidates += [pscustomobject]@{
            Label = "$pywPath -3"
            LaunchPath = $pywPath
            LaunchArgs = @('-3', $scriptPath)
            ProbePath = $pyPath
            ProbeArgs = @('-3')
        }
    }
}

foreach ($pyPath in $pyPaths) {
    $candidates += [pscustomobject]@{
        Label = "$pyPath -3"
        LaunchPath = $pyPath
        LaunchArgs = @('-3', $scriptPath)
        ProbePath = $pyPath
        ProbeArgs = @('-3')
    }
}

foreach ($pythonPath in Get-CommandPathCandidates -Name 'python') {
    $candidates += [pscustomobject]@{
        Label = $pythonPath
        LaunchPath = $pythonPath
        LaunchArgs = @($scriptPath)
        ProbePath = $pythonPath
        ProbeArgs = @()
    }
}

$probeFailures = @()
foreach ($candidate in $candidates) {
    $probe = Test-PythonTkUsable -FilePath ([string]$candidate.ProbePath) -Args ([string[]]$candidate.ProbeArgs)
    if (-not $probe.Ok) {
        $probeFailures += ("{0}: {1}" -f $candidate.Label, $probe.Detail)
        continue
    }

    Write-Host ("starting relay operator panel with {0}" -f $candidate.Label)
    Start-Process -FilePath ([string]$candidate.LaunchPath) -ArgumentList @($candidate.LaunchArgs) | Out-Null
    exit 0
}

if ($probeFailures.Count -gt 0) {
    throw "사용 가능한 tkinter Python을 찾지 못했습니다.`n$($probeFailures -join "`n")"
}

throw 'PATH에서 pyw/pythonw/py/python을 찾지 못했습니다.'
