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

function Assert-SequenceEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw ($Message + " count mismatch expected=" + $Expected.Count + " actual=" + $Actual.Count)
    }

    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$Actual[$index] -ne [string]$Expected[$index]) {
            throw ($Message + " mismatch at index " + $index + " expected=" + $Expected[$index] + " actual=" + $Actual[$index])
        }
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'launcher\WindowDiscovery.ps1')

$provider = {
    @(
        [pscustomobject]@{
            Visible   = $true
            Hwnd      = 101
            ProcessId = 201
            Title     = 'alpha'
            ClassName = 'ConsoleWindowClass'
            Rect      = @(10, 20, 210, 260)
        },
        [pscustomobject]@{
            Visible   = $false
            Hwnd      = 102
            ProcessId = 202
            Title     = 'hidden'
            ClassName = 'HiddenWindow'
            Rect      = @(0, 0, 0, 0)
        },
        [pscustomobject]@{
            Visible   = $true
            Hwnd      = 103
            ProcessId = 203
            Title     = ''
            ClassName = 'BlankTitle'
        },
        [pscustomobject]@{
            Hwnd      = 104
            ProcessId = 204
            Title     = 'bravo'
            ClassName = 'CASCADIA_HOST'
        }
    )
}

$basicRows = @(Get-VisibleWindows -WindowProvider $provider)
Assert-True ($basicRows.Count -eq 2) 'Expected hidden and blank-title windows to be excluded from the launcher contract.'
Assert-SequenceEqual -Actual @($basicRows[0].PSObject.Properties.Name) -Expected @('Hwnd', 'ProcessId', 'Title', 'ClassName') -Message 'Basic visible window contract fields must stay fixed.'
Assert-True ($basicRows[0].Hwnd -eq 101) 'Expected hwnd to remain on the visible window contract.'
Assert-True ($basicRows[0].ProcessId -eq 201) 'Expected process id to remain on the visible window contract.'
Assert-True ($basicRows[0].Title -eq 'alpha') 'Expected title to remain on the visible window contract.'
Assert-True ($basicRows[0].ClassName -eq 'ConsoleWindowClass') 'Expected class name to remain on the visible window contract.'
Assert-True ($basicRows[0].PSObject.Properties['Rect'] -eq $null) 'Rect must stay opt-in for scripts that do not request geometry.'

$rectRows = @(Get-VisibleWindows -IncludeRect -WindowProvider $provider)
Assert-True ($rectRows.Count -eq 2) 'Expected IncludeRect mode to preserve visible-window filtering.'
Assert-SequenceEqual -Actual @($rectRows[0].PSObject.Properties.Name) -Expected @('Hwnd', 'ProcessId', 'Title', 'ClassName', 'Rect') -Message 'Rect-inclusive window contract fields must stay fixed.'
Assert-SequenceEqual -Actual @($rectRows[0].Rect) -Expected @(10, 20, 210, 260) -Message 'Expected Rect coordinates to remain ordered left/top/right/bottom.'
Assert-True (@($rectRows[1].Rect).Count -eq 0) 'Expected missing geometry to serialize as an empty Rect array.'

$launcherScripts = @(
    'launcher\Attach-Targets.ps1',
    'launcher\Attach-TargetsFromBindings.ps1',
    'launcher\Check-TargetWindowVisibility.ps1',
    'launcher\Refresh-BindingProfileFromExisting.ps1',
    'launcher\Start-Targets.ps1'
)

foreach ($relativePath in $launcherScripts) {
    $fullPath = Join-Path $root $relativePath
    $text = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
    Assert-True ($text.Contains("WindowDiscovery.ps1")) ("Expected shared window helper import in " + $relativePath)
    Assert-True (-not $text.Contains('function Ensure-WindowApiType')) ("Local Ensure-WindowApiType definition should be removed from " + $relativePath)
    Assert-True (-not $text.Contains('function Get-VisibleWindows')) ("Local Get-VisibleWindows definition should be removed from " + $relativePath)
}

$refreshScriptPath = Join-Path $root 'launcher\Refresh-BindingProfileFromExisting.ps1'
$refreshScriptText = Get-Content -LiteralPath $refreshScriptPath -Raw -Encoding UTF8
Assert-True ($refreshScriptText.Contains('Get-VisibleWindows -IncludeRect')) 'Refresh-BindingProfileFromExisting must explicitly opt in to Rect geometry.'

Write-Host 'launcher window discovery contract ok'
