function New-RelayMetadataUtf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function ConvertTo-RelayJsonNormalizedValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetimeoffset]) {
        return $Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [datetime]) {
        return $Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [guid]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $normalizedMap = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $normalizedMap[[string]$key] = ConvertTo-RelayJsonNormalizedValue -Value $Value[$key]
        }

        return [pscustomobject]$normalizedMap
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $normalizedItems = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $normalizedItems.Add((ConvertTo-RelayJsonNormalizedValue -Value $item))
        }

        return ,($normalizedItems.ToArray())
    }

    $propertyBag = @($Value.PSObject.Properties)
    if ($propertyBag.Count -gt 0) {
        $normalizedObject = [ordered]@{}
        foreach ($property in $propertyBag) {
            $normalizedObject[[string]$property.Name] = ConvertTo-RelayJsonNormalizedValue -Value $property.Value
        }

        return [pscustomobject]$normalizedObject
    }

    return $Value
}

function ConvertFrom-RelayJsonText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return $null
    }

    $parsed = $Json | ConvertFrom-Json
    return (ConvertTo-RelayJsonNormalizedValue -Value $parsed)
}

function Test-RelayMetadataNonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-RelayMetadataPropertyValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Resolve-RelayMetadataPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Get-RelayMessageMetadataSidecarPath {
    param([Parameter(Mandatory)][string]$MessagePath)

    return ((Resolve-RelayMetadataPath -Path $MessagePath) + '.relay.json')
}

function Get-ReadyFileMetadataPath {
    param([Parameter(Mandatory)][string]$ReadyFilePath)

    return ((Resolve-RelayMetadataPath -Path $ReadyFilePath) + '.delivery.json')
}

function Get-ReadyFileArchiveMetadataPath {
    param([Parameter(Mandatory)][string]$ReadyFilePath)

    return ((Resolve-RelayMetadataPath -Path $ReadyFilePath) + '.archive.json')
}

function Read-RelayMetadataDocument {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists     = $false
            ParseError = ''
            Data       = $null
            Path       = $Path
        }
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            Exists     = $true
            ParseError = ''
            Data       = $null
            Path       = $Path
        }
    }

    try {
        $data = ConvertFrom-RelayJsonText -Json $raw
    }
    catch {
        return [pscustomobject]@{
            Exists     = $true
            ParseError = $_.Exception.Message
            Data       = $null
            Path       = $Path
        }
    }

    return [pscustomobject]@{
        Exists     = $true
        ParseError = ''
        Data       = $data
        Path       = $Path
    }
}

function Read-RelayMessageMetadata {
    param([Parameter(Mandatory)][string]$MessagePath)

    $metadataPath = Get-RelayMessageMetadataSidecarPath -MessagePath $MessagePath
    return (Read-RelayMetadataDocument -Path $metadataPath)
}

function Read-ReadyFileMetadata {
    param([Parameter(Mandatory)][string]$ReadyFilePath)

    $metadataPath = Get-ReadyFileMetadataPath -ReadyFilePath $ReadyFilePath
    return (Read-RelayMetadataDocument -Path $metadataPath)
}

function Read-ReadyFileArchiveMetadata {
    param([Parameter(Mandatory)][string]$ReadyFilePath)

    $metadataPath = Get-ReadyFileArchiveMetadataPath -ReadyFilePath $ReadyFilePath
    return (Read-RelayMetadataDocument -Path $metadataPath)
}

function Write-RelayMetadataDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Metadata
    )

    $parent = Split-Path -Parent $Path
    if (Test-RelayMetadataNonEmptyString $parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = (ConvertTo-RelayJsonNormalizedValue -Value $Metadata) | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-RelayMetadataUtf8NoBomEncoding))
    return $Path
}

function Write-RelayMessageMetadata {
    param(
        [Parameter(Mandatory)][string]$MessagePath,
        [Parameter(Mandatory)]$Metadata
    )

    $metadataPath = Get-RelayMessageMetadataSidecarPath -MessagePath $MessagePath
    return (Write-RelayMetadataDocument -Path $metadataPath -Metadata $Metadata)
}

function Write-ReadyFileMetadata {
    param(
        [Parameter(Mandatory)][string]$ReadyFilePath,
        [Parameter(Mandatory)]$Metadata
    )

    $metadataPath = Get-ReadyFileMetadataPath -ReadyFilePath $ReadyFilePath
    return (Write-RelayMetadataDocument -Path $metadataPath -Metadata $Metadata)
}

function New-ReadyFileArchiveMetadata {
    param(
        [Parameter(Mandatory)][string]$ReadyFilePath,
        [Parameter(Mandatory)][string]$ArchiveState,
        [Parameter(Mandatory)][string]$ReasonCode,
        [string]$ReasonDetail = '',
        [string]$ObservedCreatedAtRaw = '',
        [string]$ObservedCreatedAtUtc = ''
    )

    $deliveryMetadataDocument = Read-ReadyFileMetadata -ReadyFilePath $ReadyFilePath
    $deliveryMetadata = if ($deliveryMetadataDocument.Exists -and -not (Test-RelayMetadataNonEmptyString $deliveryMetadataDocument.ParseError)) {
        $deliveryMetadataDocument.Data
    }
    else {
        $null
    }

    return [ordered]@{
        SchemaVersion            = '1.0.0'
        Kind                     = 'relay-ready-archive'
        ArchivedAt               = (Get-Date).ToString('o')
        ArchivedPath             = (Normalize-RelayMetadataOptionalPath -PathValue $ReadyFilePath)
        ArchiveState             = [string]$ArchiveState
        ArchiveReasonCode        = [string]$ReasonCode
        ArchiveReasonDetail      = [string]$ReasonDetail
        ObservedCreatedAtRaw     = [string]$ObservedCreatedAtRaw
        ObservedCreatedAtUtc     = [string]$ObservedCreatedAtUtc
        DeliveryMetadataPath     = (Get-ReadyFileMetadataPath -ReadyFilePath $ReadyFilePath)
        DeliveryMetadataExists   = [bool]$deliveryMetadataDocument.Exists
        DeliveryMetadataParseError = [string]$deliveryMetadataDocument.ParseError
        TargetId                 = [string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'TargetId' -DefaultValue '')
        MessageType              = [string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'MessageType' -DefaultValue '')
        LauncherSessionId        = [string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'LauncherSessionId' -DefaultValue '')
        RunRoot                  = (Normalize-RelayMetadataOptionalPath -PathValue ([string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'RunRoot' -DefaultValue '')))
        RunId                    = [string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'RunId' -DefaultValue '')
        PairId                   = [string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'PairId' -DefaultValue '')
        PartnerTargetId          = [string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'PartnerTargetId' -DefaultValue '')
        SourceTargetId           = [string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'SourceTargetId' -DefaultValue '')
        SourceMessageType        = [string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'SourceMessageType' -DefaultValue '')
        SourceTextFilePath       = (Normalize-RelayMetadataOptionalPath -PathValue ([string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'SourceTextFilePath' -DefaultValue '')))
        SourceMessagePath        = (Normalize-RelayMetadataOptionalPath -PathValue ([string](Get-RelayMetadataPropertyValue -Object $deliveryMetadata -Name 'SourceMessagePath' -DefaultValue '')))
    }
}

function Write-ReadyFileArchiveMetadata {
    param(
        [Parameter(Mandatory)][string]$ReadyFilePath,
        [Parameter(Mandatory)][string]$ArchiveState,
        [Parameter(Mandatory)][string]$ReasonCode,
        [string]$ReasonDetail = '',
        [string]$ObservedCreatedAtRaw = '',
        [string]$ObservedCreatedAtUtc = ''
    )

    $metadataPath = Get-ReadyFileArchiveMetadataPath -ReadyFilePath $ReadyFilePath
    $metadata = New-ReadyFileArchiveMetadata `
        -ReadyFilePath $ReadyFilePath `
        -ArchiveState $ArchiveState `
        -ReasonCode $ReasonCode `
        -ReasonDetail $ReasonDetail `
        -ObservedCreatedAtRaw $ObservedCreatedAtRaw `
        -ObservedCreatedAtUtc $ObservedCreatedAtUtc
    return (Write-RelayMetadataDocument -Path $metadataPath -Metadata $metadata)
}

function Normalize-RelayMetadataOptionalPath {
    param([AllowEmptyString()][string]$PathValue)

    if (-not (Test-RelayMetadataNonEmptyString $PathValue)) {
        return ''
    }

    try {
        return (Resolve-RelayMetadataPath -Path $PathValue)
    }
    catch {
        return $PathValue
    }
}

function Get-RelayRunIdFromRunRoot {
    param([AllowEmptyString()][string]$RunRoot)

    if (-not (Test-RelayMetadataNonEmptyString $RunRoot)) {
        return ''
    }

    $resolvedRunRoot = Normalize-RelayMetadataOptionalPath -PathValue $RunRoot
    if (Test-RelayMetadataNonEmptyString $resolvedRunRoot) {
        return [string][System.IO.Path]::GetFileName($resolvedRunRoot.TrimEnd('\', '/'))
    }

    return [string][System.IO.Path]::GetFileName(([string]$RunRoot).TrimEnd('\', '/'))
}

function Get-SupportedPairedRelayMessageTypes {
    return @('pair-seed', 'pair-handoff', 'pair-initial', 'pair-handoff-wait')
}

function Test-IsPairRelayMessageType {
    param([AllowEmptyString()][string]$MessageType)

    $normalized = [string]$MessageType
    if (-not (Test-RelayMetadataNonEmptyString $normalized)) {
        return $false
    }

    return $normalized.Trim().ToLowerInvariant().StartsWith('pair-')
}

function Test-IsSupportedPairedRelayMessageType {
    param([AllowEmptyString()][string]$MessageType)

    $normalized = [string]$MessageType
    if (-not (Test-RelayMetadataNonEmptyString $normalized)) {
        return $false
    }

    return ($normalized.Trim().ToLowerInvariant() -in @(Get-SupportedPairedRelayMessageTypes))
}

function Get-ReadyFileMetadataRequiredFieldNames {
    param(
        [AllowEmptyString()][string]$MessageType,
        [switch]$RequirePairTransportMetadata
    )

    $requiredFieldNames = @('SchemaVersion', 'Kind', 'CreatedAt', 'TargetId', 'MessageType')
    $normalizedMessageType = [string]$MessageType
    if ($RequirePairTransportMetadata -and (Test-IsPairRelayMessageType -MessageType $normalizedMessageType)) {
        $requiredFieldNames += @('RunRoot', 'RunId', 'PairId', 'PartnerTargetId', 'LauncherSessionId')
        if ($normalizedMessageType.Trim().ToLowerInvariant() -eq 'pair-handoff') {
            $requiredFieldNames += 'SourceTargetId'
        }
    }

    return @($requiredFieldNames | Sort-Object -Unique)
}

function Get-RelayMessageMetadataRequiredFieldNames {
    param([AllowEmptyString()][string]$MessageType)

    $requiredFieldNames = @('SchemaVersion', 'Kind', 'CreatedAt', 'RunRoot', 'RunId', 'PairId', 'TargetId', 'PartnerTargetId', 'MessageType')
    $normalizedMessageType = [string]$MessageType
    if ($normalizedMessageType.Trim().ToLowerInvariant() -eq 'pair-handoff') {
        $requiredFieldNames += 'SourceTargetId'
    }

    return @($requiredFieldNames | Sort-Object -Unique)
}

function Get-RelayMetadataMissingRequiredFieldNames {
    param(
        $Object,
        [string[]]$RequiredFieldNames = @()
    )

    $missingFieldNames = New-Object System.Collections.Generic.List[string]
    foreach ($fieldName in @($RequiredFieldNames | Where-Object { Test-RelayMetadataNonEmptyString $_ })) {
        $value = [string](Get-RelayMetadataPropertyValue -Object $Object -Name ([string]$fieldName) -DefaultValue '')
        if (-not (Test-RelayMetadataNonEmptyString $value)) {
            $missingFieldNames.Add([string]$fieldName)
        }
    }

    return @($missingFieldNames)
}

function Get-RelayLauncherSessionIdFromRuntimeMap {
    param([AllowEmptyString()][string]$RuntimeMapPath)

    if (-not (Test-RelayMetadataNonEmptyString $RuntimeMapPath) -or -not (Test-Path -LiteralPath $RuntimeMapPath -PathType Leaf)) {
        return ''
    }

    $raw = Get-Content -LiteralPath $RuntimeMapPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return ''
    }

    try {
        $parsed = ConvertFrom-RelayJsonText -Json $raw
    }
    catch {
        return ''
    }

    $items = if ($parsed -is [System.Array]) { @($parsed) } elseif ($null -ne $parsed) { @($parsed) } else { @() }
    $sessionIds = @(
        $items |
            ForEach-Object { [string](Get-RelayMetadataPropertyValue -Object $_ -Name 'LauncherSessionId' -DefaultValue '') } |
            Where-Object { Test-RelayMetadataNonEmptyString $_ } |
            Sort-Object -Unique
    )

    if ($sessionIds.Count -ne 1) {
        return ''
    }

    return [string]$sessionIds[0]
}

function New-PairedRelayMessageMetadata {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PartnerTargetId,
        [string]$RoleName = '',
        [string]$InitialRoleMode = '',
        [Parameter(Mandatory)][string]$MessageType,
        [string]$SourceTargetId = '',
        [string]$MessagePath = '',
        [string]$RunId = '',
        [string]$LauncherSessionId = ''
    )

    $effectiveRunRoot = Normalize-RelayMetadataOptionalPath -PathValue $RunRoot
    $effectiveRunId = if (Test-RelayMetadataNonEmptyString $RunId) {
        [string]$RunId
    }
    else {
        Get-RelayRunIdFromRunRoot -RunRoot $effectiveRunRoot
    }

    return [ordered]@{
        SchemaVersion   = '1.0.0'
        Kind            = 'relay-message'
        CreatedAt       = (Get-Date).ToString('o')
        RunRoot         = $effectiveRunRoot
        RunId           = [string]$effectiveRunId
        PairId          = [string]$PairId
        MessageType     = [string]$MessageType
        TargetId        = [string]$TargetId
        PartnerTargetId = [string]$PartnerTargetId
        RoleName        = [string]$RoleName
        InitialRoleMode = [string]$InitialRoleMode
        SourceTargetId  = [string]$SourceTargetId
        MessagePath     = (Normalize-RelayMetadataOptionalPath -PathValue $MessagePath)
        LauncherSessionId = [string]$LauncherSessionId
    }
}

function New-ReadyFileRelayMetadata {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [string]$SourceTextFilePath = '',
        $SourceMetadata = $null,
        [string]$LauncherSessionId = ''
    )

    $sourceTargetId = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'TargetId' -DefaultValue '')
    if ((Test-RelayMetadataNonEmptyString $sourceTargetId) -and ($sourceTargetId.Trim() -ne $TargetId.Trim())) {
        throw "source metadata target mismatch: source=$sourceTargetId ready=$TargetId"
    }

    $messageType = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'MessageType' -DefaultValue '')
    if (-not (Test-RelayMetadataNonEmptyString $messageType)) {
        $messageType = 'generic'
    }

    $effectiveLauncherSessionId = if (Test-RelayMetadataNonEmptyString $LauncherSessionId) {
        [string]$LauncherSessionId
    }
    else {
        [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'LauncherSessionId' -DefaultValue '')
    }
    $sourceRunRoot = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'RunRoot' -DefaultValue '')
    $sourceRunId = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'RunId' -DefaultValue '')
    if (-not (Test-RelayMetadataNonEmptyString $sourceRunId)) {
        $sourceRunId = Get-RelayRunIdFromRunRoot -RunRoot $sourceRunRoot
    }

    return [ordered]@{
        SchemaVersion        = '1.0.0'
        Kind                 = 'relay-ready'
        CreatedAt            = (Get-Date).ToString('o')
        TargetId             = [string]$TargetId
        MessageType          = $messageType
        LauncherSessionId    = [string]$effectiveLauncherSessionId
        RunRoot              = (Normalize-RelayMetadataOptionalPath -PathValue $sourceRunRoot)
        RunId                = [string]$sourceRunId
        PairId               = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'PairId' -DefaultValue '')
        PartnerTargetId      = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'PartnerTargetId' -DefaultValue '')
        RoleName             = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'RoleName' -DefaultValue '')
        InitialRoleMode      = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'InitialRoleMode' -DefaultValue '')
        SourceTargetId       = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'SourceTargetId' -DefaultValue '')
        SourceMessageType    = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'MessageType' -DefaultValue '')
        SourceMessageCreatedAt = [string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'CreatedAt' -DefaultValue '')
        SourceTextFilePath   = (Normalize-RelayMetadataOptionalPath -PathValue $SourceTextFilePath)
        SourceMessagePath    = (Normalize-RelayMetadataOptionalPath -PathValue ([string](Get-RelayMetadataPropertyValue -Object $SourceMetadata -Name 'MessagePath' -DefaultValue '')))
    }
}
