[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\settings.psd1'),
    [string]$TargetId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

$config = Import-PowerShellDataFile -Path $ConfigPath
$targetById = @{}
foreach ($target in $config.Targets) {
    $targetById[[string]$target.Id] = $target
}

$files = Get-ChildItem -LiteralPath ([string]$config.RetryPendingRoot) -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc, Name

foreach ($file in $files) {
    $name = $file.Name
    $segments = $name -split '__', 3
    if ($segments.Count -lt 3) {
        Write-Host "skipped malformed retry file: $name"
        continue
    }

    $fileTargetId = $segments[0]
    if (-not [string]::IsNullOrWhiteSpace($TargetId) -and $fileTargetId -ne $TargetId) {
        continue
    }

    if (-not $targetById.ContainsKey($fileTargetId)) {
        Write-Host "skipped unknown target: $name"
        continue
    }

    $destinationFolder = [string]$targetById[$fileTargetId].Folder
    if (-not (Test-Path -LiteralPath $destinationFolder)) {
        New-Item -ItemType Directory -Path $destinationFolder | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $destinationName = 'requeued_{0}__{1}__{2}' -f $stamp, [guid]::NewGuid().ToString('N'), $segments[2]
    $destinationPath = Join-Path $destinationFolder $destinationName
    $metadataPath = ($file.FullName + '.meta.json')
    $destinationMetadataPath = ($destinationPath + '.meta.json')
    Move-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        Move-Item -LiteralPath $metadataPath -Destination $destinationMetadataPath -Force
    }
    Write-Host "requeued: $destinationPath"
}
