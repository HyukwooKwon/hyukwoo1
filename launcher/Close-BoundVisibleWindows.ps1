param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [switch]$Apply,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace RelayUser32 {
    public static class NativeMethods {
        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool PostMessageW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);
    }
}
"@

$WM_CLOSE = 0x0010

function ConvertTo-HwndInt64 {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) { return 0L }
    try {
        return [int64]$Value
    } catch {
        return 0L
    }
}

function Test-LiveHwnd {
    param(
        [Parameter(Mandatory = $true)]
        [int64]$Hwnd
    )

    if ($Hwnd -le 0) { return $false }
    $ptr = [IntPtr]::new($Hwnd)
    return [RelayUser32.NativeMethods]::IsWindow($ptr) -and [RelayUser32.NativeMethods]::IsWindowVisible($ptr)
}

function Request-CloseHwnd {
    param(
        [Parameter(Mandatory = $true)]
        [int64]$Hwnd
    )

    if ($Hwnd -le 0) { return $false }
    $ptr = [IntPtr]::new($Hwnd)
    return [RelayUser32.NativeMethods]::PostMessageW($ptr, [uint32]$WM_CLOSE, [UIntPtr]::Zero, [IntPtr]::Zero)
}

$resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "ConfigPath not found: $resolvedConfigPath"
}

$config = Import-PowerShellDataFile -LiteralPath $resolvedConfigPath
$bindingProfilePath = [string]$config.BindingProfilePath
if ([string]::IsNullOrWhiteSpace($bindingProfilePath)) {
    throw "BindingProfilePath missing in config: $resolvedConfigPath"
}
if (-not (Test-Path -LiteralPath $bindingProfilePath)) {
    throw "BindingProfilePath not found: $bindingProfilePath"
}

$binding = Get-Content -LiteralPath $bindingProfilePath -Raw | ConvertFrom-Json
$windows = @($binding.windows)
if (-not $windows -or $windows.Count -eq 0) {
    throw "Binding profile contains no windows: $bindingProfilePath"
}

$seen = @{}
$targets = @()
foreach ($window in $windows) {
    $targetId = [string]$window.target_id
    $hwnd = ConvertTo-HwndInt64 -Value $window.hwnd
    if ($hwnd -le 0) { continue }
    if ($seen.ContainsKey($hwnd)) { continue }
    $seen[$hwnd] = $true
    $live = Test-LiveHwnd -Hwnd $hwnd
    $closeRequested = $false
    if ($Apply -and $live) {
        $closeRequested = Request-CloseHwnd -Hwnd $hwnd
    }
    $targets += [pscustomobject]@{
        TargetId       = $targetId
        Hwnd           = $hwnd
        WindowTitle    = [string]$window.window_title
        Live           = $live
        CloseRequested = $closeRequested
    }
}

$launcherSessionId = ''
if ($binding.PSObject.Properties.Name -contains 'launcher_session_id') {
    $launcherSessionId = [string]$binding.launcher_session_id
}

$result = [ordered]@{
    ConfigPath            = $resolvedConfigPath
    BindingProfilePath    = $bindingProfilePath
    LauncherSessionId     = $launcherSessionId
    BindingUpdatedAt      = [string]$binding.updated_at
    Apply                 = [bool]$Apply
    BindingWindowCount    = @($targets).Count
    LiveBindingWindowCount = @($targets | Where-Object { $_.Live }).Count
    CloseRequestedCount   = @($targets | Where-Object { $_.CloseRequested }).Count
    Note                  = 'Only binding-managed HWNDs are targeted. No broad title-based close is performed.'
    Targets               = @($targets)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
    return
}

$result
