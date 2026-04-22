[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath,
    [string[]]$TargetId,
    [int]$OlderThanMinutes = 0,
    [string]$DestinationRoot = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Import-ConfigDataFile {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $importCommand = Get-Command -Name Import-PowerShellDataFile -ErrorAction SilentlyContinue
    if ($null -ne $importCommand) {
        return Import-PowerShellDataFile -Path $resolvedPath
    }

    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
    return [scriptblock]::Create($raw).InvokeReturnAsIs()
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-LaneNameFromTargets {
    param([Parameter(Mandatory)][object[]]$Targets)

    foreach ($target in @($Targets)) {
        $folder = [string]$target.Folder
        if (-not (Test-NonEmptyString $folder)) {
            continue
        }

        $parent = Split-Path -Parent $folder
        if (Test-NonEmptyString $parent) {
            return [System.IO.Path]::GetFileName($parent)
        }
    }

    return 'unknown-lane'
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-ConfigDataFile -Path $resolvedConfigPath
$targets = @($config.Targets)
$requestedTargetIds = @($TargetId | Where-Object { Test-NonEmptyString $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
$selectedTargets = if ($requestedTargetIds.Count -gt 0) {
    @($targets | Where-Object { [string]$_.Id -in $requestedTargetIds })
}
else {
    @($targets)
}

if ($requestedTargetIds.Count -gt 0) {
    $selectedIds = @($selectedTargets | ForEach-Object { [string]$_.Id })
    $missingIds = @($requestedTargetIds | Where-Object { $_ -notin $selectedIds })
    if ($missingIds.Count -gt 0) {
        throw ("unknown target id(s): " + ($missingIds -join ', '))
    }
}

$laneName = Get-LaneNameFromTargets -Targets $selectedTargets
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
if (-not (Test-NonEmptyString $DestinationRoot)) {
    $DestinationRoot = Join-Path $PSScriptRoot ("_tmp\ready-quarantine\{0}\{1}" -f $laneName, $stamp)
}
$resolvedDestinationRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
Ensure-Directory -Path $resolvedDestinationRoot

$cutoff = if ($OlderThanMinutes -gt 0) { (Get-Date).AddMinutes(-1 * $OlderThanMinutes) } else { $null }
$moved = New-Object System.Collections.Generic.List[object]

foreach ($target in @($selectedTargets)) {
    $targetFolder = [string]$target.Folder
    $targetIdValue = [string]$target.Id
    if (-not (Test-NonEmptyString $targetFolder)) {
        continue
    }
    if (-not (Test-Path -LiteralPath $targetFolder -PathType Container)) {
        continue
    }

    $destinationTargetRoot = Join-Path $resolvedDestinationRoot $targetIdValue
    Ensure-Directory -Path $destinationTargetRoot

    $readyFiles = @(
        Get-ChildItem -LiteralPath $targetFolder -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime, Name
    )

    foreach ($file in @($readyFiles)) {
        if ($null -ne $cutoff -and $file.LastWriteTime -gt $cutoff) {
            continue
        }

        $destinationPath = Join-Path $destinationTargetRoot $file.Name
        if ($PSCmdlet.ShouldProcess($file.FullName, "Move to $destinationPath")) {
            Move-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
            $moved.Add([pscustomobject]@{
                TargetId        = $targetIdValue
                SourcePath      = $file.FullName
                DestinationPath = $destinationPath
                LastWriteTime   = $file.LastWriteTime.ToString('o')
                FileName        = $file.Name
            })
        }
    }
}

$result = [ordered]@{
    SchemaVersion    = '1.0.0'
    ConfigPath       = $resolvedConfigPath
    LaneName         = $laneName
    DestinationRoot  = $resolvedDestinationRoot
    OlderThanMinutes = $OlderThanMinutes
    MovedCount       = $moved.Count
    Moved            = [object[]]$moved.ToArray()
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
    exit 0
}

if ($moved.Count -eq 0) {
    Write-Host ("no ready files moved lane={0} destination={1}" -f $laneName, $resolvedDestinationRoot)
    exit 0
}

Write-Host ("quarantined ready files lane={0} count={1} destination={2}" -f $laneName, $moved.Count, $resolvedDestinationRoot)
foreach ($row in @($moved)) {
    Write-Host ("- {0}: {1}" -f $row.TargetId, $row.FileName)
}
