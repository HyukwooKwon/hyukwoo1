Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PairActivationConfig {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config
    )

    $pairActivation = Get-ConfigValue -Object $Config -Name 'PairActivation' -DefaultValue @{}
    $laneName = [string](Get-ConfigValue -Object $Config -Name 'LaneName' -DefaultValue 'default')
    if (-not (Test-NonEmptyString $laneName)) {
        $laneName = 'default'
    }

    $statePath = [string](Get-ConfigValue -Object $pairActivation -Name 'StatePath' -DefaultValue '')
    if (-not (Test-NonEmptyString $statePath)) {
        $statePath = Join-Path $Root ('runtime\pair-activation\' + $laneName + '.json')
    }
    elseif (-not [System.IO.Path]::IsPathRooted($statePath)) {
        $statePath = [System.IO.Path]::GetFullPath((Join-Path $Root $statePath))
    }

    return [pscustomobject]@{
        LaneName = $laneName
        StatePath = $statePath
        DefaultEnabled = [bool](Get-ConfigValue -Object $pairActivation -Name 'DefaultEnabled' -DefaultValue $true)
    }
}

function Get-KnownPairIds {
    param(
        [string[]]$PairIds = @(),
        $Config = $null
    )

    $known = @($PairIds | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique)
    if ($known.Count -gt 0) {
        return $known
    }

    if ($null -ne $Config -and $null -ne (Get-Command -Name 'Resolve-ConfiguredPairDefinitions' -ErrorAction SilentlyContinue)) {
        try {
            $pairDefinitionSet = Resolve-ConfiguredPairDefinitions -Source $Config -SourceLabel 'config'
            $known = @(
                @($pairDefinitionSet.Pairs) |
                    ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'PairId' -DefaultValue '') } |
                    Where-Object { Test-NonEmptyString $_ } |
                    Sort-Object -Unique
            )
            if ($known.Count -gt 0) {
                return $known
            }
        }
        catch {
        }
    }

    return @('pair01', 'pair02', 'pair03', 'pair04')
}

function New-PairActivationDocument {
    param([Parameter(Mandatory)][string]$LaneName)

    return [pscustomobject]@{
        SchemaVersion = '1.0.0'
        LaneName = $LaneName
        UpdatedAt = (Get-Date).ToString('o')
        Pairs = @()
    }
}

function Get-PairActivationDocument {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config
    )

    $resolved = Resolve-PairActivationConfig -Root $Root -Config $Config
    if (-not (Test-Path -LiteralPath $resolved.StatePath)) {
        return [pscustomobject]@{
            LaneName = $resolved.LaneName
            StatePath = $resolved.StatePath
            DefaultEnabled = $resolved.DefaultEnabled
            Document = (New-PairActivationDocument -LaneName $resolved.LaneName)
        }
    }

    $document = Get-Content -LiteralPath $resolved.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($document.PSObject.Properties['SchemaVersion'] -eq $null) {
        $document | Add-Member -NotePropertyName SchemaVersion -NotePropertyValue '1.0.0'
    }
    if ($document.PSObject.Properties['LaneName'] -eq $null) {
        $document | Add-Member -NotePropertyName LaneName -NotePropertyValue $resolved.LaneName
    }
    if ($document.PSObject.Properties['Pairs'] -eq $null) {
        $document | Add-Member -NotePropertyName Pairs -NotePropertyValue @()
    }

    return [pscustomobject]@{
        LaneName = $resolved.LaneName
        StatePath = $resolved.StatePath
        DefaultEnabled = $resolved.DefaultEnabled
        Document = $document
    }
}

function Save-PairActivationDocument {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$StatePath
    )

    Ensure-Directory -Path (Split-Path -Parent $StatePath)
    $Document.UpdatedAt = (Get-Date).ToString('o')
    [System.IO.File]::WriteAllText($StatePath, ($Document | ConvertTo-Json -Depth 10), (New-Utf8NoBomEncoding))
}

function Get-PairActivationEntry {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$PairId
    )

    foreach ($item in @($Document.Pairs)) {
        if ([string](Get-ConfigValue -Object $item -Name 'PairId' -DefaultValue '') -eq $PairId) {
            return $item
        }
    }

    return $null
}

function Get-PairActivationState {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [Parameter(Mandatory)][string]$PairId
    )

    $documentState = Get-PairActivationDocument -Root $Root -Config $Config
    $entry = Get-PairActivationEntry -Document $documentState.Document -PairId $PairId
    $defaultEnabled = [bool]$documentState.DefaultEnabled

    $disabledUntil = ''
    $disableReason = ''
    $updatedAt = ''
    $updatedBy = ''
    $configuredEnabled = $defaultEnabled
    $state = if ($defaultEnabled) { 'enabled' } else { 'disabled' }
    $source = 'default'
    $isExpired = $false

    if ($null -ne $entry) {
        $configuredEnabled = [bool](Get-ConfigValue -Object $entry -Name 'Enabled' -DefaultValue $false)
        $disabledUntil = [string](Get-ConfigValue -Object $entry -Name 'DisabledUntil' -DefaultValue '')
        $disableReason = [string](Get-ConfigValue -Object $entry -Name 'DisableReason' -DefaultValue '')
        $updatedAt = [string](Get-ConfigValue -Object $entry -Name 'UpdatedAt' -DefaultValue '')
        $updatedBy = [string](Get-ConfigValue -Object $entry -Name 'UpdatedBy' -DefaultValue '')
        $source = 'runtime-override'

        if (-not $configuredEnabled -and (Test-NonEmptyString $disabledUntil)) {
            try {
                if ([datetimeoffset]::Parse($disabledUntil) -lt [datetimeoffset]::Now) {
                    $isExpired = $true
                }
            }
            catch {
            }
        }

        if ($configuredEnabled) {
            $state = 'enabled'
        }
        elseif ($isExpired) {
            $state = 'expired-auto-enabled'
            $source = 'runtime-expired'
        }
        else {
            $state = 'disabled'
        }
    }

    $effectiveEnabled = ($state -eq 'enabled' -or $state -eq 'expired-auto-enabled')
    $message = if ($effectiveEnabled) {
        if ($state -eq 'expired-auto-enabled') {
            '비활성 만료시각이 지나 자동으로 다시 활성 취급됩니다.'
        }
        else {
            '활성 상태입니다.'
        }
    }
    else {
        $reasonPart = if (Test-NonEmptyString $disableReason) { $disableReason } else { '사유 없음' }
        $untilPart = if (Test-NonEmptyString $disabledUntil) { (' / until=' + $disabledUntil) } else { '' }
        ('비활성 상태입니다. reason=' + $reasonPart + $untilPart)
    }

    return [pscustomobject]@{
        SchemaVersion = '1.0.0'
        PairId = $PairId
        LaneName = $documentState.LaneName
        StatePath = $documentState.StatePath
        DefaultEnabled = $defaultEnabled
        ConfiguredEnabled = [bool]$configuredEnabled
        EffectiveEnabled = [bool]$effectiveEnabled
        State = $state
        DisableReason = $disableReason
        DisabledUntil = $disabledUntil
        IsExpired = [bool]$isExpired
        UpdatedAt = $updatedAt
        UpdatedBy = $updatedBy
        Source = $source
        Message = $message
    }
}

function Get-PairActivationSummary {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [string[]]$PairIds = @()
    )

    return @(
        Get-KnownPairIds -PairIds $PairIds -Config $Config | ForEach-Object {
            Get-PairActivationState -Root $Root -Config $Config -PairId $_
        }
    )
}

function Set-PairActivationDisabled {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [Parameter(Mandatory)][string]$PairId,
        [string]$Reason,
        [string]$DisabledUntil,
        [string]$UpdatedBy
    )

    if (-not (Test-NonEmptyString $UpdatedBy)) {
        $UpdatedBy = if (Test-NonEmptyString $env:USERNAME) { $env:USERNAME } else { 'operator' }
    }

    $documentState = Get-PairActivationDocument -Root $Root -Config $Config
    $retained = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($documentState.Document.Pairs)) {
        if ([string](Get-ConfigValue -Object $item -Name 'PairId' -DefaultValue '') -ne $PairId) {
            [void]$retained.Add($item)
        }
    }

    [void]$retained.Add([pscustomobject]@{
        PairId = $PairId
        Enabled = $false
        DisableReason = if (Test-NonEmptyString $Reason) { $Reason } else { '' }
        DisabledUntil = if (Test-NonEmptyString $DisabledUntil) { $DisabledUntil } else { $null }
        UpdatedAt = (Get-Date).ToString('o')
        UpdatedBy = $UpdatedBy
    })

    $documentState.Document.PSObject.Properties.Remove('Pairs')
    $documentState.Document | Add-Member -NotePropertyName Pairs -NotePropertyValue ([object[]]$retained.ToArray())
    Save-PairActivationDocument -Document $documentState.Document -StatePath $documentState.StatePath
    return (Get-PairActivationState -Root $Root -Config $Config -PairId $PairId)
}

function Set-PairActivationEnabled {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [Parameter(Mandatory)][string]$PairId
    )

    $documentState = Get-PairActivationDocument -Root $Root -Config $Config
    $retained = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($documentState.Document.Pairs)) {
        if ([string](Get-ConfigValue -Object $item -Name 'PairId' -DefaultValue '') -ne $PairId) {
            [void]$retained.Add($item)
        }
    }

    $documentState.Document.PSObject.Properties.Remove('Pairs')
    $documentState.Document | Add-Member -NotePropertyName Pairs -NotePropertyValue ([object[]]$retained.ToArray())
    Save-PairActivationDocument -Document $documentState.Document -StatePath $documentState.StatePath
    return (Get-PairActivationState -Root $Root -Config $Config -PairId $PairId)
}

function Assert-PairActivationEnabled {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Config,
        [Parameter(Mandatory)][string]$PairId
    )

    $state = Get-PairActivationState -Root $Root -Config $Config -PairId $PairId
    if (-not [bool]$state.EffectiveEnabled) {
        throw ("pair 실행이 비활성화되어 있습니다: {0} / {1}" -f $PairId, [string]$state.Message)
    }

    return $state
}
