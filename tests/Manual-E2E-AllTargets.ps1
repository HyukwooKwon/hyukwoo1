[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TextPrefix = 'manual-e2e',
    [int]$DelayBetweenTargetsMs = 400,
    [switch]$StartTargets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Test-HasSendLocator {
    param([Parameter(Mandatory)]$RuntimeEntry)

    $runtimeHwnd = if ($null -ne $RuntimeEntry.Hwnd) { [string]$RuntimeEntry.Hwnd } else { '' }
    $runtimeWindowPid = if ($null -ne $RuntimeEntry.WindowPid) { [int]$RuntimeEntry.WindowPid } else { 0 }
    $runtimeShellPid = if ($null -ne $RuntimeEntry.ShellPid) { [int]$RuntimeEntry.ShellPid } else { 0 }
    $runtimeTitle = if ($null -ne $RuntimeEntry.Title) { [string]$RuntimeEntry.Title } else { '' }

    return (
        (Test-NonEmptyString $runtimeHwnd) -or
        ($runtimeWindowPid -gt 0) -or
        ($runtimeShellPid -gt 0) -or
        (Test-NonEmptyString $runtimeTitle)
    )
}

function Assert-RuntimeMapContract {
    param(
        [Parameter(Mandatory)]$RuntimeItems,
        [Parameter(Mandatory)]$ConfigTargets
    )

    $expectedIds = @($ConfigTargets | ForEach-Object { [string]$_.Id } | Sort-Object -Unique)
    $runtimeById = @{}
    $duplicateIds = New-Object System.Collections.Generic.List[string]
    $launcherSessionIds = @{}

    foreach ($item in $RuntimeItems) {
        $targetId = if ($null -ne $item.TargetId) { [string]$item.TargetId } else { '' }
        if (-not (Test-NonEmptyString $targetId)) {
            throw 'runtime map contains blank target id'
        }

        if ($runtimeById.ContainsKey($targetId)) {
            $duplicateIds.Add($targetId)
            continue
        }

        $launcherSessionId = if ($null -ne $item.LauncherSessionId) { [string]$item.LauncherSessionId } else { '' }
        if (-not (Test-NonEmptyString $launcherSessionId)) {
            throw ("runtime entry missing LauncherSessionId: {0}" -f $targetId)
        }

        $launcherSessionIds[$launcherSessionId] = $true
        $runtimeById[$targetId] = $item
    }

    if ($duplicateIds.Count -gt 0) {
        $duplicates = @($duplicateIds | Sort-Object -Unique)
        throw ("runtime map contains duplicate target ids: " + ($duplicates -join ', '))
    }

    $actualIds = @($runtimeById.Keys | Sort-Object)
    $missingIds = @($expectedIds | Where-Object { $_ -notin $actualIds })
    $extraIds = @($actualIds | Where-Object { $_ -notin $expectedIds })

    if ($missingIds.Count -gt 0 -or $extraIds.Count -gt 0) {
        $parts = @()
        if ($missingIds.Count -gt 0) {
            $parts += ('missing=' + ($missingIds -join ','))
        }
        if ($extraIds.Count -gt 0) {
            $parts += ('extra=' + ($extraIds -join ','))
        }

        throw ("runtime map target ids do not match config: " + ($parts -join '; '))
    }

    if ($runtimeById.Count -ne $expectedIds.Count) {
        throw ("runtime map target count mismatch: expected={0} actual={1}" -f $expectedIds.Count, $runtimeById.Count)
    }

    $uniqueLauncherSessionIds = @($launcherSessionIds.Keys | Sort-Object)
    if ($uniqueLauncherSessionIds.Count -ne 1) {
        throw ("runtime map must contain exactly one LauncherSessionId: " + ($uniqueLauncherSessionIds -join ', '))
    }

    foreach ($targetId in $expectedIds) {
        $entry = $runtimeById[$targetId]
        foreach ($propertyName in @('ResolvedBy', 'LookupSucceededAt', 'HostKind', 'LauncherSessionId')) {
            if (-not (Test-NonEmptyString $entry.$propertyName)) {
                throw ("runtime entry missing {0}: {1}" -f $propertyName, $targetId)
            }
        }

        if ($null -eq $entry.WindowPid -or [int]$entry.WindowPid -le 0) {
            throw ("runtime entry missing WindowPid: {0}" -f $targetId)
        }

        if ($null -eq $entry.ShellPid -or [int]$entry.ShellPid -le 0) {
            throw ("runtime entry missing ShellPid: {0}" -f $targetId)
        }

        if (-not (Test-HasSendLocator -RuntimeEntry $entry)) {
            throw ("runtime entry missing send locator (Hwnd/WindowPid/ShellPid/Title): {0}" -f $targetId)
        }
    }

    return $runtimeById
}

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
$runtimeById = Assert-RuntimeMapContract -RuntimeItems $runtime -ConfigTargets $config.Targets

$results = @()

foreach ($targetConfig in $config.Targets | Sort-Object Id) {
    $targetId = [string]$targetConfig.Id
    if (-not $runtimeById.ContainsKey($targetId)) {
        $results += [pscustomobject]@{
            TargetId = $targetId
            ExitCode = -1
            Result   = 'missing-runtime'
        }
        Write-Host ("{0} runtime entry not found" -f $targetId)
        continue
    }

    $target = $runtimeById[$targetId]
    $enterCount = if ($null -ne $targetConfig.EnterCount) { [int]$targetConfig.EnterCount } else { [int]$config.DefaultEnterCount }
    $text = "{0} {1}`r`n이 문장이 {1} 창에 그대로 들어가야 합니다." -f $TextPrefix, $targetId
    $payloadPath = Join-Path ([string]$config.LogsRoot) ('manual_e2e_' + $targetId + '_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($payloadPath, $text, [System.Text.UTF8Encoding]::new($false))

    try {
        $proc = Start-Process -FilePath ([string]$config.AhkExePath) -ArgumentList @(
            [string]$config.AhkScriptPath,
            '--runtime', [string]$config.RuntimeMapPath,
            '--targetId', $targetId,
            '--resolverShell', [string]$config.ResolverShellPath,
            '--file', $payloadPath,
            '--enter', [string]$enterCount,
            '--timeoutMs', [string]$config.SendTimeoutMs
        ) -Wait -PassThru

        $result = if ($proc.ExitCode -eq 0) { 'ok' } else { 'failed' }
        $results += [pscustomobject]@{
            TargetId = $targetId
            ExitCode = [int]$proc.ExitCode
            Result   = $result
        }

        Write-Host ("{0} hwnd={1} windowPid={2} shellPid={3} resolvedBy={4} hostKind={5} exit={6}" -f $targetId, $target.Hwnd, $target.WindowPid, $target.ShellPid, $target.ResolvedBy, $target.HostKind, $proc.ExitCode)
    }
    finally {
        if (Test-Path -LiteralPath $payloadPath) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($DelayBetweenTargetsMs -gt 0) {
        Start-Sleep -Milliseconds $DelayBetweenTargetsMs
    }
}

$successCount = @($results | Where-Object { $_.ExitCode -eq 0 }).Count
$failureCount = @($results | Where-Object { $_.ExitCode -ne 0 }).Count

Write-Host ("summary success={0} failure={1}" -f $successCount, $failureCount)
Write-Host '각 target 창에서 본문과 Enter가 실제로 들어갔는지 화면으로 확인하세요.'

if ($failureCount -gt 0) {
    exit 1
}

exit 0
