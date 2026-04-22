Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-OneTimeQueueLaneName {
    param(
        $Config,
        [string]$LaneName
    )

    if (Test-NonEmptyString $LaneName) {
        return [string]$LaneName
    }

    $resolved = [string](Get-ConfigValue -Object $Config -Name 'LaneName' -DefaultValue '')
    if (Test-NonEmptyString $resolved) {
        return $resolved
    }

    return 'default'
}

function Resolve-OneTimeQueueDirectory {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [string]$LaneName
    )

    $resolvedLane = Resolve-OneTimeQueueLaneName -Config $Config -LaneName $LaneName
    return (Join-Path $Root ('runtime\one-time-queue\' + $resolvedLane))
}

function Resolve-OneTimeQueuePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [Parameter(Mandatory)][string]$PairId,
        [string]$LaneName
    )

    $queueDirectory = Resolve-OneTimeQueueDirectory -Root $Root -Config $Config -LaneName $LaneName
    return (Join-Path $queueDirectory ($PairId + '.queue.json'))
}

function Resolve-OneTimeQueueArchiveDirectory {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [string]$LaneName
    )

    return (Join-Path (Resolve-OneTimeQueueDirectory -Root $Root -Config $Config -LaneName $LaneName) 'archive')
}

function New-OneTimeQueueDocument {
    param(
        [Parameter(Mandatory)][string]$LaneName,
        [Parameter(Mandatory)][string]$PairId
    )

    return [pscustomobject]@{
        SchemaVersion = '1.0.0'
        LaneName = $LaneName
        PairId = $PairId
        GeneratedAt = (Get-Date).ToString('o')
        Items = @()
    }
}

function Get-OneTimeQueueDocument {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [Parameter(Mandatory)][string]$PairId,
        [string]$LaneName
    )

    $resolvedLane = Resolve-OneTimeQueueLaneName -Config $Config -LaneName $LaneName
    $queuePath = Resolve-OneTimeQueuePath -Root $Root -Config $Config -PairId $PairId -LaneName $resolvedLane

    if (-not (Test-Path -LiteralPath $queuePath)) {
        return [pscustomobject]@{
            QueuePath = $queuePath
            Document = (New-OneTimeQueueDocument -LaneName $resolvedLane -PairId $PairId)
        }
    }

    $document = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($document.PSObject.Properties['SchemaVersion'] -eq $null) {
        $document | Add-Member -NotePropertyName SchemaVersion -NotePropertyValue '1.0.0'
    }
    if ($document.PSObject.Properties['LaneName'] -eq $null) {
        $document | Add-Member -NotePropertyName LaneName -NotePropertyValue $resolvedLane
    }
    if ($document.PSObject.Properties['PairId'] -eq $null) {
        $document | Add-Member -NotePropertyName PairId -NotePropertyValue $PairId
    }
    if ($document.PSObject.Properties['Items'] -eq $null) {
        $document | Add-Member -NotePropertyName Items -NotePropertyValue @()
    }

    return [pscustomobject]@{
        QueuePath = $queuePath
        Document = $document
    }
}

function Save-OneTimeQueueDocument {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$QueuePath
    )

    $directory = Split-Path -Parent $QueuePath
    Ensure-Directory -Path $directory

    $Document.GeneratedAt = (Get-Date).ToString('o')
    $encoding = New-Utf8NoBomEncoding
    [System.IO.File]::WriteAllText($QueuePath, ($Document | ConvertTo-Json -Depth 10), $encoding)
}

function Set-OneTimeQueueDocumentItems {
    param(
        [Parameter(Mandatory)]$QueueDocument,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items
    )

    $QueueDocument.PSObject.Properties.Remove('Items')
    $QueueDocument | Add-Member -NotePropertyName Items -NotePropertyValue $Items
}

function Write-OneTimeQueueArchiveRecord {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Reason
    )

    $laneName = Resolve-OneTimeQueueLaneName -Config $Config -LaneName ''
    $archiveDirectory = Resolve-OneTimeQueueArchiveDirectory -Root $Root -Config $Config -LaneName $laneName
    Ensure-Directory -Path $archiveDirectory

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $itemId = [string](Get-ConfigValue -Object $Item -Name 'Id' -DefaultValue 'unknown')
    $pairId = [string](Get-ConfigValue -Object (Get-ConfigValue -Object $Item -Name 'Scope' -DefaultValue $null) -Name 'PairId' -DefaultValue 'unknown')
    $archivePath = Join-Path $archiveDirectory ("{0}.{1}.{2}.json" -f $pairId, $Reason, $stamp)
    $payload = [pscustomobject]@{
        SchemaVersion = '1.0.0'
        ArchivedAt = (Get-Date).ToString('o')
        Reason = $Reason
        LaneName = $laneName
        PairId = $pairId
        ItemId = $itemId
        Item = $Item
    }

    $encoding = New-Utf8NoBomEncoding
    [System.IO.File]::WriteAllText($archivePath, ($payload | ConvertTo-Json -Depth 10), $encoding)
    return $archivePath
}

function New-OneTimeQueueItem {
    param(
        [Parameter(Mandatory)][string]$PairId,
        [ValidateSet('', 'top', 'bottom')][string]$Role = '',
        [string]$TargetId,
        [ValidateSet('initial', 'handoff', 'both')][string]$AppliesTo = 'both',
        [ValidateSet('one-time-prefix', 'one-time-suffix')][string]$Placement = 'one-time-prefix',
        [Parameter(Mandatory)][string]$Text,
        [int]$Priority = 100,
        [string]$Notes,
        [string]$CreatedBy,
        [string]$ExpiresAt
    )

    if (-not (Test-NonEmptyString $Text)) {
        throw 'Text is required.'
    }

    if (-not (Test-NonEmptyString $CreatedBy)) {
        $CreatedBy = $env:USERNAME
    }
    if (-not (Test-NonEmptyString $CreatedBy)) {
        $CreatedBy = 'operator'
    }

    return [pscustomobject]@{
        Id = ('otm-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        Enabled = $true
        State = 'queued'
        ConsumeOnce = $true
        Text = $Text
        Scope = [pscustomobject]@{
            PairId = $PairId
            Role = if (Test-NonEmptyString $Role) { $Role } else { $null }
            TargetId = if (Test-NonEmptyString $TargetId) { $TargetId } else { $null }
            AppliesTo = $AppliesTo
        }
        Placement = $Placement
        Priority = $Priority
        CreatedAt = (Get-Date).ToString('o')
        CreatedBy = $CreatedBy
        ExpiresAt = if (Test-NonEmptyString $ExpiresAt) { $ExpiresAt } else { $null }
        Notes = if (Test-NonEmptyString $Notes) { $Notes } else { '' }
    }
}

function Get-OneTimeQueueItemEffectiveState {
    param([Parameter(Mandatory)]$Item)

    $state = [string](Get-ConfigValue -Object $Item -Name 'State' -DefaultValue 'queued')
    if ($state -eq '') {
        $state = 'queued'
    }

    $expiresAt = [string](Get-ConfigValue -Object $Item -Name 'ExpiresAt' -DefaultValue '')
    if ((Test-NonEmptyString $expiresAt) -and ($state -notin @('cancelled', 'consumed', 'expired'))) {
        try {
            if ([datetimeoffset]::Parse($expiresAt) -lt [datetimeoffset]::Now) {
                return 'expired'
            }
        }
        catch {
        }
    }

    return $state
}

function Get-ApplicableOneTimeQueueItems {
    param(
        [Parameter(Mandatory)]$QueueDocument,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][ValidateSet('initial', 'handoff')][string]$MessageType
    )

    $matched = foreach ($item in @($QueueDocument.Items)) {
        $effectiveState = Get-OneTimeQueueItemEffectiveState -Item $item
        if ([string](Get-ConfigValue -Object $item -Name 'Enabled' -DefaultValue $true) -eq 'False') {
            continue
        }
        if ($effectiveState -ne 'queued' -and $effectiveState -ne 'previewed') {
            continue
        }

        $scope = Get-ConfigValue -Object $item -Name 'Scope' -DefaultValue $null
        $scopePairId = [string](Get-ConfigValue -Object $scope -Name 'PairId' -DefaultValue '')
        $scopeRole = [string](Get-ConfigValue -Object $scope -Name 'Role' -DefaultValue '')
        $scopeTargetId = [string](Get-ConfigValue -Object $scope -Name 'TargetId' -DefaultValue '')
        $scopeAppliesTo = [string](Get-ConfigValue -Object $scope -Name 'AppliesTo' -DefaultValue 'both')

        if ($scopePairId -ne $PairId) {
            continue
        }
        if ((Test-NonEmptyString $scopeRole) -and ($scopeRole -ne $RoleName)) {
            continue
        }
        if ((Test-NonEmptyString $scopeTargetId) -and ($scopeTargetId -ne $TargetId)) {
            continue
        }
        if ($scopeAppliesTo -ne 'both' -and $scopeAppliesTo -ne $MessageType) {
            continue
        }

        [pscustomobject]@{
            Id = [string](Get-ConfigValue -Object $item -Name 'Id' -DefaultValue '')
            State = $effectiveState
            Placement = [string](Get-ConfigValue -Object $item -Name 'Placement' -DefaultValue 'one-time-prefix')
            Priority = [int](Get-ConfigValue -Object $item -Name 'Priority' -DefaultValue 100)
            Text = [string](Get-ConfigValue -Object $item -Name 'Text' -DefaultValue '')
            ConsumeOnce = [bool](Get-ConfigValue -Object $item -Name 'ConsumeOnce' -DefaultValue $true)
            CreatedAt = [string](Get-ConfigValue -Object $item -Name 'CreatedAt' -DefaultValue '')
            CreatedBy = [string](Get-ConfigValue -Object $item -Name 'CreatedBy' -DefaultValue '')
            Notes = [string](Get-ConfigValue -Object $item -Name 'Notes' -DefaultValue '')
            Scope = $scope
        }
    }

    return @($matched | Sort-Object Priority, CreatedAt, Id)
}

function Get-OneTimeQueueSummary {
    param(
        [Parameter(Mandatory)]$QueueDocument,
        [Parameter(Mandatory)][string]$QueuePath
    )

    $effectiveStates = @($QueueDocument.Items | ForEach-Object { Get-OneTimeQueueItemEffectiveState -Item $_ })
    return [pscustomobject]@{
        QueuePath = $QueuePath
        ItemCount = @($QueueDocument.Items).Count
        QueuedCount = @($effectiveStates | Where-Object { $_ -eq 'queued' }).Count
        PreviewedCount = @($effectiveStates | Where-Object { $_ -eq 'previewed' }).Count
        ConsumedCount = @($effectiveStates | Where-Object { $_ -eq 'consumed' }).Count
        CancelledCount = @($effectiveStates | Where-Object { $_ -eq 'cancelled' }).Count
        ExpiredCount = @($effectiveStates | Where-Object { $_ -eq 'expired' }).Count
    }
}

function Split-OneTimeQueueItemsByPlacement {
    param($Items)

    return [pscustomobject]@{
        Prefix = @(@($Items) | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'Placement' -DefaultValue '') -eq 'one-time-prefix' })
        Suffix = @(@($Items) | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'Placement' -DefaultValue '') -eq 'one-time-suffix' })
    }
}

function Set-OneTimeQueueItemState {
    param(
        [Parameter(Mandatory)]$QueueDocument,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][ValidateSet('cancelled', 'consumed', 'previewed')][string]$State
    )

    $matched = $null
    foreach ($item in @($QueueDocument.Items)) {
        if ([string](Get-ConfigValue -Object $item -Name 'Id' -DefaultValue '') -eq $ItemId) {
            $item.State = $State
            if ($State -eq 'cancelled') {
                $item.Enabled = $false
            }
            $matched = $item
            break
        }
    }

    if ($null -eq $matched) {
        throw ("queue item not found: " + $ItemId)
    }

    return $matched
}

function Complete-OneTimeQueueItems {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string[]]$ItemIds,
        [switch]$IgnoreMissing
    )

    $requestedIds = @($ItemIds | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique)
    $queueState = Get-OneTimeQueueDocument -Root $Root -Config $Config -PairId $PairId
    if ($requestedIds.Count -eq 0) {
        return [pscustomobject]@{
            QueuePath = $queueState.QueuePath
            PairId = $PairId
            ConsumedCount = 0
            ConsumedItems = @()
            ArchivePaths = @()
            QueueSummary = (Get-OneTimeQueueSummary -QueueDocument $queueState.Document -QueuePath $queueState.QueuePath)
        }
    }

    $requestedSet = @{}
    foreach ($itemId in $requestedIds) {
        $requestedSet[$itemId] = $true
    }

    $consumedItems = @()
    $archivePaths = @()
    $retainedItems = New-Object System.Collections.Generic.List[object]

    foreach ($item in @($queueState.Document.Items)) {
        $itemId = [string](Get-ConfigValue -Object $item -Name 'Id' -DefaultValue '')
        if ($requestedSet.ContainsKey($itemId)) {
            $item.State = 'consumed'
            $archivePath = Write-OneTimeQueueArchiveRecord -Root $Root -Config $Config -Item $item -Reason 'consumed'
            $archivePaths += $archivePath
            $consumedItems += [pscustomobject]@{
                Id = $itemId
                State = 'consumed'
                ArchivePath = $archivePath
            }
            $requestedSet.Remove($itemId) | Out-Null
            continue
        }

        [void]$retainedItems.Add($item)
    }

    if ($requestedSet.Count -gt 0 -and -not $IgnoreMissing.IsPresent) {
        throw ('queue item not found: ' + (($requestedSet.Keys | Sort-Object) -join ', '))
    }

    Set-OneTimeQueueDocumentItems -QueueDocument $queueState.Document -Items ([object[]]$retainedItems.ToArray())
    Save-OneTimeQueueDocument -Document $queueState.Document -QueuePath $queueState.QueuePath

    return [pscustomobject]@{
        QueuePath = $queueState.QueuePath
        PairId = $PairId
        ConsumedCount = @($consumedItems).Count
        ConsumedItems = @($consumedItems)
        ArchivePaths = @($archivePaths)
        QueueSummary = (Get-OneTimeQueueSummary -QueueDocument $queueState.Document -QueuePath $queueState.QueuePath)
    }
}
