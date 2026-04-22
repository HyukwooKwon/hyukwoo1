function Resolve-ArchivePath {
    param(
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$SourcePath
    )

    Ensure-Directory -Path $DestinationRoot

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $baseName = [System.IO.Path]::GetFileName($SourcePath)
    $destName = '{0}__{1}__{2}' -f $TargetId, $stamp, $baseName

    return (Join-Path $DestinationRoot $destName)
}

function Move-MessageToArchive {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string]$TargetId
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return $null
    }

    $destination = Resolve-ArchivePath -DestinationRoot $DestinationRoot -TargetId $TargetId -SourcePath $SourcePath
    Move-Item -LiteralPath $SourcePath -Destination $destination -Force
    $deliveryMetadataSourcePath = ($SourcePath + '.delivery.json')
    if (Test-Path -LiteralPath $deliveryMetadataSourcePath -PathType Leaf) {
        $deliveryMetadataDestinationPath = ($destination + '.delivery.json')
        Move-Item -LiteralPath $deliveryMetadataSourcePath -Destination $deliveryMetadataDestinationPath -Force
    }
    return $destination
}
