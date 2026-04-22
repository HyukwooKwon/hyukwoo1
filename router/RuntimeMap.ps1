function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

. (Join-Path $PSScriptRoot 'RelayMessageMetadata.ps1')

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Read-RuntimeMap {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Runtime map not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = ConvertFrom-RelayJsonText -Json $raw
    if ($null -eq $parsed) {
        return @()
    }

    if ($parsed -is [System.Array]) {
        return $parsed
    }

    return ,$parsed
}

function Write-RuntimeMap {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Items
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $json = $Items | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Utf8NoBomEncoding))
}

function New-RuntimeMapEntry {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][int]$ShellPid,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$ShellPath,
        $Window = $null,
        [string]$ResolvedBy = '',
        [string]$LookupSucceededAt = '',
        [string]$LauncherSessionId = '',
        [string]$LaunchedAt = '',
        [int]$LauncherPid = 0,
        [string]$ProcessName = '',
        [string]$WindowClass = '',
        [string]$HostKind = '',
        [string]$RegistrationMode = '',
        [string]$ShellStartTimeUtc = '',
        [string]$ManagedMarker = ''
    )

    return [pscustomobject]@{
        TargetId          = $TargetId
        ShellPid          = $ShellPid
        WindowPid         = if ($null -ne $Window) { [int]$Window.ProcessId } else { $null }
        Hwnd              = if ($null -ne $Window) { [string]$Window.Hwnd } else { $null }
        Title             = $Title
        StartedAt         = (Get-Date).ToString('o')
        ShellPath         = $ShellPath
        Available         = [bool]($null -ne $Window)
        ResolvedBy        = $ResolvedBy
        LookupSucceededAt = $LookupSucceededAt
        LauncherSessionId = $LauncherSessionId
        LaunchedAt        = $LaunchedAt
        LauncherPid       = $LauncherPid
        ProcessName       = $ProcessName
        WindowClass       = $WindowClass
        HostKind          = $HostKind
        RegistrationMode  = $RegistrationMode
        ShellStartTimeUtc = $ShellStartTimeUtc
        ManagedMarker     = $ManagedMarker
    }
}

function Get-RuntimeMapByTargetId {
    param([Parameter(Mandatory)]$Items)

    $map = @{}
    foreach ($item in $Items) {
        $map[[string]$item.TargetId] = $item
    }

    return $map
}
