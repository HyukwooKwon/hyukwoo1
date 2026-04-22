function Test-BindingRefreshReuseNonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Copy-BindingRefreshReuseObject {
    param($Object)

    $map = [ordered]@{}
    if ($null -eq $Object) {
        return $map
    }

    if ($Object -is [hashtable]) {
        foreach ($key in $Object.Keys) {
            $map[$key] = $Object[$key]
        }

        return $map
    }

    foreach ($property in $Object.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }

    return $map
}

function Get-BindingRefreshReuseFinding {
    param([Parameter(Mandatory)]$TargetRow)

    $reason = [string]$TargetRow.Reason
    if (-not (Test-BindingRefreshReuseNonEmptyString $reason)) {
        return ''
    }

    if ($reason -eq 'shell-missing') {
        return ("shell-missing:{0}:{1}" -f $TargetRow.TargetId, $TargetRow.ShellPid)
    }

    if ($reason -eq 'window-missing') {
        return ("window-missing:{0}:{1}" -f $TargetRow.TargetId, $TargetRow.MatchMethod)
    }

    return ("{0}:{1}" -f $reason, $TargetRow.TargetId)
}

function Resolve-BindingRefreshReuseScope {
    param(
        [Parameter(Mandatory)][object[]]$Targets,
        [Parameter(Mandatory)][string[]]$ExpectedTargetIds,
        [string[]]$GlobalFailures = @(),
        [ValidateSet('Full', 'Pairs')][string]$ReuseMode = 'Full'
    )

    $configuredTargetIds = @(
        $ExpectedTargetIds |
            ForEach-Object { [string]$_ } |
            Where-Object { Test-BindingRefreshReuseNonEmptyString $_ } |
            Sort-Object -Unique
    )

    $activePairIds = New-Object System.Collections.Generic.List[string]
    $inactivePairIds = New-Object System.Collections.Generic.List[string]
    $incompletePairIds = New-Object System.Collections.Generic.List[string]
    $activeTargetIds = New-Object System.Collections.Generic.List[string]
    $inactiveTargetIds = New-Object System.Collections.Generic.List[string]
    $orphanMatchedTargetIds = New-Object System.Collections.Generic.List[string]
    $softFindings = New-Object System.Collections.Generic.List[string]
    $hardFailures = New-Object System.Collections.Generic.List[string]

    foreach ($failure in @($GlobalFailures)) {
        if (Test-BindingRefreshReuseNonEmptyString ([string]$failure)) {
            $hardFailures.Add([string]$failure)
        }
    }

    if ($ReuseMode -eq 'Pairs') {
        $pairGroups = @($Targets | Group-Object PairId)
        foreach ($group in $pairGroups) {
            $pairId = [string]$group.Name
            $pairTargets = @($group.Group)
            $matchedTargets = @($pairTargets | Where-Object { $_.Matched })

            if (-not (Test-BindingRefreshReuseNonEmptyString $pairId)) {
                if ($matchedTargets.Count -gt 0) {
                    $hardFailures.Add(("pair-id-missing:{0}" -f (($matchedTargets | Select-Object -ExpandProperty TargetId) -join ',')))
                }
                continue
            }

            if ($matchedTargets.Count -eq 0) {
                $inactivePairIds.Add($pairId)
                foreach ($pairTarget in $pairTargets) {
                    $inactiveTargetIds.Add([string]$pairTarget.TargetId)
                    $finding = Get-BindingRefreshReuseFinding -TargetRow $pairTarget
                    if (Test-BindingRefreshReuseNonEmptyString $finding) {
                        $softFindings.Add($finding)
                    }
                }
                continue
            }

            if ($matchedTargets.Count -ne $pairTargets.Count) {
                $inactivePairIds.Add($pairId)
                $incompletePairIds.Add($pairId)
                $softFindings.Add(("incomplete-pair:{0}:{1}/{2}" -f $pairId, $matchedTargets.Count, $pairTargets.Count))
                foreach ($pairTarget in $pairTargets) {
                    $inactiveTargetIds.Add([string]$pairTarget.TargetId)
                    if ($pairTarget.Matched) {
                        $orphanMatchedTargetIds.Add([string]$pairTarget.TargetId)
                        $softFindings.Add(("orphan-target:{0}:{1}" -f $pairTarget.TargetId, $pairId))
                        continue
                    }

                    $finding = Get-BindingRefreshReuseFinding -TargetRow $pairTarget
                    if (Test-BindingRefreshReuseNonEmptyString $finding) {
                        $softFindings.Add($finding)
                    }
                }
                continue
            }

            $activePairIds.Add($pairId)
            foreach ($pairTarget in $pairTargets) {
                $activeTargetIds.Add([string]$pairTarget.TargetId)
            }
        }

        if ($activePairIds.Count -eq 0 -and $hardFailures.Count -eq 0) {
            $hardFailures.Add('no-complete-pair')
        }
    }
    else {
        foreach ($targetRow in @($Targets | Where-Object { -not $_.Matched })) {
            $finding = Get-BindingRefreshReuseFinding -TargetRow $targetRow
            if (Test-BindingRefreshReuseNonEmptyString $finding) {
                $hardFailures.Add($finding)
            }
            else {
                $hardFailures.Add(("unknown:{0}" -f $targetRow.TargetId))
            }
        }

        foreach ($targetId in @($Targets | Where-Object { $_.Matched } | Select-Object -ExpandProperty TargetId)) {
            $activeTargetIds.Add([string]$targetId)
        }
    }

    $configuredTargetCount = @($configuredTargetIds).Count
    $partialReuse = ($ReuseMode -eq 'Pairs')
    $activeTargetIdSet = @($activeTargetIds | Sort-Object -Unique)
    $activePairIdSet = @($activePairIds | Sort-Object -Unique)
    $inactivePairIdSet = @($inactivePairIds | Sort-Object -Unique)
    $incompletePairIdSet = @($incompletePairIds | Sort-Object -Unique)
    $inactiveTargetIdSet = @($inactiveTargetIds | Sort-Object -Unique)
    $orphanMatchedTargetIdSet = @($orphanMatchedTargetIds | Sort-Object -Unique)
    $sessionExpectedTargetCount = if ($partialReuse) { $activeTargetIdSet.Count } else { $configuredTargetCount }
    $success = if ($partialReuse) {
        ($activePairIdSet.Count -gt 0 -and $hardFailures.Count -eq 0)
    }
    else {
        ($hardFailures.Count -eq 0)
    }

    $annotatedTargets = foreach ($targetRow in @($Targets)) {
        $targetMap = Copy-BindingRefreshReuseObject -Object $targetRow
        $targetId = [string]$targetRow.TargetId
        $pairId = [string]$targetRow.PairId
        $countedAsReused = ($targetId -in $activeTargetIdSet)
        $inSessionScope = $countedAsReused
        $pairCompletionState = if ($pairId -in $activePairIdSet) {
            'complete'
        }
        elseif ($pairId -in $incompletePairIdSet) {
            'incomplete'
        }
        else {
            'none'
        }

        if ($partialReuse) {
            if ($countedAsReused) {
                $scopeState = 'active'
            }
            elseif ($targetId -in $orphanMatchedTargetIdSet) {
                $scopeState = 'orphan'
            }
            elseif ($targetRow.Matched) {
                $scopeState = 'hard-failed'
            }
            else {
                $scopeState = 'inactive'
            }
        }
        else {
            $countedAsReused = [bool]$targetRow.Matched
            $inSessionScope = $countedAsReused
            $scopeState = if ($targetRow.Matched) { 'active' } else { 'hard-failed' }
            if ($targetRow.Matched) {
                $pairCompletionState = 'complete'
            }
        }

        $targetMap['InSessionScope'] = [bool]$inSessionScope
        $targetMap['ScopeState'] = $scopeState
        $targetMap['CountedAsReused'] = [bool]$countedAsReused
        $targetMap['PairCompletionState'] = $pairCompletionState
        [pscustomobject]$targetMap
    }

    return [pscustomobject]@{
        ReuseMode                = if ($partialReuse) { 'pairs' } else { 'full' }
        PartialReuse             = [bool]$partialReuse
        ConfiguredTargetCount    = $configuredTargetCount
        SessionExpectedTargetCount = $sessionExpectedTargetCount
        ActivePairIds            = @($activePairIdSet)
        InactivePairIds          = @($inactivePairIdSet)
        IncompletePairIds        = @($incompletePairIdSet)
        ActiveTargetIds          = @($activeTargetIdSet)
        InactiveTargetIds        = @($inactiveTargetIdSet)
        OrphanMatchedTargetIds   = @($orphanMatchedTargetIdSet)
        SoftFindings             = @($softFindings | Sort-Object -Unique)
        HardFailures             = @($hardFailures | Sort-Object -Unique)
        AnnotatedTargets         = @($annotatedTargets)
        Success                  = [bool]$success
    }
}
