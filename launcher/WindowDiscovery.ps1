[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-WindowApiType {
    if ('Relay.WindowApi' -as [type]) {
        return
    }

    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace Relay {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static class WindowApi {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    }
}
'@
}

function Ensure-ForegroundWindowApiType {
    if ('Relay.ForegroundWindowApi' -as [type]) {
        return
    }

    Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace Relay {
    public static class ForegroundWindowApi {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
    }
}
'@
}

function New-WindowInfoRecord {
    param(
        [int64]$Hwnd = 0,
        [int]$ProcessId = 0,
        [AllowEmptyString()][string]$ProcessName = '',
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyString()][string]$ClassName = ''
    )

    return [pscustomobject][ordered]@{
        Hwnd        = [int64]$Hwnd
        ProcessId   = [int]$ProcessId
        ProcessName = [string]$ProcessName
        Title       = [string]$Title
        ClassName   = [string]$ClassName
    }
}

function Get-VisibleWindows {
    param(
        [switch]$IncludeRect,
        [scriptblock]$WindowProvider
    )

    $windows = New-Object System.Collections.Generic.List[object]

    if ($null -ne $WindowProvider) {
        foreach ($window in @(& $WindowProvider)) {
            if ($null -eq $window) {
                continue
            }

            $visibleProperty = $window.PSObject.Properties['Visible']
            if ($null -ne $visibleProperty -and -not [bool]$visibleProperty.Value) {
                continue
            }

            $titleProperty = $window.PSObject.Properties['Title']
            $title = if ($null -ne $titleProperty) { [string]$titleProperty.Value } else { '' }
            if ([string]::IsNullOrWhiteSpace($title)) {
                continue
            }

            $record = [ordered]@{
                Hwnd      = [int64]($window.PSObject.Properties['Hwnd'].Value)
                ProcessId = [int]($window.PSObject.Properties['ProcessId'].Value)
                Title     = $title
                ClassName = [string]$window.PSObject.Properties['ClassName'].Value
            }

            if ($IncludeRect) {
                $rectProperty = $window.PSObject.Properties['Rect']
                if ($null -ne $rectProperty -and $null -ne $rectProperty.Value) {
                    $rectValues = [int[]]@($rectProperty.Value | ForEach-Object { [int]$_ })
                }
                else {
                    $rectValues = [int[]]@()
                }
                $record.Rect = $rectValues
            }

            $windows.Add([pscustomobject]$record)
        }

        return $windows
    }

    Ensure-WindowApiType

    [Relay.WindowApi]::EnumWindows({
        param($hWnd, $lParam)

        if (-not [Relay.WindowApi]::IsWindowVisible($hWnd)) {
            return $true
        }

        $windowProcessId = 0
        [Relay.WindowApi]::GetWindowThreadProcessId($hWnd, [ref]$windowProcessId) | Out-Null

        $titleBuffer = [System.Text.StringBuilder]::new(1024)
        [Relay.WindowApi]::GetWindowText($hWnd, $titleBuffer, $titleBuffer.Capacity) | Out-Null
        $title = $titleBuffer.ToString()
        if ([string]::IsNullOrWhiteSpace($title)) {
            return $true
        }

        $classBuffer = [System.Text.StringBuilder]::new(256)
        [Relay.WindowApi]::GetClassName($hWnd, $classBuffer, $classBuffer.Capacity) | Out-Null

        $record = [ordered]@{
            Hwnd      = $hWnd.ToInt64()
            ProcessId = [int]$windowProcessId
            Title     = $title
            ClassName = $classBuffer.ToString()
        }

        if ($IncludeRect) {
            $rect = [Relay.RECT]::new()
            if ([Relay.WindowApi]::GetWindowRect($hWnd, [ref]$rect)) {
                $rectValues = [int[]]@(
                    [int]$rect.Left,
                    [int]$rect.Top,
                    [int]$rect.Right,
                    [int]$rect.Bottom
                )
            }
            else {
                $rectValues = [int[]]@()
            }
            $record.Rect = $rectValues
        }

        $windows.Add([pscustomobject]$record)
        return $true
    }, [IntPtr]::Zero) | Out-Null

    return $windows
}

function Get-ForegroundWindowInfo {
    param(
        [scriptblock]$WindowProvider,
        $ForegroundHwnd = $null
    )

    if ($null -ne $WindowProvider) {
        if ($null -eq $ForegroundHwnd -or [string]::IsNullOrWhiteSpace([string]$ForegroundHwnd)) {
            return (New-WindowInfoRecord)
        }

        $foregroundHwndText = [string]$ForegroundHwnd
        foreach ($window in @(& $WindowProvider)) {
            if ($null -eq $window) {
                continue
            }

            $hwndProperty = $window.PSObject.Properties['Hwnd']
            if ($null -eq $hwndProperty -or [string]$hwndProperty.Value -ne $foregroundHwndText) {
                continue
            }

            $processName = ''
            $processNameProperty = $window.PSObject.Properties['ProcessName']
            if ($null -ne $processNameProperty) {
                $processName = [string]$processNameProperty.Value
            }

            return (New-WindowInfoRecord `
                -Hwnd ([int64]$window.PSObject.Properties['Hwnd'].Value) `
                -ProcessId ([int]$window.PSObject.Properties['ProcessId'].Value) `
                -ProcessName $processName `
                -Title ([string]$window.PSObject.Properties['Title'].Value) `
                -ClassName ([string]$window.PSObject.Properties['ClassName'].Value))
        }

        return (New-WindowInfoRecord)
    }

    Ensure-WindowApiType
    Ensure-ForegroundWindowApiType

    $hWnd = [Relay.ForegroundWindowApi]::GetForegroundWindow()
    if ($hWnd -eq [IntPtr]::Zero) {
        return (New-WindowInfoRecord)
    }

    $windowProcessId = 0
    [Relay.WindowApi]::GetWindowThreadProcessId($hWnd, [ref]$windowProcessId) | Out-Null

    $titleBuffer = [System.Text.StringBuilder]::new(1024)
    [Relay.WindowApi]::GetWindowText($hWnd, $titleBuffer, $titleBuffer.Capacity) | Out-Null

    $classBuffer = [System.Text.StringBuilder]::new(256)
    [Relay.WindowApi]::GetClassName($hWnd, $classBuffer, $classBuffer.Capacity) | Out-Null

    $processName = ''
    if ([int]$windowProcessId -gt 0) {
        try {
            $processName = [string](Get-Process -Id ([int]$windowProcessId) -ErrorAction Stop).ProcessName
        }
        catch {
            $processName = ''
        }
    }

    return (New-WindowInfoRecord `
        -Hwnd $hWnd.ToInt64() `
        -ProcessId ([int]$windowProcessId) `
        -ProcessName $processName `
        -Title $titleBuffer.ToString() `
        -ClassName $classBuffer.ToString())
}
