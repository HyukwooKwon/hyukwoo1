function Normalize-RelayPath {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant()
}

function Get-FileStateKey {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return ('{0}|{1}|{2}' -f (Normalize-RelayPath -Path $item.FullName), $item.Length, $item.LastWriteTimeUtc.Ticks)
}

function Enqueue-ReadyFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][System.Collections.Generic.Queue[object]]$Queue,
        [Parameter(Mandatory)][hashtable]$StateMap,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$Reason
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.EndsWith('.ready.txt', [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $key = Get-FileStateKey -Path $fullPath
    if ($StateMap.ContainsKey($key)) {
        return
    }

    $Queue.Enqueue([pscustomobject]@{
        Path      = $fullPath
        TargetId  = $TargetId
        StateKey  = $key
        QueuedAt  = (Get-Date).ToString('o')
        QueueNote = $Reason
    })

    $StateMap[$key] = 'queued'
    Write-RelayLog -Path $LogPath -Level 'info' -Message "queued [$Reason] target=$TargetId file=$fullPath"
}

function Write-RouterState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.Generic.Queue[object]]$Queue,
        [Parameter(Mandatory)][hashtable]$StateMap,
        $CurrentItem = $null,
        [string]$LastError = '',
        [string]$Status = 'running',
        [string]$StoppedAt = '',
        [string]$RouterMutexName = '',
        [int]$RouterPid = 0,
        [string]$RouterStartedAt = '',
        [string]$LauncherSessionId = '',
        [string]$LauncherLaunchedAt = '',
        [int]$LauncherPid = 0,
        [string[]]$HostKinds = @(),
        [string]$PreexistingHandlingMode = '',
        [bool]$IgnorePreexistingReadyFiles = $false,
        [bool]$RequireReadyDeliveryMetadata = $false,
        [bool]$RequirePairTransportMetadata = $false,
        [string]$IgnoredRoot = '',
        [hashtable]$StateCache = $null,
        [switch]$Force
    )

    $processing = if ($null -ne $CurrentItem) {
        [pscustomobject]@{
            TargetId = [string]$CurrentItem.TargetId
            Path     = [string]$CurrentItem.Path
            StateKey = [string]$CurrentItem.StateKey
        }
    }
    else {
        $null
    }

    $snapshotCore = [ordered]@{
        Status            = $Status
        StoppedAt         = $StoppedAt
        QueueCount        = $Queue.Count
        PendingQueueCount = $Queue.Count
        KnownStates       = $StateMap.Count
        Processing        = $processing
        LastError         = $LastError
        RouterPid         = $RouterPid
        RouterMutexName   = $RouterMutexName
        RouterStartedAt   = $RouterStartedAt
        LauncherSessionId = $LauncherSessionId
        LauncherLaunchedAt = $LauncherLaunchedAt
        LauncherPid       = $LauncherPid
        HostKinds         = @($HostKinds)
        PreexistingHandlingMode = $PreexistingHandlingMode
        IgnorePreexistingReadyFiles = [bool]$IgnorePreexistingReadyFiles
        RequireReadyDeliveryMetadata = [bool]$RequireReadyDeliveryMetadata
        RequirePairTransportMetadata = [bool]$RequirePairTransportMetadata
        IgnoredRoot       = $IgnoredRoot
    }

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $comparisonJson = [pscustomobject]$snapshotCore | ConvertTo-Json -Depth 6

    if ($null -ne $StateCache) {
        $lastComparableJson = if ($StateCache.ContainsKey('LastComparableJson')) { [string]$StateCache['LastComparableJson'] } else { '' }
        if (-not $Force -and $comparisonJson -eq $lastComparableJson) {
            return $false
        }
    }

    $snapshotData = [ordered]@{
        UpdatedAt = (Get-Date).ToString('o')
    }
    foreach ($entry in $snapshotCore.GetEnumerator()) {
        $snapshotData[$entry.Key] = $entry.Value
    }

    $snapshot = [pscustomobject]$snapshotData
    $json = $snapshot | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Utf8NoBomEncoding))
    if ($null -ne $StateCache) {
        $StateCache['LastJson'] = $json
        $StateCache['LastComparableJson'] = $comparisonJson
        $StateCache['LastWrittenAt'] = (Get-Date).ToString('o')
    }

    return $true
}
