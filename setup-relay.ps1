[CmdletBinding()]
param(
    [string]$Root
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Split-Path -Parent $PSCommandPath) }
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Get-RelayMutexName {
    param([Parameter(Mandatory)][string]$Root)

    $leaf = Split-Path -Leaf $Root
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = 'relay'
    }

    $safeLeaf = ($leaf -replace '[^A-Za-z0-9_]', '_')
    return ('Global\RelayRouter_' + $safeLeaf)
}

function New-SettingsPsd1Content {
    param([Parameter(Mandatory)][string]$Root)

    $escapedRoot = $Root.Replace("'", "''")
    $mutexName = (Get-RelayMutexName -Root $Root).Replace("'", "''")
    $targets = foreach ($number in 1..8) {
        $suffix = '{0:d2}' -f $number
        "        @{ Id='target$suffix'; WindowTitle='Relay-Target-$suffix'; Folder='$escapedRoot\inbox\target$suffix'; EnterCount=1; FixedSuffix=`$null }"
    }

    return @"
@{
    Root                 = '$escapedRoot'
    InboxRoot            = '$escapedRoot\inbox'
    ProcessedRoot        = '$escapedRoot\processed'
    FailedRoot           = '$escapedRoot\failed'
    RetryPendingRoot     = '$escapedRoot\retry-pending'
    RuntimeRoot          = '$escapedRoot\runtime'
    RuntimeMapPath       = '$escapedRoot\runtime\target-runtime.json'
    RouterStatePath      = '$escapedRoot\runtime\router-state.json'
    RouterMutexName      = '$mutexName'
    LogsRoot             = '$escapedRoot\logs'
    RouterLogPath        = '$escapedRoot\logs\router.log'
    AhkExePath           = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    AhkScriptPath        = '$escapedRoot\sender\SendToWindow.ahk'
    ShellPath            = 'pwsh.exe'
    ResolverShellPath    = 'pwsh.exe'
    DefaultEnterCount    = 1
    DefaultFixedSuffix   = '여기에 고정문구 입력'
    MaxPayloadChars      = 4000
    MaxPayloadBytes      = 12000
    SweepIntervalMs      = 2000
    IdleSleepMs          = 250
    RetryDelayMs         = 1000
    MaxRetryCount        = 1
    SendTimeoutMs        = 5000
    WindowLookupTimeoutMs = 12000
    WindowLookupRetryCount = 1
    WindowLookupRetryDelayMs = 750
    Targets              = @(
$(($targets -join "`r`n"))
    )
}
"@
}

$folders = @(
    $Root,
    (Join-Path $Root 'config'),
    (Join-Path $Root 'runtime'),
    (Join-Path $Root 'launcher'),
    (Join-Path $Root 'router'),
    (Join-Path $Root 'sender'),
    (Join-Path $Root 'tests'),
    (Join-Path $Root 'inbox'),
    (Join-Path $Root 'processed'),
    (Join-Path $Root 'failed'),
    (Join-Path $Root 'retry-pending'),
    (Join-Path $Root 'logs'),
    (Join-Path $Root 'reviewfile')
)

foreach ($number in 1..8) {
    $suffix = '{0:d2}' -f $number
    $folders += (Join-Path $Root "inbox\target$suffix")
}

foreach ($folder in $folders) {
    Ensure-Directory -Path $folder
}

$configPath = Join-Path $Root 'config\settings.psd1'
if (-not (Test-Path -LiteralPath $configPath)) {
    $content = New-SettingsPsd1Content -Root $Root
    [System.IO.File]::WriteAllText($configPath, $content, (New-Utf8NoBomEncoding))
    Write-Host "created: $configPath"
}
else {
    Write-Host "exists: $configPath"
}

$runtimeMapPath = Join-Path $Root 'runtime\target-runtime.json'
if (-not (Test-Path -LiteralPath $runtimeMapPath)) {
    [System.IO.File]::WriteAllText($runtimeMapPath, '[]', (New-Utf8NoBomEncoding))
    Write-Host "created: $runtimeMapPath"
}
else {
    Write-Host "exists: $runtimeMapPath"
}

$routerStatePath = Join-Path $Root 'runtime\router-state.json'
if (-not (Test-Path -LiteralPath $routerStatePath)) {
    [System.IO.File]::WriteAllText($routerStatePath, '{}', (New-Utf8NoBomEncoding))
    Write-Host "created: $routerStatePath"
}
else {
    Write-Host "exists: $routerStatePath"
}

Write-Host "setup completed: $Root"
