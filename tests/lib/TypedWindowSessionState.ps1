function Get-TypedWindowSessionRoot {
    param([Parameter(Mandatory)]$Config)

    $runtimeRoot = [string](Get-ConfigValue -Object $Config -Name 'RuntimeRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $runtimeRoot)) {
        $runtimeRoot = Join-Path $script:root 'runtime\bottest-live-visible'
    }

    $sessionRoot = Join-Path $runtimeRoot 'typed-window-session'
    Ensure-Directory -Path $sessionRoot
    return $sessionRoot
}

function Get-TypedWindowSessionStatePath {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey
    )

    return (Join-Path (Get-TypedWindowSessionRoot -Config $Config) ($TargetKey + '.json'))
}

function Get-DefaultTypedWindowSessionRouteKey {
    param(
        [Parameter(Mandatory)][string]$ScopeKind,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$TargetKey
    )

    if ($ScopeKind -eq 'pair') {
        return ('pair:{0}:{1}' -f $ScopeId, $TargetKey)
    }

    return ('{0}:{1}' -f $ScopeKind, $ScopeId)
}

function Resolve-TypedWindowSessionScope {
    param(
        [Parameter(Mandatory)][string]$TargetKey,
        [string]$PairIdValue = '',
        [string]$ScopeKindValue = '',
        [string]$ScopeIdValue = '',
        [string]$RouteKeyValue = ''
    )

    $resolvedScopeKind = [string]$ScopeKindValue
    if (-not (Test-NonEmptyString $resolvedScopeKind)) {
        if ((Test-NonEmptyString $RouteKeyValue) -and ($RouteKeyValue -match '^[^:]+:')) {
            $resolvedScopeKind = [string]($RouteKeyValue -replace ':.*$', '')
        }
        elseif (Test-NonEmptyString $PairIdValue) {
            $resolvedScopeKind = 'pair'
        }
        else {
            $resolvedScopeKind = 'target-autoloop'
        }
    }

    $resolvedPairId = ''
    $resolvedScopeId = [string]$ScopeIdValue
    if ($resolvedScopeKind -eq 'pair') {
        if (Test-NonEmptyString $PairIdValue) {
            $resolvedPairId = [string]$PairIdValue
        }
        elseif (Test-NonEmptyString $resolvedScopeId) {
            $resolvedPairId = $resolvedScopeId
        }
        elseif (Test-NonEmptyString $RouteKeyValue) {
            $routeSegments = @([string]$RouteKeyValue -split ':')
            if ($routeSegments.Count -ge 2 -and (Test-NonEmptyString ([string]$routeSegments[1]))) {
                $resolvedPairId = [string]$routeSegments[1]
            }
        }

        if (-not (Test-NonEmptyString $resolvedScopeId)) {
            $resolvedScopeId = $resolvedPairId
        }
    }
    else {
        if (-not (Test-NonEmptyString $resolvedScopeId) -and (Test-NonEmptyString $RouteKeyValue)) {
            $prefix = $resolvedScopeKind + ':'
            if ($RouteKeyValue.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $resolvedScopeId = $RouteKeyValue.Substring($prefix.Length)
            }
        }

        if (-not (Test-NonEmptyString $resolvedScopeId)) {
            $resolvedScopeId = $TargetKey
        }
    }

    if (-not (Test-NonEmptyString $resolvedScopeId)) {
        $resolvedScopeId = $TargetKey
    }

    $resolvedRouteKey = [string]$RouteKeyValue
    if (-not (Test-NonEmptyString $resolvedRouteKey)) {
        $resolvedRouteKey = Get-DefaultTypedWindowSessionRouteKey -ScopeKind $resolvedScopeKind -ScopeId $resolvedScopeId -TargetKey $TargetKey
    }

    return [pscustomobject]@{
        PairId = $resolvedPairId
        ScopeKind = $resolvedScopeKind
        ScopeId = $resolvedScopeId
        RouteKey = $resolvedRouteKey
    }
}

function New-TypedWindowSessionState {
    param(
        [Parameter(Mandatory)][string]$TargetKey,
        [string]$State = 'bootstrap-needed',
        [Alias('RunRoot')][string]$RunRootValue = '',
        [Alias('PairId')][string]$PairIdValue = '',
        [string]$ScopeKindValue = '',
        [string]$ScopeIdValue = '',
        [string]$RouteKeyValue = '',
        [string]$ResetReason = ''
    )

    $scope = Resolve-TypedWindowSessionScope `
        -TargetKey $TargetKey `
        -PairIdValue $PairIdValue `
        -ScopeKindValue $ScopeKindValue `
        -ScopeIdValue $ScopeIdValue `
        -RouteKeyValue $RouteKeyValue

    return [ordered]@{
        SchemaVersion                     = '1.0.0'
        TargetId                          = $TargetKey
        State                             = $State
        SessionRunRoot                    = $RunRootValue
        SessionPairId                     = [string]$scope.PairId
        SessionScopeKind                  = [string]$scope.ScopeKind
        SessionScopeId                    = [string]$scope.ScopeId
        SessionRouteKey                   = [string]$scope.RouteKey
        SessionTargetId                   = $TargetKey
        SessionEpoch                      = 0
        LastPrepareAt                     = ''
        LastSubmitAt                      = ''
        LastProgressAt                    = ''
        LastConfirmedArtifactAt           = ''
        LastResetReason                   = $ResetReason
        ConsecutiveSubmitUnconfirmedCount = 0
        UpdatedAt                         = (Get-Date).ToString('o')
    }
}

function Read-TypedWindowSessionState {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey,
        [string]$DefaultPairIdValue = '',
        [string]$DefaultScopeKindValue = '',
        [string]$DefaultScopeIdValue = '',
        [string]$DefaultRouteKeyValue = ''
    )

    $path = Get-TypedWindowSessionStatePath -Config $Config -TargetKey $TargetKey
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject](New-TypedWindowSessionState `
            -TargetKey $TargetKey `
            -PairIdValue $DefaultPairIdValue `
            -ScopeKindValue $DefaultScopeKindValue `
            -ScopeIdValue $DefaultScopeIdValue `
            -RouteKeyValue $DefaultRouteKeyValue)
    }

    try {
        $session = Read-JsonObject -Path $path
        $sessionTargetId = [string](Get-ConfigValue -Object $session -Name 'SessionTargetId' -DefaultValue $TargetKey)
        $scope = Resolve-TypedWindowSessionScope `
            -TargetKey $sessionTargetId `
            -PairIdValue ([string](Get-ConfigValue -Object $session -Name 'SessionPairId' -DefaultValue '')) `
            -ScopeKindValue ([string](Get-ConfigValue -Object $session -Name 'SessionScopeKind' -DefaultValue '')) `
            -ScopeIdValue ([string](Get-ConfigValue -Object $session -Name 'SessionScopeId' -DefaultValue '')) `
            -RouteKeyValue ([string](Get-ConfigValue -Object $session -Name 'SessionRouteKey' -DefaultValue ''))
        return [pscustomobject]@{
            SchemaVersion                     = [string](Get-ConfigValue -Object $session -Name 'SchemaVersion' -DefaultValue '1.0.0')
            TargetId                          = [string](Get-ConfigValue -Object $session -Name 'TargetId' -DefaultValue $TargetKey)
            State                             = [string](Get-ConfigValue -Object $session -Name 'State' -DefaultValue 'bootstrap-needed')
            SessionRunRoot                    = [string](Get-ConfigValue -Object $session -Name 'SessionRunRoot' -DefaultValue '')
            SessionPairId                     = [string]$scope.PairId
            SessionScopeKind                  = [string]$scope.ScopeKind
            SessionScopeId                    = [string]$scope.ScopeId
            SessionRouteKey                   = [string]$scope.RouteKey
            SessionTargetId                   = $sessionTargetId
            SessionEpoch                      = [int](Get-ConfigValue -Object $session -Name 'SessionEpoch' -DefaultValue 0)
            LastPrepareAt                     = [string](Get-ConfigValue -Object $session -Name 'LastPrepareAt' -DefaultValue '')
            LastSubmitAt                      = [string](Get-ConfigValue -Object $session -Name 'LastSubmitAt' -DefaultValue '')
            LastProgressAt                    = [string](Get-ConfigValue -Object $session -Name 'LastProgressAt' -DefaultValue '')
            LastConfirmedArtifactAt           = [string](Get-ConfigValue -Object $session -Name 'LastConfirmedArtifactAt' -DefaultValue '')
            LastResetReason                   = [string](Get-ConfigValue -Object $session -Name 'LastResetReason' -DefaultValue '')
            ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $session -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0)
            UpdatedAt                         = [string](Get-ConfigValue -Object $session -Name 'UpdatedAt' -DefaultValue '')
        }
    }
    catch {
        return [pscustomobject](New-TypedWindowSessionState `
            -TargetKey $TargetKey `
            -State 'dirty-session' `
            -PairIdValue $DefaultPairIdValue `
            -ScopeKindValue $DefaultScopeKindValue `
            -ScopeIdValue $DefaultScopeIdValue `
            -RouteKeyValue $DefaultRouteKeyValue `
            -ResetReason 'session-parse-failed')
    }
}

function Save-TypedWindowSessionState {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)]$Session
    )

    $path = Get-TypedWindowSessionStatePath -Config $Config -TargetKey $TargetKey
    $sessionTargetId = [string](Get-ConfigValue -Object $Session -Name 'SessionTargetId' -DefaultValue $TargetKey)
    $scope = Resolve-TypedWindowSessionScope `
        -TargetKey $sessionTargetId `
        -PairIdValue ([string](Get-ConfigValue -Object $Session -Name 'SessionPairId' -DefaultValue '')) `
        -ScopeKindValue ([string](Get-ConfigValue -Object $Session -Name 'SessionScopeKind' -DefaultValue '')) `
        -ScopeIdValue ([string](Get-ConfigValue -Object $Session -Name 'SessionScopeId' -DefaultValue '')) `
        -RouteKeyValue ([string](Get-ConfigValue -Object $Session -Name 'SessionRouteKey' -DefaultValue ''))
    $payload = [ordered]@{
        SchemaVersion                     = '1.0.0'
        TargetId                          = $TargetKey
        State                             = [string](Get-ConfigValue -Object $Session -Name 'State' -DefaultValue 'bootstrap-needed')
        SessionRunRoot                    = [string](Get-ConfigValue -Object $Session -Name 'SessionRunRoot' -DefaultValue '')
        SessionPairId                     = [string]$scope.PairId
        SessionScopeKind                  = [string]$scope.ScopeKind
        SessionScopeId                    = [string]$scope.ScopeId
        SessionRouteKey                   = [string]$scope.RouteKey
        SessionTargetId                   = $sessionTargetId
        SessionEpoch                      = [int](Get-ConfigValue -Object $Session -Name 'SessionEpoch' -DefaultValue 0)
        LastPrepareAt                     = [string](Get-ConfigValue -Object $Session -Name 'LastPrepareAt' -DefaultValue '')
        LastSubmitAt                      = [string](Get-ConfigValue -Object $Session -Name 'LastSubmitAt' -DefaultValue '')
        LastProgressAt                    = [string](Get-ConfigValue -Object $Session -Name 'LastProgressAt' -DefaultValue '')
        LastConfirmedArtifactAt           = [string](Get-ConfigValue -Object $Session -Name 'LastConfirmedArtifactAt' -DefaultValue '')
        LastResetReason                   = [string](Get-ConfigValue -Object $Session -Name 'LastResetReason' -DefaultValue '')
        ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $Session -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0)
        UpdatedAt                         = (Get-Date).ToString('o')
    }

    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-TypedWindowSessionInfo {
    param(
        $Session,
        [string]$DefaultTargetKey = ''
    )

    if ($null -eq $Session) {
        return [pscustomobject]@{
            State = ''
            LastResetReason = ''
            ScopeKind = ''
            ScopeId = ''
            RouteKey = ''
        }
    }

    $sessionTargetId = [string](Get-ConfigValue -Object $Session -Name 'SessionTargetId' -DefaultValue $DefaultTargetKey)
    if (-not (Test-NonEmptyString $sessionTargetId)) {
        $sessionTargetId = $DefaultTargetKey
    }
    $scope = Resolve-TypedWindowSessionScope `
        -TargetKey $sessionTargetId `
        -PairIdValue ([string](Get-ConfigValue -Object $Session -Name 'SessionPairId' -DefaultValue '')) `
        -ScopeKindValue ([string](Get-ConfigValue -Object $Session -Name 'SessionScopeKind' -DefaultValue '')) `
        -ScopeIdValue ([string](Get-ConfigValue -Object $Session -Name 'SessionScopeId' -DefaultValue '')) `
        -RouteKeyValue ([string](Get-ConfigValue -Object $Session -Name 'SessionRouteKey' -DefaultValue ''))

    return [pscustomobject]@{
        State = [string](Get-ConfigValue -Object $Session -Name 'State' -DefaultValue '')
        LastResetReason = [string](Get-ConfigValue -Object $Session -Name 'LastResetReason' -DefaultValue '')
        ScopeKind = [string]$scope.ScopeKind
        ScopeId = [string]$scope.ScopeId
        RouteKey = [string]$scope.RouteKey
    }
}
