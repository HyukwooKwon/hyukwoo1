[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\settings.psd1'),
    [string]$TargetId,
    [string[]]$RetryPath = @()
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

function Update-RequeuedRetryMetadata {
    param(
        [Parameter(Mandatory)][string]$MetadataPath,
        [Parameter(Mandatory)][string]$SourceRetryPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
        return
    }

    try {
        $metadata = Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return
    }

    $requeueCount = 0
    if ($null -ne $metadata.PSObject.Properties['RequeueCount']) {
        $parsedCount = 0
        if ([int]::TryParse(([string]$metadata.RequeueCount), [ref]$parsedCount)) {
            $requeueCount = $parsedCount
        }
    }
    $requeueCount += 1

    $history = @()
    if ($null -ne $metadata.PSObject.Properties['RequeueHistory']) {
        $history = @($metadata.RequeueHistory)
    }
    $history += [pscustomobject][ordered]@{
        RequeuedAt = (Get-Date).ToString('o')
        FromRetryPath = $SourceRetryPath
        ToReadyPath = $DestinationPath
    }

    $metadata | Add-Member -NotePropertyName RequeueCount -NotePropertyValue $requeueCount -Force
    $metadata | Add-Member -NotePropertyName LastRequeuedAt -NotePropertyValue (Get-Date).ToString('o') -Force
    $metadata | Add-Member -NotePropertyName LastRequeuedFromRetryPath -NotePropertyValue $SourceRetryPath -Force
    $metadata | Add-Member -NotePropertyName LastRequeuedToReadyPath -NotePropertyValue $DestinationPath -Force
    $metadata | Add-Member -NotePropertyName RequeueHistory -NotePropertyValue @($history) -Force

    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $MetadataPath -Encoding UTF8
}

function Get-RequeueLauncherSessionId {
    param($Config)

    $runtimeMapPath = ''
    if ($Config -is [hashtable] -and $Config.ContainsKey('RuntimeMapPath')) {
        $runtimeMapPath = [string]$Config['RuntimeMapPath']
    }
    elseif ($null -ne $Config.PSObject.Properties['RuntimeMapPath']) {
        $runtimeMapPath = [string]$Config.RuntimeMapPath
    }
    if ([string]::IsNullOrWhiteSpace($runtimeMapPath) -or -not (Test-Path -LiteralPath $runtimeMapPath -PathType Leaf)) {
        return ''
    }

    try {
        $runtimeItems = @(Get-Content -LiteralPath $runtimeMapPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return ''
    }

    $sessionIds = @(
        $runtimeItems |
            ForEach-Object {
                if ($null -ne $_.PSObject.Properties['LauncherSessionId']) {
                    [string]$_.LauncherSessionId
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    if ($sessionIds.Count -eq 1) {
        return [string]$sessionIds[0]
    }
    return ''
}

function New-ReconstructedReadyDeliveryMetadata {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$SourceRetryPath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$LauncherSessionId = ''
    )

    return [ordered]@{
        SchemaVersion = '1.0.0'
        Kind = 'relay-ready'
        CreatedAt = (Get-Date).ToString('o')
        TargetId = $TargetId
        MessageType = 'generic'
        LauncherSessionId = $LauncherSessionId
        SourceRetryPath = $SourceRetryPath
        RequeuedReadyPath = $DestinationPath
        ReconstructedFromRetryPending = $true
    }
}

$retryPendingRoot = [string]$config.RetryPendingRoot
$launcherSessionId = Get-RequeueLauncherSessionId -Config $config
$files = @()
if (@($RetryPath).Count -gt 0) {
    $normalizedRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($retryPendingRoot)) {
        try {
            $normalizedRoot = [System.IO.Path]::GetFullPath($retryPendingRoot).TrimEnd('\', '/').ToLowerInvariant()
        }
        catch {
            $normalizedRoot = $retryPendingRoot.TrimEnd('\', '/').ToLowerInvariant()
        }
    }
    foreach ($path in @($RetryPath)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if (-not $item.PSIsContainer -and $item.Name -like '*.ready.txt') {
            if (-not [string]::IsNullOrWhiteSpace($normalizedRoot)) {
                try {
                    $normalizedItemPath = [System.IO.Path]::GetFullPath($item.FullName).ToLowerInvariant()
                }
                catch {
                    $normalizedItemPath = $item.FullName.ToLowerInvariant()
                }
                if (-not ($normalizedItemPath.StartsWith($normalizedRoot + '\') -or $normalizedItemPath -eq $normalizedRoot)) {
                    throw "retry path is outside RetryPendingRoot: $($item.FullName)"
                }
            }
            $files += $item
        }
    }
    $files = @($files | Sort-Object LastWriteTimeUtc, Name -Unique)
}
else {
    $files = Get-ChildItem -LiteralPath $retryPendingRoot -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, Name
}

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
    $deliveryMetadataPath = ($file.FullName + '.delivery.json')
    $destinationDeliveryMetadataPath = ($destinationPath + '.delivery.json')
    Move-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        Move-Item -LiteralPath $metadataPath -Destination $destinationMetadataPath -Force
        Update-RequeuedRetryMetadata `
            -MetadataPath $destinationMetadataPath `
            -SourceRetryPath ([string]$file.FullName) `
            -DestinationPath $destinationPath
    }
    if (Test-Path -LiteralPath $deliveryMetadataPath -PathType Leaf) {
        Move-Item -LiteralPath $deliveryMetadataPath -Destination $destinationDeliveryMetadataPath -Force
    }
    else {
        $reconstructedDeliveryMetadata = New-ReconstructedReadyDeliveryMetadata `
            -TargetId $fileTargetId `
            -SourceRetryPath ([string]$file.FullName) `
            -DestinationPath $destinationPath `
            -LauncherSessionId $launcherSessionId
        $reconstructedDeliveryMetadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $destinationDeliveryMetadataPath -Encoding UTF8
        Write-Host "reconstructed delivery metadata: $destinationDeliveryMetadataPath"
    }
    Write-Host "requeued: $destinationPath"
}
