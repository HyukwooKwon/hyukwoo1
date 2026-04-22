[CmdletBinding(DefaultParameterSetName = 'InlineText')]
param(
    [Parameter(Mandatory)]
    [string]$TargetId,

    [Parameter(ParameterSetName = 'InlineText')]
    [string]$Text = "테스트 메시지입니다.`r`n두 번째 줄입니다.",

    [Parameter(Mandatory, ParameterSetName = 'TextFile')]
    [string]$TextFilePath,

    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config\settings.psd1'
}

. (Join-Path $PSScriptRoot 'router\RelayMessageMetadata.ps1')

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Get-ConfigBooleanSetting {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$DefaultValue
    )

    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains($Name)) {
            return [bool]$Config[$Name]
        }

        return $DefaultValue
    }

    $property = $Config.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return [bool]$property.Value
    }

    return $DefaultValue
}

function Import-ConfigDataFile {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $importCommand = Get-Command -Name Import-PowerShellDataFile -ErrorAction SilentlyContinue
    if ($null -ne $importCommand) {
        return Import-PowerShellDataFile -Path $resolvedPath
    }

    # Fallback for hosts where the cmdlet is unexpectedly unavailable.
    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
    return [scriptblock]::Create($raw).InvokeReturnAsIs()
}

$config = Import-ConfigDataFile -Path $ConfigPath
$target = $config.Targets | Where-Object { $_.Id -eq $TargetId } | Select-Object -First 1

if ($null -eq $target) {
    throw "Unknown TargetId: $TargetId"
}

$folder = [string]$target.Folder
if (-not (Test-Path -LiteralPath $folder)) {
    throw "Target folder not found: $folder"
}

$body = if ($PSCmdlet.ParameterSetName -eq 'TextFile') {
    if (-not (Test-Path -LiteralPath $TextFilePath)) {
        throw "Text file not found: $TextFilePath"
    }

    $resolvedTextFilePath = (Resolve-Path -LiteralPath $TextFilePath).Path
    [System.IO.File]::ReadAllText($resolvedTextFilePath, [System.Text.UTF8Encoding]::new($false, $true))
}
else {
    [string]$Text
}

$sourceMetadataDocument = $null
$sourceMetadata = $null
$resolvedSourceTextFilePath = ''
$runtimeMapPath = if ($config -is [System.Collections.IDictionary]) {
    if ($config.Contains('RuntimeMapPath')) { [string]$config['RuntimeMapPath'] } else { '' }
}
else {
    if ($null -ne $config.PSObject.Properties['RuntimeMapPath']) { [string]$config.RuntimeMapPath } else { '' }
}
$requirePairTransportMetadata = Get-ConfigBooleanSetting -Config $config -Name 'RequirePairTransportMetadata' -DefaultValue $false
$readyLauncherSessionId = Get-RelayLauncherSessionIdFromRuntimeMap -RuntimeMapPath $runtimeMapPath
if ($PSCmdlet.ParameterSetName -eq 'TextFile') {
    $resolvedSourceTextFilePath = $resolvedTextFilePath
    $sourceMetadataDocument = Read-RelayMessageMetadata -MessagePath $resolvedSourceTextFilePath
    if ($requirePairTransportMetadata -and -not $sourceMetadataDocument.Exists) {
        throw "Relay metadata required for TextFilePath when pair transport metadata is enforced: $resolvedSourceTextFilePath (.relay.json missing). Use -Text for ad-hoc input or create the source relay metadata first."
    }
    if (Test-RelayMetadataNonEmptyString ([string]$sourceMetadataDocument.ParseError)) {
        throw "Relay metadata parse failed: $($sourceMetadataDocument.Path) error=$($sourceMetadataDocument.ParseError)"
    }

    $sourceMetadata = $sourceMetadataDocument.Data
    $sourceMessageType = [string](Get-RelayMetadataPropertyValue -Object $sourceMetadata -Name 'MessageType' -DefaultValue '')
    $hasPairSourceMetadata = Test-IsPairRelayMessageType -MessageType $sourceMessageType

    if (($requirePairTransportMetadata -or $hasPairSourceMetadata) -and -not (Test-IsSupportedPairedRelayMessageType -MessageType $sourceMessageType)) {
        throw "Unsupported pair relay metadata for TextFilePath: messageType=$sourceMessageType path=$resolvedSourceTextFilePath"
    }

    if ($requirePairTransportMetadata -or $hasPairSourceMetadata) {
        $requiredFieldNames = @(Get-RelayMessageMetadataRequiredFieldNames -MessageType $sourceMessageType)
        $missingFieldNames = @(Get-RelayMetadataMissingRequiredFieldNames -Object $sourceMetadata -RequiredFieldNames $requiredFieldNames)
        if ($missingFieldNames.Count -gt 0) {
            throw "Pair relay metadata missing fields for TextFilePath: fields=$($missingFieldNames -join ',') path=$resolvedSourceTextFilePath"
        }
    }
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$guid = [guid]::NewGuid().ToString('N')
$tmpPath = Join-Path $folder "message_${stamp}__${guid}.tmp.txt"
$readyPath = Join-Path $folder "message_${stamp}__${guid}.ready.txt"
$readyMetadata = New-ReadyFileRelayMetadata -TargetId $TargetId -SourceTextFilePath $resolvedSourceTextFilePath -SourceMetadata $sourceMetadata -LauncherSessionId $readyLauncherSessionId

[System.IO.File]::WriteAllText($tmpPath, $body, (New-Utf8NoBomEncoding))
Write-ReadyFileMetadata -ReadyFilePath $readyPath -Metadata $readyMetadata | Out-Null
Move-Item -LiteralPath $tmpPath -Destination $readyPath -Force

Write-Host "created ready file: $readyPath"
