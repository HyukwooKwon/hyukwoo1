function Get-BindingSessionScopePropertyValue {
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

function Test-BindingSessionScopeHasProperty {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    if ($Object -is [hashtable]) {
        return $Object.ContainsKey($Name)
    }

    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-BindingSessionScopeArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Get-BindingSessionScopeStringList {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @(
            $Value |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
    }

    $single = [string]$Value
    if ([string]::IsNullOrWhiteSpace($single)) {
        return @()
    }

    return @($single)
}

function Get-BindingSessionScopeTargetId {
    param($Entry)

    return [string](Get-BindingSessionScopePropertyValue -Object $Entry -Name 'target_id' -DefaultValue (
        Get-BindingSessionScopePropertyValue -Object $Entry -Name 'TargetId' -DefaultValue (
            Get-BindingSessionScopePropertyValue -Object $Entry -Name 'targetId' -DefaultValue ''
        )
    ))
}

function Get-BindingSessionScopePairId {
    param($Entry)

    return [string](Get-BindingSessionScopePropertyValue -Object $Entry -Name 'pair_id' -DefaultValue (
        Get-BindingSessionScopePropertyValue -Object $Entry -Name 'PairId' -DefaultValue (
            Get-BindingSessionScopePropertyValue -Object $Entry -Name 'pairId' -DefaultValue ''
        )
    ))
}

function Get-BindingSessionScope {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$BindingDocument
    )

    $bindingData = Get-BindingSessionScopePropertyValue -Object $BindingDocument -Name 'Data' -DefaultValue $BindingDocument
    $configuredTargetIds = @(
        $Config.Targets |
            ForEach-Object { [string]$_.Id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $configuredTargetCount = [int](Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'configured_target_count' -DefaultValue (@($configuredTargetIds).Count))
    $configuredTargets = @(Get-BindingSessionScopeArray -Value (Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'configured_targets' -DefaultValue @()))
    $bindingWindows = @(Get-BindingSessionScopeArray -Value (Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'windows' -DefaultValue @()))

    $pairByTargetId = @{}
    foreach ($entry in @($configuredTargets) + @($bindingWindows)) {
        $targetId = Get-BindingSessionScopeTargetId -Entry $entry
        if ([string]::IsNullOrWhiteSpace($targetId)) {
            continue
        }

        $pairId = Get-BindingSessionScopePairId -Entry $entry
        if (-not [string]::IsNullOrWhiteSpace($pairId)) {
            $pairByTargetId[$targetId] = $pairId
        }
    }

    $requestedTargetIds = @(
        Get-BindingSessionScopeStringList -Value (
            Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'active_target_ids' -DefaultValue @()
        ) |
            Where-Object { $_ -in $configuredTargetIds }
    )

    $hasPartialReuseMetadata = Test-BindingSessionScopeHasProperty -Object $bindingData -Name 'partial_reuse'
    $partialReuseMetadata = if ($hasPartialReuseMetadata) {
        [bool](Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'partial_reuse' -DefaultValue $false)
    }
    else {
        $false
    }
    $reuseModeMetadata = [string](Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'reuse_mode' -DefaultValue '')

    if (@($requestedTargetIds).Count -eq 0) {
        $activeTargetIds = @($configuredTargetIds)
        $inactiveTargetIds = @()
    }
    else {
        $activeTargetIds = @($requestedTargetIds | Sort-Object -Unique)
        $inactiveTargetIds = @($configuredTargetIds | Where-Object { $_ -notin $activeTargetIds } | Sort-Object -Unique)
    }

    $partialReuse = [bool]($partialReuseMetadata -or (@($inactiveTargetIds).Count -gt 0))
    if ([string]::IsNullOrWhiteSpace($reuseModeMetadata)) {
        $reuseMode = if ($partialReuse) { 'pairs' } else { 'full' }
    }
    else {
        $reuseMode = $reuseModeMetadata.ToLowerInvariant()
    }

    $activePairIds = @(Get-BindingSessionScopeStringList -Value (Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'active_pair_ids' -DefaultValue @()))
    if (@($activePairIds).Count -eq 0 -and @($activeTargetIds).Count -gt 0) {
        $activePairIds = @(
            $activeTargetIds |
                ForEach-Object {
                    if ($pairByTargetId.ContainsKey($_)) { [string]$pairByTargetId[$_] } else { '' }
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
    }

    $inactivePairIds = @(Get-BindingSessionScopeStringList -Value (Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'inactive_pair_ids' -DefaultValue @()))
    if (@($inactivePairIds).Count -eq 0) {
        $inactivePairIds = @(
            $inactiveTargetIds |
                ForEach-Object {
                    if ($pairByTargetId.ContainsKey($_)) { [string]$pairByTargetId[$_] } else { '' }
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
    }

    $incompletePairIds = @(Get-BindingSessionScopeStringList -Value (Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'incomplete_pair_ids' -DefaultValue @()))
    $orphanMatchedTargetIds = @(
        Get-BindingSessionScopeStringList -Value (
            Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'orphan_matched_target_ids' -DefaultValue @()
        ) |
            Where-Object { $_ -in $configuredTargetIds }
    )
    $softFindings = @(Get-BindingSessionScopeStringList -Value (Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'soft_findings' -DefaultValue @()))
    if (@($softFindings).Count -eq 0) {
        $softFindings = @(Get-BindingSessionScopeStringList -Value (Get-BindingSessionScopePropertyValue -Object $bindingData -Name 'ignored_failure_reasons' -DefaultValue @()))
    }

    $bindingWindowTargetIds = @(
        $bindingWindows |
            ForEach-Object { Get-BindingSessionScopeTargetId -Entry $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $scopedBindingWindows = @(
        $bindingWindows |
            Where-Object { (Get-BindingSessionScopeTargetId -Entry $_) -in $activeTargetIds }
    )
    $scopedBindingTargetIds = @(
        $scopedBindingWindows |
            ForEach-Object { Get-BindingSessionScopeTargetId -Entry $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $outOfScopeBindingTargetIds = @($bindingWindowTargetIds | Where-Object { $_ -notin $activeTargetIds } | Sort-Object -Unique)

    return [pscustomobject]@{
        ConfiguredTargetIds   = @($configuredTargetIds)
        ConfiguredTargetCount = $configuredTargetCount
        ConfiguredTargets     = @($configuredTargets)
        BindingWindows        = @($bindingWindows)
        BindingWindowEntryCount = @($bindingWindows).Count
        BindingWindowTargetIds = @($bindingWindowTargetIds)
        BindingUniqueTargetCount = @($bindingWindowTargetIds).Count
        BindingWindowCount    = @($bindingWindowTargetIds).Count
        ScopedBindingWindows  = @($scopedBindingWindows)
        ScopedBindingTargetIds = @($scopedBindingTargetIds)
        ScopedBindingTargetCount = @($scopedBindingTargetIds).Count
        ScopedBindingWindowCount = @($scopedBindingTargetIds).Count
        OutOfScopeBindingTargetIds = @($outOfScopeBindingTargetIds)
        ActiveTargetIds       = @($activeTargetIds)
        ExpectedTargetIds     = @($activeTargetIds)
        ExpectedTargetCount   = @($activeTargetIds).Count
        InactiveTargetIds     = @($inactiveTargetIds)
        PartialReuse          = [bool]$partialReuse
        ReuseMode             = $reuseMode
        ActivePairIds         = @($activePairIds)
        InactivePairIds       = @($inactivePairIds)
        IncompletePairIds     = @($incompletePairIds)
        OrphanMatchedTargetIds = @($orphanMatchedTargetIds)
        SoftFindings          = @($softFindings)
    }
}
