function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Test-SharedVisibleTypedWindowLane {
    param(
        $Config = $null,
        $PairTest = $null
    )

    $laneName = [string](Get-ConfigValue -Object $Config -Name 'LaneName' -DefaultValue '')
    if ($laneName -ne 'bottest-live-visible') {
        return $false
    }

    $executionPathMode = [string](Get-ConfigValue -Object $PairTest -Name 'ExecutionPathMode' -DefaultValue '')
    if ($executionPathMode -ne 'typed-window') {
        return $false
    }

    return [bool](Get-ConfigValue -Object $PairTest -Name 'RequireUserVisibleCellExecution' -DefaultValue $false)
}

function Assert-HeadlessDispatchAllowedForLane {
    param(
        [switch]$UseHeadlessDispatch,
        [switch]$AllowHeadlessDispatchInTypedWindowLane,
        $Config = $null,
        $PairTest = $null,
        [string]$ConfigPath = ''
    )

    if (-not [bool]$UseHeadlessDispatch) {
        return
    }

    if ([bool]$AllowHeadlessDispatchInTypedWindowLane) {
        return
    }

    if (-not (Test-SharedVisibleTypedWindowLane -Config $Config -PairTest $PairTest)) {
        return
    }

    $resolvedConfigPath = if (Test-NonEmptyString $ConfigPath) { $ConfigPath } else { '<unset>' }
    throw ("headless-dispatch-disallowed-in-shared-visible-typed-window lane=bottest-live-visible config={0} override=-AllowHeadlessDispatchInTypedWindowLane" -f $resolvedConfigPath)
}

function Get-ConfigValue {
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

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
}

function Test-ConfigMemberExists {
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

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }

    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-ConfigMemberNames {
    param($Object)

    if ($null -eq $Object) {
        return @()
    }

    if ($Object -is [hashtable]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }

    return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Assert-ConfigNonNegativeInteger {
    param(
        $Value,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][string]$Context
    )

    if ($null -eq $Value) {
        return
    }

    $raw = [string]$Value
    if (-not (Test-NonEmptyString $raw)) {
        return
    }

    $parsed = 0L
    if (-not [long]::TryParse($raw, [ref]$parsed)) {
        throw ('{0}.{1} must be a non-negative integer.' -f $Context, $FieldName)
    }

    if ($parsed -lt 0) {
        throw ('{0}.{1} must be a non-negative integer.' -f $Context, $FieldName)
    }
}

function Get-TargetContractPaths {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$TargetEntry,
        $Request = $null
    )

    $targetFolder = [string]$TargetEntry.TargetFolder
    $summaryPath = if (Test-NonEmptyString ([string](Get-ConfigValue -Object $Request -Name 'SummaryPath' -DefaultValue ''))) {
        [string](Get-ConfigValue -Object $Request -Name 'SummaryPath' -DefaultValue '')
    }
    else {
        Join-Path $targetFolder ([string]$PairTest.SummaryFileName)
    }
    $reviewFolderPath = if (Test-NonEmptyString ([string](Get-ConfigValue -Object $Request -Name 'ReviewFolderPath' -DefaultValue ''))) {
        [string](Get-ConfigValue -Object $Request -Name 'ReviewFolderPath' -DefaultValue '')
    }
    else {
        Join-Path $targetFolder ([string]$PairTest.ReviewFolderName)
    }
    $requestPath = if (Test-NonEmptyString ([string](Get-ConfigValue -Object $TargetEntry -Name 'RequestPath' -DefaultValue ''))) {
        [string](Get-ConfigValue -Object $TargetEntry -Name 'RequestPath' -DefaultValue '')
    }
    else {
        Join-Path $targetFolder ([string]$PairTest.HeadlessExec.RequestFileName)
    }
    $donePath = if (Test-NonEmptyString ([string](Get-ConfigValue -Object $Request -Name 'DoneFilePath' -DefaultValue ''))) {
        [string](Get-ConfigValue -Object $Request -Name 'DoneFilePath' -DefaultValue '')
    }
    else {
        Join-Path $targetFolder ([string]$PairTest.HeadlessExec.DoneFileName)
    }
    $errorPath = if (Test-NonEmptyString ([string](Get-ConfigValue -Object $Request -Name 'ErrorFilePath' -DefaultValue ''))) {
        [string](Get-ConfigValue -Object $Request -Name 'ErrorFilePath' -DefaultValue '')
    }
    else {
        Join-Path $targetFolder ([string]$PairTest.HeadlessExec.ErrorFileName)
    }
    $resultPath = if (Test-NonEmptyString ([string](Get-ConfigValue -Object $Request -Name 'ResultFilePath' -DefaultValue ''))) {
        [string](Get-ConfigValue -Object $Request -Name 'ResultFilePath' -DefaultValue '')
    }
    else {
        Join-Path $targetFolder ([string]$PairTest.HeadlessExec.ResultFileName)
    }

    return [pscustomobject]@{
        TargetFolder     = $targetFolder
        SummaryPath      = $summaryPath
        ReviewFolderPath = $reviewFolderPath
        RequestPath      = $requestPath
        DonePath         = $donePath
        ErrorPath        = $errorPath
        ResultPath       = $resultPath
    }
}

function Get-ExternalContractPathMode {
    param(
        [Parameter(Mandatory)]$PairTest,
        $PairPolicy = $null
    )

    return [bool](Get-ConfigValue -Object $PairPolicy -Name 'UseExternalWorkRepoContractPaths' -DefaultValue ([bool](Get-ConfigValue -Object $PairTest -Name 'UseExternalWorkRepoContractPaths' -DefaultValue $false)))
}

function Test-UseExternalWorkRepoRunRoot {
    param(
        [Parameter(Mandatory)]$PairTest,
        $PairPolicy = $null,
        [string]$WorkRepoRoot = ''
    )

    if (-not (Test-NonEmptyString $WorkRepoRoot)) {
        return $false
    }

    return [bool](Get-ConfigValue -Object $PairPolicy -Name 'UseExternalWorkRepoRunRoot' -DefaultValue ([bool](Get-ConfigValue -Object $PairTest -Name 'UseExternalWorkRepoRunRoot' -DefaultValue $false)))
}

function Resolve-ExternalWorkRepoRunRootBase {
    param(
        [Parameter(Mandatory)]$PairTest,
        $PairPolicy = $null,
        [Parameter(Mandatory)][string]$WorkRepoRoot
    )

    if (-not (Test-NonEmptyString $WorkRepoRoot)) {
        throw 'external run root base requires a non-empty WorkRepoRoot.'
    }

    $relativeRootSpec = [string](Get-ConfigValue -Object $PairPolicy -Name 'ExternalWorkRepoRunRootRelativeRoot' -DefaultValue ([string](Get-ConfigValue -Object $PairTest -Name 'ExternalWorkRepoRunRootRelativeRoot' -DefaultValue '.relay-runs\bottest-live-visible')))
    if ([System.IO.Path]::IsPathRooted($relativeRootSpec)) {
        return [System.IO.Path]::GetFullPath($relativeRootSpec)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $WorkRepoRoot $relativeRootSpec))
}

function Resolve-ExternalRunRootOwnerRoot {
    param(
        [Parameter(Mandatory)]$PairTest,
        $PairPolicy = $null,
        [Parameter(Mandatory)][string]$RunRoot,
        [string]$WorkRepoRoot = ''
    )

    $resolvedRunRoot = [System.IO.Path]::GetFullPath($RunRoot)
    if (Test-NonEmptyString $WorkRepoRoot) {
        $resolvedWorkRepoRoot = [System.IO.Path]::GetFullPath($WorkRepoRoot)
        if (Test-PathEqualsOrIsDescendant -Path $resolvedRunRoot -BasePath $resolvedWorkRepoRoot) {
            return $resolvedWorkRepoRoot
        }
    }

    $relativeRootSpec = [string](Get-ConfigValue -Object $PairPolicy -Name 'ExternalWorkRepoRunRootRelativeRoot' -DefaultValue ([string](Get-ConfigValue -Object $PairTest -Name 'ExternalWorkRepoRunRootRelativeRoot' -DefaultValue '.relay-runs\bottest-live-visible')))
    if ([System.IO.Path]::IsPathRooted($relativeRootSpec)) {
        return ''
    }

    $segments = @(
        ($relativeRootSpec -split '[\\/]') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne '.' }
    )
    $ownerRoot = Split-Path -Parent $resolvedRunRoot
    foreach ($segment in @($segments)) {
        if (-not (Test-NonEmptyString $ownerRoot)) {
            return ''
        }
        $ownerRoot = Split-Path -Parent $ownerRoot
    }

    if (-not (Test-NonEmptyString $ownerRoot)) {
        return ''
    }

    return [System.IO.Path]::GetFullPath($ownerRoot)
}

function Get-StringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        if (Test-NonEmptyString $Value) {
            return ,([string]$Value)
        }

        return @()
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            if (Test-NonEmptyString $item) {
                $items.Add([string]$item)
            }
        }

        return @($items)
    }

    if (Test-NonEmptyString ([string]$Value)) {
        return ,([string]$Value)
    }

    return @()
}

function Get-ForbiddenArtifactPolicy {
    param($Source)

    $defaultLiterals = @(
        '여기에 고정문구 입력'
    )
    $defaultRegexes = @(
        '이렇게 계획개선해봤어',
        '더 개선해야될 부분이 있어\??',
        '이런부분도 참고해봐'
    )

    $literals = @(
        Get-StringArray (Get-ConfigValue -Object $Source -Name 'ForbiddenArtifactLiterals' -DefaultValue @($defaultLiterals))
    )
    $regexes = @(
        Get-StringArray (Get-ConfigValue -Object $Source -Name 'ForbiddenArtifactRegexes' -DefaultValue @($defaultRegexes))
    )

    foreach ($pattern in @($regexes)) {
        if (-not (Test-NonEmptyString $pattern)) {
            continue
        }

        try {
            $null = [regex]::new([string]$pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        catch {
            throw ("PairTest.ForbiddenArtifactRegexes contains invalid regex pattern: {0}" -f [string]$pattern)
        }
    }

    return [pscustomobject]@{
        Literals = @($literals)
        Regexes  = @($regexes)
    }
}

function Get-ForbiddenArtifactTextMatch {
    param(
        [string]$Text,
        [string[]]$LiteralList = @(),
        [string[]]$RegexPatternList = @()
    )

    if (-not (Test-NonEmptyString $Text)) {
        return [pscustomobject]@{
            Found      = $false
            MatchKind  = ''
            MatchText  = ''
            Pattern    = ''
            EntryPath  = ''
        }
    }

    foreach ($literal in @($LiteralList)) {
        if (-not (Test-NonEmptyString $literal)) {
            continue
        }
        if ($Text.Contains([string]$literal)) {
            return [pscustomobject]@{
                Found      = $true
                MatchKind  = 'literal'
                MatchText  = [string]$literal
                Pattern    = [string]$literal
                EntryPath  = ''
            }
        }
    }

    foreach ($pattern in @($RegexPatternList)) {
        if (-not (Test-NonEmptyString $pattern)) {
            continue
        }

        try {
            $match = [regex]::Match(
                $Text,
                [string]$pattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
        catch {
            continue
        }

        if ($match.Success) {
            $matchText = [string]$match.Value
            if ($matchText.Length -gt 120) {
                $matchText = ($matchText.Substring(0, 120) + ' ...')
            }

            return [pscustomobject]@{
                Found      = $true
                MatchKind  = 'regex'
                MatchText  = $matchText
                Pattern    = [string]$pattern
                EntryPath  = ''
            }
        }
    }

    return [pscustomobject]@{
        Found      = $false
        MatchKind  = ''
        MatchText  = ''
        Pattern    = ''
        EntryPath  = ''
    }
}

function Get-ForbiddenArtifactTextFileMatch {
    param(
        [string]$Path,
        [string[]]$LiteralList = @(),
        [string[]]$RegexPatternList = @()
    )

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Found      = $false
            MatchKind  = ''
            MatchText  = ''
            Pattern    = ''
            EntryPath  = ''
        }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            Found      = $false
            MatchKind  = ''
            MatchText  = ''
            Pattern    = ''
            EntryPath  = ''
        }
    }

    return (Get-ForbiddenArtifactTextMatch -Text $raw -LiteralList @($LiteralList) -RegexPatternList @($RegexPatternList))
}

function Get-ForbiddenArtifactZipMatch {
    param(
        [string]$Path,
        [string[]]$LiteralList = @(),
        [string[]]$RegexPatternList = @()
    )

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    }
    catch {
    }

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Found      = $false
            MatchKind  = ''
            MatchText  = ''
            Pattern    = ''
            EntryPath  = ''
        }
    }

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.Length -le 0 -or $entry.Length -gt 1MB) {
                    continue
                }

                $reader = $null
                try {
                    $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8, $true)
                    $content = $reader.ReadToEnd()
                    $match = Get-ForbiddenArtifactTextMatch -Text $content -LiteralList @($LiteralList) -RegexPatternList @($RegexPatternList)
                    if ([bool]$match.Found) {
                        $match | Add-Member -NotePropertyName 'EntryPath' -NotePropertyValue ([string]$entry.FullName) -Force
                        return $match
                    }
                }
                catch {
                }
                finally {
                    if ($null -ne $reader) {
                        $reader.Dispose()
                    }
                }
            }
        }
        finally {
            if ($null -ne $archive) {
                $archive.Dispose()
            }
        }
    }
    catch {
    }

    return [pscustomobject]@{
        Found      = $false
        MatchKind  = ''
        MatchText  = ''
        Pattern    = ''
        EntryPath  = ''
    }
}

function Get-RelaySubmitRetryModes {
    param(
        [Parameter(Mandatory)]$Config,
        [string[]]$DefaultValues = @('enter')
    )

    $seen = @{}
    $normalizedModes = New-Object System.Collections.Generic.List[string]
    foreach ($mode in @(Get-StringArray (Get-ConfigValue -Object $Config -Name 'SubmitRetryModes' -DefaultValue @($DefaultValues)))) {
        $normalized = [string]$mode
        if (-not (Test-NonEmptyString $normalized)) {
            continue
        }

        $normalized = $normalized.Trim().ToLowerInvariant()
        if (-not (Test-NonEmptyString $normalized)) {
            continue
        }
        if ($seen.ContainsKey($normalized)) {
            continue
        }

        $seen[$normalized] = $true
        $normalizedModes.Add($normalized)
    }

    if ($normalizedModes.Count -gt 0) {
        return @($normalizedModes)
    }

    return @('enter')
}

function Get-RelayPrimarySubmitMode {
    param([string[]]$Modes = @())

    $normalizedModes = @($Modes | Where-Object { Test-NonEmptyString $_ })
    if ($normalizedModes.Count -eq 0) {
        return ''
    }

    return [string]$normalizedModes[0]
}

function Get-RelayFinalSubmitMode {
    param([string[]]$Modes = @())

    $normalizedModes = @($Modes | Where-Object { Test-NonEmptyString $_ })
    if ($normalizedModes.Count -eq 0) {
        return ''
    }

    return [string]$normalizedModes[-1]
}

function Get-RelaySubmitRetrySequenceSummary {
    param([string[]]$Modes = @())

    $normalizedModes = @($Modes | Where-Object { Test-NonEmptyString $_ })
    if ($normalizedModes.Count -eq 0) {
        return ''
    }

    return ([string]::Join(' -> ', $normalizedModes))
}

function Test-PairedAcceptanceSuccessState {
    param([string]$AcceptanceState)

    return ($AcceptanceState -in @('roundtrip-confirmed', 'first-handoff-confirmed'))
}

function Test-PairedSourceOutboxAcceptedRow {
    param($Row)

    $state = [string](Get-ConfigValue -Object $Row -Name 'SourceOutboxState' -DefaultValue '')
    $nextAction = [string](Get-ConfigValue -Object $Row -Name 'SourceOutboxNextAction' -DefaultValue '')
    $latestState = [string](Get-ConfigValue -Object $Row -Name 'LatestState' -DefaultValue '')

    if ($state -in @('imported', 'imported-archive-pending', 'forwarded')) {
        return $true
    }
    if ($state -in @('duplicate-marker-archived', 'duplicate-marker-present')) {
        return (
            $nextAction -in @('handoff-ready', 'already-forwarded', 'duplicate-skipped') -or
            $latestState -in @('ready-to-forward', 'forwarded', 'duplicate-skipped')
        )
    }
    return $false
}

function Test-PairedSourceOutboxObservedRow {
    param($Row)

    if ($null -eq $Row) {
        return $false
    }

    $state = [string](Get-ConfigValue -Object $Row -Name 'SourceOutboxState' -DefaultValue '')
    $latestState = [string](Get-ConfigValue -Object $Row -Name 'LatestState' -DefaultValue '')
    $publishReadyPath = [string](Get-ConfigValue -Object $Row -Name 'PublishReadyPath' -DefaultValue '')
    $summaryPath = [string](Get-ConfigValue -Object $Row -Name 'SourceSummaryPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $summaryPath)) {
        $summaryPath = [string](Get-ConfigValue -Object $Row -Name 'SummaryPath' -DefaultValue '')
    }
    $reviewZipPath = [string](Get-ConfigValue -Object $Row -Name 'SourceReviewZipPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $reviewZipPath)) {
        $reviewZipPath = [string](Get-ConfigValue -Object $Row -Name 'ReviewZipPath' -DefaultValue '')
    }

    if ($state -in @('publish-started', 'imported', 'imported-archive-pending', 'duplicate-marker-archived', 'duplicate-marker-present', 'forwarded')) {
        return $true
    }
    if ($latestState -in @('ready-to-forward', 'forwarded', 'duplicate-skipped')) {
        return $true
    }
    if ((Test-NonEmptyString $publishReadyPath) -and (Test-Path -LiteralPath $publishReadyPath)) {
        return $true
    }
    if ((Test-NonEmptyString $summaryPath) -and (Test-Path -LiteralPath $summaryPath) -and
        (Test-NonEmptyString $reviewZipPath) -and (Test-Path -LiteralPath $reviewZipPath)) {
        return $true
    }
    return $false
}

function Test-PairedSourceOutboxStrictReadyRow {
    param($Row)

    if ($null -eq $Row) {
        return $false
    }

    if (Test-PairedSourceOutboxAcceptedRow -Row $Row) {
        return $true
    }
    if (Test-PairedHandoffTransitionReadyRow -Row $Row) {
        return $true
    }

    $publishReadyPath = [string](Get-ConfigValue -Object $Row -Name 'PublishReadyPath' -DefaultValue '')
    $summaryPath = [string](Get-ConfigValue -Object $Row -Name 'SourceSummaryPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $summaryPath)) {
        $summaryPath = [string](Get-ConfigValue -Object $Row -Name 'SummaryPath' -DefaultValue '')
    }
    $reviewZipPath = [string](Get-ConfigValue -Object $Row -Name 'SourceReviewZipPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $reviewZipPath)) {
        $reviewZipPath = [string](Get-ConfigValue -Object $Row -Name 'ReviewZipPath' -DefaultValue '')
    }

    return (
        (Test-NonEmptyString $publishReadyPath) -and (Test-Path -LiteralPath $publishReadyPath) -and
        (Test-NonEmptyString $summaryPath) -and (Test-Path -LiteralPath $summaryPath) -and
        (Test-NonEmptyString $reviewZipPath) -and (Test-Path -LiteralPath $reviewZipPath)
    )
}

function Test-PairedHandoffTransitionReadyRow {
    param($Row)

    $nextAction = [string](Get-ConfigValue -Object $Row -Name 'SourceOutboxNextAction' -DefaultValue '')
    $latestState = [string](Get-ConfigValue -Object $Row -Name 'LatestState' -DefaultValue '')

    return (
        $nextAction -in @('handoff-ready', 'already-forwarded', 'duplicate-skipped') -or
        $latestState -in @('ready-to-forward', 'forwarded', 'duplicate-skipped')
    )
}

function Test-PairedHandoffAcceptedRow {
    param($Row)

    $latestState = [string](Get-ConfigValue -Object $Row -Name 'LatestState' -DefaultValue '')
    $sourceOutboxState = [string](Get-ConfigValue -Object $Row -Name 'SourceOutboxState' -DefaultValue '')

    return (
        $latestState -in @('forwarded', 'duplicate-skipped') -or
        $sourceOutboxState -eq 'forwarded'
    )
}

function Test-PairedPartnerProgressObserved {
    param($Row)

    if ($null -eq $Row) {
        return $false
    }

    $submitState = [string](Get-ConfigValue -Object $Row -Name 'SubmitState' -DefaultValue '')
    $sourceOutboxState = [string](Get-ConfigValue -Object $Row -Name 'SourceOutboxState' -DefaultValue '')
    $latestState = [string](Get-ConfigValue -Object $Row -Name 'LatestState' -DefaultValue '')
    $dispatchState = [string](Get-ConfigValue -Object $Row -Name 'DispatchState' -DefaultValue '')

    if (Test-NonEmptyString $submitState) {
        return $true
    }
    if (Test-NonEmptyString $sourceOutboxState) {
        return $true
    }
    if ($dispatchState -in @('running', 'failed')) {
        return $true
    }
    return ($latestState -in @('ready-to-forward', 'forwarded', 'duplicate-skipped'))
}

function Test-PairedFirstHandoffDetected {
    param(
        $CurrentRow,
        $PartnerRow = $null,
        [int]$ForwardedCount = 0,
        [int]$PartnerReadyCount = 0,
        [int]$InitialPartnerInboxCount = 0,
        [switch]$UseVisibleWorker
    )

    if ($UseVisibleWorker) {
        return (
            $ForwardedCount -ge 1 -or
            (Test-PairedHandoffTransitionReadyRow -Row $CurrentRow) -or
            (Test-PairedHandoffAcceptedRow -Row $CurrentRow) -or
            ((Test-PairedSourceOutboxObservedRow -Row $CurrentRow) -and (Test-PairedPartnerProgressObserved -Row $PartnerRow))
        )
    }

    $currentLatestState = [string](Get-ConfigValue -Object $CurrentRow -Name 'LatestState' -DefaultValue '')
    return ($currentLatestState -eq 'forwarded' -or $PartnerReadyCount -gt $InitialPartnerInboxCount)
}

function Test-PairedRoundtripDetected {
    param(
        $SeedRow,
        $PartnerRow = $null,
        [int]$ForwardedCount = 0,
        [int]$SeedReadyCount = 0,
        [int]$RoundtripBaselineSeedInboxCount = 0,
        [switch]$UseVisibleWorker
    )

    if ($UseVisibleWorker) {
        return (
            $ForwardedCount -ge 2 -or
            (Test-PairedHandoffAcceptedRow -Row $PartnerRow)
        )
    }

    return ($SeedReadyCount -gt $RoundtripBaselineSeedInboxCount)
}

function Get-PairedAcceptanceManualAttentionOutcome {
    param([string]$RetryReason = '')

    $reason = if (Test-NonEmptyString $RetryReason) { $RetryReason } else { 'manual-attention-required' }
    return [pscustomobject]@{
        AcceptanceState = 'manual_attention_required'
        AcceptanceReason = $reason
    }
}

function Get-PairedAcceptanceFailureOutcome {
    param(
        [string]$SubmitState = '',
        [string]$ExecutionState = '',
        [string]$SubmitReason = ''
    )

    $state = if ($SubmitState -eq 'unconfirmed') { 'submit-unconfirmed' } else { $ExecutionState }
    if (-not (Test-NonEmptyString $state)) {
        $state = 'error'
    }
    $reason = if (Test-NonEmptyString $SubmitReason) { $SubmitReason } else { $state }

    return [pscustomobject]@{
        AcceptanceState = $state
        AcceptanceReason = $reason
    }
}

function Get-PairedAcceptanceSuccessOutcome {
    param(
        [switch]$FirstHandoff,
        [switch]$Roundtrip,
        [switch]$UseVisibleWorker
    )

    if ($Roundtrip) {
        return [pscustomobject]@{
            AcceptanceState = 'roundtrip-confirmed'
            AcceptanceReason = if ($UseVisibleWorker) { 'forwarded-state-roundtrip-detected' } else { 'seed-target-received-followup-ready-file' }
        }
    }

    if ($FirstHandoff) {
        return [pscustomobject]@{
            AcceptanceState = 'first-handoff-confirmed'
            AcceptanceReason = if ($UseVisibleWorker) { 'forwarded-state-detected' } else { 'partner-ready-file-detected' }
        }
    }

    return [pscustomobject]@{
        AcceptanceState = 'waiting'
        AcceptanceReason = ''
    }
}

function Get-PairedAcceptanceTimeoutOutcome {
    param(
        [bool]$FirstHandoffConfirmed,
        [switch]$UseVisibleWorker,
        [string]$WatcherStopSuffix = ''
    )

    if ($FirstHandoffConfirmed) {
        $state = 'roundtrip-timeout'
        $reason = if ($UseVisibleWorker) { 'roundtrip-forwarded-state-not-detected' } else { 'seed-target-followup-ready-file-not-detected' }
    }
    else {
        $state = 'first-handoff-timeout'
        $reason = if ($UseVisibleWorker) { 'first-forwarded-state-not-detected' } else { 'partner-ready-file-not-detected' }
    }

    return [pscustomobject]@{
        AcceptanceState = $state
        AcceptanceReason = ($reason + $WatcherStopSuffix)
    }
}

function New-PairedPrimitiveEvidence {
    param(
        $TargetRow = $null,
        $PartnerRow = $null,
        $PairRow = $null,
        $Receipt = $null,
        $Watcher = $null,
        $Counts = $null,
        [hashtable]$Extra = @{}
    )

    $evidence = [ordered]@{}
    if ($null -ne $TargetRow) {
        $evidence.Target = $TargetRow
    }
    if ($null -ne $PartnerRow) {
        $evidence.Partner = $PartnerRow
    }
    if ($null -ne $PairRow) {
        $evidence.Pair = $PairRow
    }
    if ($null -ne $Receipt) {
        $evidence.AcceptanceReceipt = $Receipt
    }
    if ($null -ne $Watcher) {
        $evidence.Watcher = $Watcher
    }
    if ($null -ne $Counts) {
        $evidence.Counts = $Counts
    }
    foreach ($key in @($Extra.Keys | Sort-Object)) {
        $evidence[$key] = $Extra[$key]
    }

    return [pscustomobject]$evidence
}

function Get-DefaultMessageSlotOrder {
    param([string]$TemplateName = '')

    return @(
        'global-prefix',
        'pair-extra',
        'role-extra',
        'target-extra',
        'one-time-prefix',
        'body',
        'one-time-suffix',
        'global-suffix'
    )
}

function Get-OrderedMessageSlotSequence {
    param(
        [string[]]$RequestedSlotOrder = @(),
        [string]$TemplateName = ''
    )

    $sequence = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($slot in @($RequestedSlotOrder) + @(Get-DefaultMessageSlotOrder -TemplateName $TemplateName)) {
        if (-not (Test-NonEmptyString $slot)) {
            continue
        }
        if ($seen.ContainsKey([string]$slot)) {
            continue
        }
        $seen[[string]$slot] = $true
        $sequence.Add([string]$slot)
    }
    return @($sequence)
}

function Split-OneTimeItemsByPlacement {
    param($Items)

    return [pscustomobject]@{
        Prefix = @(@($Items) | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'Placement' -DefaultValue '') -eq 'one-time-prefix' })
        Suffix = @(@($Items) | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'Placement' -DefaultValue '') -eq 'one-time-suffix' })
    }
}

function Get-OrderedMessageBlocks {
    param(
        [Parameter(Mandatory)]$TemplateBlocks,
        [Parameter(Mandatory)][string]$BodyText,
        $OneTimeItems = @()
    )

    $oneTimeSplit = Split-OneTimeItemsByPlacement -Items $OneTimeItems
    $orderedBlocks = New-Object System.Collections.Generic.List[string]
    $slotOrder = Get-OrderedMessageSlotSequence -RequestedSlotOrder @(Get-ConfigValue -Object $TemplateBlocks -Name 'SlotOrder' -DefaultValue @()) -TemplateName ''

    foreach ($slot in @($slotOrder)) {
        $texts = switch ([string]$slot) {
            'global-prefix' { @($TemplateBlocks.PrefixBlocks) }
            'pair-extra' { @($TemplateBlocks.Sources.Pair) }
            'role-extra' { @($TemplateBlocks.Sources.Role) }
            'target-extra' { @($TemplateBlocks.Sources.Target) }
            'one-time-prefix' { @($oneTimeSplit.Prefix | ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'Text' -DefaultValue '') }) }
            'body' { @($BodyText) }
            'one-time-suffix' { @($oneTimeSplit.Suffix | ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'Text' -DefaultValue '') }) }
            'global-suffix' { @($TemplateBlocks.SuffixBlocks) }
            default { @() }
        }

        foreach ($text in @($texts)) {
            if (Test-NonEmptyString $text) {
                $orderedBlocks.Add([string]$text)
            }
        }
    }

    return @($orderedBlocks)
}

function Expand-RunRootPattern {
    param([Parameter(Mandatory)][string]$Pattern)

    return [regex]::Replace($Pattern, '\{([^}]+)\}', {
        param($match)

        $format = [string]$match.Groups[1].Value
        try {
            return (Get-Date -Format $format)
        }
        catch {
            return $match.Value
        }
    })
}

function Resolve-FullPathFromBase {
    param(
        [Parameter(Mandatory)][string]$PathValue,
        [Parameter(Mandatory)][string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Get-BookkeepingResidualRootsEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$BasePath
    )

    $rootKeys = @(
        'InboxRoot',
        'ProcessedRoot',
        'RuntimeRoot',
        'LogsRoot'
    )

    $items = @()
    foreach ($key in $rootKeys) {
        $rawValue = [string](Get-ConfigValue -Object $Config -Name $key -DefaultValue '')
        if (-not (Test-NonEmptyString $rawValue)) {
            continue
        }

        $items += [pscustomobject]@{
            Name = [string]$key
            Path = (Resolve-FullPathFromBase -PathValue $rawValue -BasePath $BasePath)
        }
    }

    return @($items)
}

function Test-PathInsideAnyAllowedRoot {
    param(
        [string]$Path,
        [string[]]$AllowedRootPaths = @()
    )

    foreach ($allowedRootPath in @($AllowedRootPaths)) {
        if (-not (Test-NonEmptyString ([string]$allowedRootPath))) {
            continue
        }

        if (Test-PathEqualsOrIsDescendant -Path $Path -BasePath ([string]$allowedRootPath)) {
            return $true
        }
    }

    return $false
}

function Test-PathEqualsOrIsDescendant {
    param(
        [string]$Path,
        [string]$BasePath
    )

    if (-not (Test-NonEmptyString $Path) -or -not (Test-NonEmptyString $BasePath)) {
        return $false
    }

    $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $normalizedBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\')
    if ($normalizedPath -eq $normalizedBase) {
        return $true
    }

    return $normalizedPath.StartsWith(($normalizedBase + '\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-BookkeepingRootsPolicy {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$PairTest,
        $PairPolicy = $null,
        [Parameter(Mandatory)][string]$AutomationRoot,
        [Parameter(Mandatory)][string]$BasePath,
        [string]$WorkRepoRoot = '',
        [string[]]$AllowedRootPaths = @()
    )

    $requiresExternalBookkeeping = (
        [bool](Get-ConfigValue -Object $PairPolicy -Name 'RequireExternalRunRoot' -DefaultValue ([bool](Get-ConfigValue -Object $PairTest -Name 'RequireExternalRunRoot' -DefaultValue $false))) -or
        [bool](Get-ConfigValue -Object $PairPolicy -Name 'UseExternalWorkRepoRunRoot' -DefaultValue ([bool](Get-ConfigValue -Object $PairTest -Name 'UseExternalWorkRepoRunRoot' -DefaultValue $false)))
    )

    if (-not $requiresExternalBookkeeping) {
        return [pscustomobject]@{
            Passed = $true
            Reason = ''
            Detail = ''
            ResidualRoots = @()
        }
    }

    if (-not (Test-NonEmptyString $WorkRepoRoot)) {
        return [pscustomobject]@{
            Passed = $false
            Reason = 'external-bookkeeping-workrepo-required'
            Detail = 'WorkRepoRoot is empty.'
            ResidualRoots = @()
        }
    }

    $resolvedAutomationRoot = [System.IO.Path]::GetFullPath($AutomationRoot)
    $resolvedWorkRepoRoot = [System.IO.Path]::GetFullPath($WorkRepoRoot)
    $normalizedAllowedRootPaths = @(
        @($AllowedRootPaths) |
            Where-Object { Test-NonEmptyString ([string]$_) } |
            ForEach-Object { [System.IO.Path]::GetFullPath([string]$_) } |
            Sort-Object -Unique
    )
    $residualRoots = @(Get-BookkeepingResidualRootsEvidence -Config $Config -BasePath $BasePath)

    foreach ($item in @($residualRoots)) {
        $path = [string]$item.Path
        if (-not (Test-NonEmptyString $path)) {
            continue
        }

        if (Test-PathEqualsOrIsDescendant -Path $path -BasePath $resolvedAutomationRoot) {
            return [pscustomobject]@{
                Passed = $false
                Reason = 'automation-repo-bookkeeping-roots-disallowed'
                Detail = ('{0} must be outside automation repo. automationRoot={1} path={2}' -f [string]$item.Name, $resolvedAutomationRoot, $path)
                ResidualRoots = @($residualRoots)
            }
        }

        $pathAllowed = if ($normalizedAllowedRootPaths.Count -gt 0) {
            Test-PathInsideAnyAllowedRoot -Path $path -AllowedRootPaths $normalizedAllowedRootPaths
        }
        else {
            Test-PathEqualsOrIsDescendant -Path $path -BasePath $resolvedWorkRepoRoot
        }

        if (-not $pathAllowed) {
            $detail = if ($normalizedAllowedRootPaths.Count -gt 0) {
                ('{0} must be inside one of the allowed external bookkeeping roots. allowedRoots={1} path={2}' -f [string]$item.Name, ($normalizedAllowedRootPaths -join ', '), $path)
            }
            else {
                ('{0} must be inside WorkRepoRoot. workRepoRoot={1} path={2}' -f [string]$item.Name, $resolvedWorkRepoRoot, $path)
            }
            return [pscustomobject]@{
                Passed = $false
                Reason = 'bookkeeping-root-outside-workrepo'
                Detail = $detail
                ResidualRoots = @($residualRoots)
            }
        }
    }

    return [pscustomobject]@{
        Passed = $true
        Reason = ''
        Detail = ''
        ResidualRoots = @($residualRoots)
    }
}

function Test-SeedWorkRepoPolicy {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$PairPolicy,
        [Parameter(Mandatory)][string]$AutomationRoot,
        [string]$WorkRepoRoot,
        [string]$ReviewInputPath = ''
    )

    $requireExternal = [bool](Get-ConfigValue -Object $PairPolicy -Name 'RequireExternalSeedWorkRepo' -DefaultValue (Get-ConfigValue -Object $PairTest -Name 'RequireExternalSeedWorkRepo' -DefaultValue $false))
    if (-not $requireExternal) {
        return [pscustomobject]@{
            Passed = $true
            Reason = ''
            Detail = ''
        }
    }

    if (-not (Test-NonEmptyString $WorkRepoRoot)) {
        return [pscustomobject]@{
            Passed = $false
            Reason = 'external-workrepo-required'
            Detail = 'WorkRepoRoot is empty.'
        }
    }

    $resolvedAutomationRoot = [System.IO.Path]::GetFullPath($AutomationRoot)
    $resolvedWorkRepoRoot = [System.IO.Path]::GetFullPath($WorkRepoRoot)
    if (Test-PathEqualsOrIsDescendant -Path $resolvedWorkRepoRoot -BasePath $resolvedAutomationRoot) {
        return [pscustomobject]@{
            Passed = $false
            Reason = 'automation-repo-workrepo-disallowed'
            Detail = ('WorkRepoRoot must be outside automation repo. automationRoot={0} workRepoRoot={1}' -f $resolvedAutomationRoot, $resolvedWorkRepoRoot)
        }
    }

    if (Test-NonEmptyString $ReviewInputPath) {
        $resolvedReviewInputPath = [System.IO.Path]::GetFullPath($ReviewInputPath)
        if (Test-PathEqualsOrIsDescendant -Path $resolvedReviewInputPath -BasePath $resolvedAutomationRoot) {
            return [pscustomobject]@{
                Passed = $false
                Reason = 'automation-repo-reviewinput-disallowed'
                Detail = ('ReviewInputPath must be outside automation repo. automationRoot={0} reviewInputPath={1}' -f $resolvedAutomationRoot, $resolvedReviewInputPath)
            }
        }
    }

    return [pscustomobject]@{
        Passed = $true
        Reason = ''
        Detail = ''
    }
}

function Assert-SeedWorkRepoPolicy {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$PairPolicy,
        [Parameter(Mandatory)][string]$AutomationRoot,
        [string]$WorkRepoRoot,
        [string]$ReviewInputPath = ''
    )

    $policyResult = Test-SeedWorkRepoPolicy `
        -PairTest $PairTest `
        -PairPolicy $PairPolicy `
        -AutomationRoot $AutomationRoot `
        -WorkRepoRoot $WorkRepoRoot `
        -ReviewInputPath $ReviewInputPath

    if (-not [bool]$policyResult.Passed) {
        throw ('seed work repo policy failed: {0} detail={1}' -f [string]$policyResult.Reason, [string]$policyResult.Detail)
    }
}

function Test-RunRootPolicy {
    param(
        [Parameter(Mandatory)]$PairTest,
        $PairPolicy = $null,
        [Parameter(Mandatory)][string]$AutomationRoot,
        [string]$RunRoot,
        [string]$WorkRepoRoot = ''
    )

    $requireExternalRunRoot = [bool](Get-ConfigValue -Object $PairPolicy -Name 'RequireExternalRunRoot' -DefaultValue ([bool](Get-ConfigValue -Object $PairTest -Name 'RequireExternalRunRoot' -DefaultValue $false)))
    if (-not $requireExternalRunRoot) {
        return [pscustomobject]@{
            Passed = $true
            Reason = ''
            Detail = ''
        }
    }

    if (-not (Test-NonEmptyString $RunRoot)) {
        return [pscustomobject]@{
            Passed = $false
            Reason = 'external-runroot-required'
            Detail = 'RunRoot is empty.'
        }
    }

    if (-not (Test-NonEmptyString $WorkRepoRoot)) {
        return [pscustomobject]@{
            Passed = $false
            Reason = 'external-runroot-workrepo-required'
            Detail = 'WorkRepoRoot is empty.'
        }
    }

    $resolvedAutomationRoot = [System.IO.Path]::GetFullPath($AutomationRoot)
    $resolvedRunRoot = [System.IO.Path]::GetFullPath($RunRoot)
    if (Test-PathEqualsOrIsDescendant -Path $resolvedRunRoot -BasePath $resolvedAutomationRoot) {
        return [pscustomobject]@{
            Passed = $false
            Reason = 'automation-repo-runroot-disallowed'
            Detail = ('RunRoot must be outside automation repo. automationRoot={0} runRoot={1}' -f $resolvedAutomationRoot, $resolvedRunRoot)
        }
    }

    $resolvedWorkRepoRoot = [System.IO.Path]::GetFullPath($WorkRepoRoot)
    if (-not (Test-PathEqualsOrIsDescendant -Path $resolvedRunRoot -BasePath $resolvedWorkRepoRoot)) {
        return [pscustomobject]@{
            Passed = $false
            Reason = 'external-runroot-outside-workrepo'
            Detail = ('RunRoot must be inside WorkRepoRoot. workRepoRoot={0} runRoot={1}' -f $resolvedWorkRepoRoot, $resolvedRunRoot)
        }
    }

    return [pscustomobject]@{
        Passed = $true
        Reason = ''
        Detail = ''
    }
}

function Assert-RunRootPolicy {
    param(
        [Parameter(Mandatory)]$PairTest,
        $PairPolicy = $null,
        [Parameter(Mandatory)][string]$AutomationRoot,
        [string]$RunRoot,
        [string]$WorkRepoRoot = ''
    )

    $policyResult = Test-RunRootPolicy `
        -PairTest $PairTest `
        -PairPolicy $PairPolicy `
        -AutomationRoot $AutomationRoot `
        -RunRoot $RunRoot `
        -WorkRepoRoot $WorkRepoRoot

    if (-not [bool]$policyResult.Passed) {
        throw ('run root policy failed: {0} detail={1}' -f [string]$policyResult.Reason, [string]$policyResult.Detail)
    }
}

function Assert-BookkeepingRootsPolicy {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$PairTest,
        $PairPolicy = $null,
        [Parameter(Mandatory)][string]$AutomationRoot,
        [Parameter(Mandatory)][string]$BasePath,
        [string]$WorkRepoRoot = '',
        [string[]]$AllowedRootPaths = @()
    )

    $policyResult = Test-BookkeepingRootsPolicy `
        -Config $Config `
        -PairTest $PairTest `
        -PairPolicy $PairPolicy `
        -AutomationRoot $AutomationRoot `
        -BasePath $BasePath `
        -WorkRepoRoot $WorkRepoRoot `
        -AllowedRootPaths $AllowedRootPaths

    if (-not [bool]$policyResult.Passed) {
        throw ('bookkeeping root policy failed: {0} detail={1}' -f [string]$policyResult.Reason, [string]$policyResult.Detail)
    }
}

function Resolve-ConfiguredPairRowSet {
    param($Source = $null)

    $pairRows = @(
        Get-ConfigValue -Object $Source -Name 'PairDefinitions' -DefaultValue @()
    )
    $sourceDetail = ''
    if (@($pairRows).Count -gt 0) {
        $sourceDetail = 'pair-definitions'
    }
    if (@($pairRows).Count -eq 0) {
        $pairRows = @(
            Get-ConfigValue -Object $Source -Name 'Pairs' -DefaultValue @()
        )
        if (@($pairRows).Count -gt 0) {
            $sourceDetail = 'pairs'
        }
    }
    if (@($pairRows).Count -eq 0) {
        $nestedPairTest = Get-ConfigValue -Object $Source -Name 'PairTest' -DefaultValue $null
        if ($null -ne $nestedPairTest) {
            $pairRows = @(
                Get-ConfigValue -Object $nestedPairTest -Name 'PairDefinitions' -DefaultValue @()
            )
            if (@($pairRows).Count -gt 0) {
                $sourceDetail = 'pair-definitions'
            }
            if (@($pairRows).Count -eq 0) {
                $pairRows = @(
                    Get-ConfigValue -Object $nestedPairTest -Name 'Pairs' -DefaultValue @()
                )
                if (@($pairRows).Count -gt 0) {
                    $sourceDetail = 'pairs'
                }
            }
        }
    }

    return [pscustomobject]@{
        Rows = @($pairRows)
        SourceDetail = [string]$sourceDetail
    }
}

function Get-ConfiguredTargetRows {
    param($Source = $null)

    $targetRows = @(
        Get-ConfigValue -Object $Source -Name 'Targets' -DefaultValue @()
    )
    if (@($targetRows).Count -eq 0) {
        $nestedPairTest = Get-ConfigValue -Object $Source -Name 'PairTest' -DefaultValue $null
        if ($null -ne $nestedPairTest) {
            $targetRows = @(
                Get-ConfigValue -Object $nestedPairTest -Name 'Targets' -DefaultValue @()
            )
        }
    }

    return @($targetRows)
}

function Get-FallbackPairDefinitions {
    param($Source = $null)

    $targetRows = @(Get-ConfiguredTargetRows -Source $Source)
    if (@($targetRows).Count -eq 0) {
        throw 'PairDefinitions are required when no fallback Targets are available.'
    }
    if ((@($targetRows).Count % 2) -ne 0) {
        throw ('PairDefinitions are required because fallback target-order pairing needs an even number of Targets. actual={0}' -f @($targetRows).Count)
    }

    $targetIds = New-Object System.Collections.Generic.List[string]
    foreach ($targetRow in @($targetRows)) {
        $targetId = [string](Get-ConfigValue -Object $targetRow -Name 'Id' -DefaultValue '')
        if (-not (Test-NonEmptyString $targetId)) {
            $targetId = [string](Get-ConfigValue -Object $targetRow -Name 'TargetId' -DefaultValue '')
        }
        if (-not (Test-NonEmptyString $targetId)) {
            throw 'Fallback target-order pairing requires every target row to define Id or TargetId.'
        }
        $targetIds.Add($targetId)
    }

    $pairCount = [int]($targetIds.Count / 2)
    $pairs = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $pairCount; $index++) {
        $pairOrdinal = $index + 1
        $topTargetId = [string]$targetIds[$index]
        $bottomTargetId = [string]$targetIds[$index + $pairCount]
        $pairs.Add([pscustomobject]@{
                PairId = ('pair{0:d2}' -f $pairOrdinal)
                TopTargetId = $topTargetId
                BottomTargetId = $bottomTargetId
                SeedTargetId = $topTargetId
            })
    }

    return ([object[]]$pairs.ToArray())
}

function Get-PairTopologyStrategy {
    param(
        [string]$PairDefinitionSource = '',
        [string]$PairDefinitionSourceDetail = ''
    )

    $source = [string]$PairDefinitionSource
    $sourceDetail = [string]$PairDefinitionSourceDetail
    if (Test-NonEmptyString $sourceDetail) {
        if ($sourceDetail -like 'fallback-*') {
            return $sourceDetail
        }
        if ($sourceDetail -like '*-pair-definitions' -or $sourceDetail -like '*-pairs') {
            return 'configured'
        }
    }

    if ($source -eq 'fallback') {
        return 'fallback'
    }
    if ($source -in @('config', 'manifest')) {
        return 'configured'
    }

    return 'unknown'
}

function Resolve-ConfiguredPairDefinitions {
    param(
        $Source = $null,
        [string]$SourceLabel = 'config'
    )

    $pairRowSet = Resolve-ConfiguredPairRowSet -Source $Source
    $pairRows = @($pairRowSet.Rows)
    $effectiveSource = $SourceLabel
    $effectiveSourceDetail = if (Test-NonEmptyString ([string]$pairRowSet.SourceDetail)) {
        ('{0}-{1}' -f $SourceLabel, [string]$pairRowSet.SourceDetail)
    }
    else {
        ''
    }
    if (@($pairRows).Count -eq 0) {
        $pairRows = @(Get-FallbackPairDefinitions -Source $Source)
        $effectiveSource = 'fallback'
        $effectiveSourceDetail = 'fallback-target-order'
    }

    $resolved = @()
    $seenPairIds = @{}
    $seenTargets = @{}
    foreach ($row in @($pairRows)) {
        $pairId = [string](Get-ConfigValue -Object $row -Name 'PairId' -DefaultValue '')
        $topTargetId = [string](Get-ConfigValue -Object $row -Name 'TopTargetId' -DefaultValue '')
        $bottomTargetId = [string](Get-ConfigValue -Object $row -Name 'BottomTargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $pairId)) {
            throw ('PairDefinitions({0}) row is missing PairId.' -f $effectiveSource)
        }
        if (-not (Test-NonEmptyString $topTargetId)) {
            throw ('PairDefinitions.{0}.TopTargetId is required.' -f $pairId)
        }
        if (-not (Test-NonEmptyString $bottomTargetId)) {
            throw ('PairDefinitions.{0}.BottomTargetId is required.' -f $pairId)
        }
        if ($topTargetId -eq $bottomTargetId) {
            throw ('PairDefinitions.{0} cannot reuse the same target for TopTargetId and BottomTargetId.' -f $pairId)
        }
        if ($seenPairIds.ContainsKey($pairId)) {
            throw ('PairDefinitions contains a duplicate PairId: {0}' -f $pairId)
        }
        $seenPairIds[$pairId] = $true
        foreach ($targetId in @($topTargetId, $bottomTargetId)) {
            $existingPairId = [string](Get-ConfigValue -Object $seenTargets -Name $targetId -DefaultValue '')
            if (Test-NonEmptyString $existingPairId) {
                throw ('target {0} is assigned to multiple pairs: {1}, {2}' -f $targetId, $existingPairId, $pairId)
            }
            $seenTargets[$targetId] = $pairId
        }

        $explicitSeedTargetId = [string](Get-ConfigValue -Object $row -Name 'SeedTargetId' -DefaultValue '')
        if ((Test-ConfigMemberExists -Object $row -Name 'SeedTargetId') -and (Test-NonEmptyString $explicitSeedTargetId) -and $explicitSeedTargetId -notin @($topTargetId, $bottomTargetId)) {
            throw ('PairDefinitions.{0}.SeedTargetId must match TopTargetId or BottomTargetId.' -f $pairId)
        }

        $seedTargetId = $explicitSeedTargetId
        if (-not (Test-NonEmptyString $seedTargetId)) {
            $seedTargetId = $topTargetId
        }
        $resolved += [pscustomobject]@{
            PairId = $pairId
            TopTargetId = $topTargetId
            BottomTargetId = $bottomTargetId
            SeedTargetId = $seedTargetId
            TargetIds = @($topTargetId, $bottomTargetId)
        }
    }

    return [pscustomobject]@{
        Source = $effectiveSource
        SourceDetail = [string]$effectiveSourceDetail
        Strategy = [string](Get-PairTopologyStrategy -PairDefinitionSource $effectiveSource -PairDefinitionSourceDetail $effectiveSourceDetail)
        Pairs = @($resolved)
    }
}

function Resolve-PairPolicyMap {
    param(
        $Source = $null,
        [Parameter(Mandatory)][object[]]$PairDefinitions,
        [Parameter(Mandatory)][string]$Root
    )

    $policyMap = @{}
    $pairPolicies = Get-ConfigValue -Object $Source -Name 'PairPolicies' -DefaultValue @{}
    $knownPairIds = @($PairDefinitions | ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'PairId' -DefaultValue '') } | Where-Object { Test-NonEmptyString $_ })
    foreach ($policyPairId in @(Get-ConfigMemberNames -Object $pairPolicies)) {
        if ([string]$policyPairId -notin $knownPairIds) {
            throw ('PairPolicies.{0} has no matching PairDefinitions entry.' -f [string]$policyPairId)
        }
    }

    Assert-ConfigNonNegativeInteger -Value (Get-ConfigValue -Object $Source -Name 'DefaultWatcherMaxForwardCount' -DefaultValue 0) -FieldName 'DefaultWatcherMaxForwardCount' -Context 'PairTest'
    Assert-ConfigNonNegativeInteger -Value (Get-ConfigValue -Object $Source -Name 'DefaultWatcherRunDurationSec' -DefaultValue 900) -FieldName 'DefaultWatcherRunDurationSec' -Context 'PairTest'
    Assert-ConfigNonNegativeInteger -Value (Get-ConfigValue -Object $Source -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0) -FieldName 'DefaultPairMaxRoundtripCount' -Context 'PairTest'
    $globalSeedWorkRepoRoot = [string](Get-ConfigValue -Object $Source -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')
    $globalSeedReviewInputPath = [string](Get-ConfigValue -Object $Source -Name 'DefaultSeedReviewInputPath' -DefaultValue '')
    $globalSeedReviewSearchRelativePath = [string](Get-ConfigValue -Object $Source -Name 'DefaultSeedReviewInputSearchRelativePath' -DefaultValue 'reviewfile')
    $globalSeedReviewFilter = [string](Get-ConfigValue -Object $Source -Name 'DefaultSeedReviewInputFilter' -DefaultValue '*.zip')
    $globalSeedReviewNameRegex = [string](Get-ConfigValue -Object $Source -Name 'DefaultSeedReviewInputNameRegex' -DefaultValue '')
    $globalSeedReviewMaxAgeHours = [double](Get-ConfigValue -Object $Source -Name 'DefaultSeedReviewInputMaxAgeHours' -DefaultValue 72)
    $globalSeedReviewRequireSingleCandidate = [bool](Get-ConfigValue -Object $Source -Name 'DefaultSeedReviewInputRequireSingleCandidate' -DefaultValue $false)
    $globalRequireExternalSeedWorkRepo = [bool](Get-ConfigValue -Object $Source -Name 'RequireExternalSeedWorkRepo' -DefaultValue $false)
    $globalUseExternalWorkRepoRunRoot = [bool](Get-ConfigValue -Object $Source -Name 'UseExternalWorkRepoRunRoot' -DefaultValue $false)
    $globalRequireExternalRunRoot = [bool](Get-ConfigValue -Object $Source -Name 'RequireExternalRunRoot' -DefaultValue $false)
    $globalExternalWorkRepoRunRootRelativeRoot = [string](Get-ConfigValue -Object $Source -Name 'ExternalWorkRepoRunRootRelativeRoot' -DefaultValue '.relay-runs\bottest-live-visible')
    $globalWatcherMaxForwardCount = [int](Get-ConfigValue -Object $Source -Name 'DefaultWatcherMaxForwardCount' -DefaultValue 0)
    $globalWatcherRunDurationSec = [int](Get-ConfigValue -Object $Source -Name 'DefaultWatcherRunDurationSec' -DefaultValue 900)
    $globalPairMaxRoundtripCount = [int](Get-ConfigValue -Object $Source -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0)
    $globalPublishContractMode = [string](Get-ConfigValue -Object $Source -Name 'DefaultPublishContractMode' -DefaultValue 'strict')
    $globalRecoveryPolicy = [string](Get-ConfigValue -Object $Source -Name 'DefaultRecoveryPolicy' -DefaultValue 'manual-review')
    $globalPauseAllowed = [bool](Get-ConfigValue -Object $Source -Name 'DefaultPauseAllowed' -DefaultValue $true)

    foreach ($pair in @($PairDefinitions)) {
        $pairId = [string](Get-ConfigValue -Object $pair -Name 'PairId' -DefaultValue '')
        if (-not (Test-NonEmptyString $pairId)) {
            continue
        }

        $pairSource = Get-ConfigValue -Object $pairPolicies -Name $pairId -DefaultValue $null
        $contextLabel = ('PairPolicies.{0}' -f $pairId)
        Assert-ConfigNonNegativeInteger -Value (Get-ConfigValue -Object $pairSource -Name 'DefaultWatcherMaxForwardCount' -DefaultValue $globalWatcherMaxForwardCount) -FieldName 'DefaultWatcherMaxForwardCount' -Context $contextLabel
        Assert-ConfigNonNegativeInteger -Value (Get-ConfigValue -Object $pairSource -Name 'DefaultWatcherRunDurationSec' -DefaultValue $globalWatcherRunDurationSec) -FieldName 'DefaultWatcherRunDurationSec' -Context $contextLabel
        Assert-ConfigNonNegativeInteger -Value (Get-ConfigValue -Object $pairSource -Name 'DefaultPairMaxRoundtripCount' -DefaultValue $globalPairMaxRoundtripCount) -FieldName 'DefaultPairMaxRoundtripCount' -Context $contextLabel
        $topTargetId = [string](Get-ConfigValue -Object $pair -Name 'TopTargetId' -DefaultValue '')
        $bottomTargetId = [string](Get-ConfigValue -Object $pair -Name 'BottomTargetId' -DefaultValue '')
        $seedTargetId = [string](Get-ConfigValue -Object $pairSource -Name 'DefaultSeedTargetId' -DefaultValue '')
        if ((Test-ConfigMemberExists -Object $pairSource -Name 'DefaultSeedTargetId') -and (Test-NonEmptyString $seedTargetId) -and $seedTargetId -notin @($topTargetId, $bottomTargetId)) {
            throw ('{0}.DefaultSeedTargetId must match TopTargetId or BottomTargetId.' -f $contextLabel)
        }
        if (-not (Test-NonEmptyString $seedTargetId)) {
            $seedTargetId = [string](Get-ConfigValue -Object $pair -Name 'SeedTargetId' -DefaultValue '')
        }
        if (-not (Test-NonEmptyString $seedTargetId)) {
            $seedTargetId = $topTargetId
        }

        $pairHasExplicitSeedWorkRepoRoot = Test-ConfigMemberExists -Object $pairSource -Name 'DefaultSeedWorkRepoRoot'
        $seedWorkRepoRootRaw = [string](Get-ConfigValue -Object $pairSource -Name 'DefaultSeedWorkRepoRoot' -DefaultValue $globalSeedWorkRepoRoot)
        $seedReviewInputPathRaw = [string](Get-ConfigValue -Object $pairSource -Name 'DefaultSeedReviewInputPath' -DefaultValue $globalSeedReviewInputPath)
        $policyMap[$pairId] = [pscustomobject]@{
            PairId = $pairId
            TopTargetId = $topTargetId
            BottomTargetId = $bottomTargetId
            DefaultSeedTargetId = $seedTargetId
            DefaultSeedWorkRepoRoot = if (Test-NonEmptyString $seedWorkRepoRootRaw) { Resolve-FullPathFromBase -PathValue $seedWorkRepoRootRaw -BasePath $Root } else { '' }
            DefaultSeedWorkRepoRootSource = if ($pairHasExplicitSeedWorkRepoRoot) { 'pair-policy' } elseif (Test-NonEmptyString $seedWorkRepoRootRaw) { 'global-default' } else { 'unset' }
            DefaultSeedWorkRepoRootInherited = [bool]((-not $pairHasExplicitSeedWorkRepoRoot) -and (Test-NonEmptyString $seedWorkRepoRootRaw))
            DefaultSeedReviewInputPath = if (Test-NonEmptyString $seedReviewInputPathRaw) { Resolve-FullPathFromBase -PathValue $seedReviewInputPathRaw -BasePath $Root } else { '' }
            DefaultSeedReviewInputSearchRelativePath = [string](Get-ConfigValue -Object $pairSource -Name 'DefaultSeedReviewInputSearchRelativePath' -DefaultValue $globalSeedReviewSearchRelativePath)
            DefaultSeedReviewInputFilter = [string](Get-ConfigValue -Object $pairSource -Name 'DefaultSeedReviewInputFilter' -DefaultValue $globalSeedReviewFilter)
            DefaultSeedReviewInputNameRegex = [string](Get-ConfigValue -Object $pairSource -Name 'DefaultSeedReviewInputNameRegex' -DefaultValue $globalSeedReviewNameRegex)
            DefaultSeedReviewInputMaxAgeHours = [double](Get-ConfigValue -Object $pairSource -Name 'DefaultSeedReviewInputMaxAgeHours' -DefaultValue $globalSeedReviewMaxAgeHours)
            DefaultSeedReviewInputRequireSingleCandidate = [bool](Get-ConfigValue -Object $pairSource -Name 'DefaultSeedReviewInputRequireSingleCandidate' -DefaultValue $globalSeedReviewRequireSingleCandidate)
            RequireExternalSeedWorkRepo = [bool](Get-ConfigValue -Object $pairSource -Name 'RequireExternalSeedWorkRepo' -DefaultValue $globalRequireExternalSeedWorkRepo)
            UseExternalWorkRepoRunRoot = [bool](Get-ConfigValue -Object $pairSource -Name 'UseExternalWorkRepoRunRoot' -DefaultValue $globalUseExternalWorkRepoRunRoot)
            RequireExternalRunRoot = [bool](Get-ConfigValue -Object $pairSource -Name 'RequireExternalRunRoot' -DefaultValue $globalRequireExternalRunRoot)
            ExternalWorkRepoRunRootRelativeRoot = [string](Get-ConfigValue -Object $pairSource -Name 'ExternalWorkRepoRunRootRelativeRoot' -DefaultValue $globalExternalWorkRepoRunRootRelativeRoot)
            UseExternalWorkRepoContractPaths = [bool](Get-ConfigValue -Object $pairSource -Name 'UseExternalWorkRepoContractPaths' -DefaultValue ([bool](Get-ConfigValue -Object $Source -Name 'UseExternalWorkRepoContractPaths' -DefaultValue $false)))
            ExternalWorkRepoContractRelativeRoot = [string](Get-ConfigValue -Object $pairSource -Name 'ExternalWorkRepoContractRelativeRoot' -DefaultValue ([string](Get-ConfigValue -Object $Source -Name 'ExternalWorkRepoContractRelativeRoot' -DefaultValue '.relay-contract\bottest-live-visible')))
            DefaultWatcherMaxForwardCount = [int](Get-ConfigValue -Object $pairSource -Name 'DefaultWatcherMaxForwardCount' -DefaultValue $globalWatcherMaxForwardCount)
            DefaultWatcherRunDurationSec = [int](Get-ConfigValue -Object $pairSource -Name 'DefaultWatcherRunDurationSec' -DefaultValue $globalWatcherRunDurationSec)
            DefaultPairMaxRoundtripCount = [int](Get-ConfigValue -Object $pairSource -Name 'DefaultPairMaxRoundtripCount' -DefaultValue $globalPairMaxRoundtripCount)
            PublishContractMode = [string](Get-ConfigValue -Object $pairSource -Name 'PublishContractMode' -DefaultValue $globalPublishContractMode)
            RecoveryPolicy = [string](Get-ConfigValue -Object $pairSource -Name 'RecoveryPolicy' -DefaultValue $globalRecoveryPolicy)
            PauseAllowed = [bool](Get-ConfigValue -Object $pairSource -Name 'PauseAllowed' -DefaultValue $globalPauseAllowed)
        }
    }

    return $policyMap
}

function Select-PairDefinitions {
    param(
        [Parameter(Mandatory)][object[]]$PairDefinitions,
        [string[]]$IncludePairId = @(),
        [string]$TargetId = ''
    )

    $selectedPairs = @($PairDefinitions)
    $requestedPairIds = @($IncludePairId | Where-Object { Test-NonEmptyString $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if ($requestedPairIds.Count -gt 0) {
        $selectedPairs = @($selectedPairs | Where-Object { [string]$_.PairId -in $requestedPairIds })
        $selectedPairIds = @($selectedPairs | ForEach-Object { [string]$_.PairId })
        $missingPairIds = @($requestedPairIds | Where-Object { $_ -notin $selectedPairIds })
        if ($missingPairIds.Count -gt 0) {
            throw ("unknown pair id(s): " + ($missingPairIds -join ', '))
        }
    }

    if (Test-NonEmptyString $TargetId) {
        $selectedPairs = @($selectedPairs | Where-Object {
                ([string]$_.TopTargetId -eq $TargetId) -or ([string]$_.BottomTargetId -eq $TargetId)
            })
    }

    return @($selectedPairs)
}

function Get-DefaultPairId {
    param([Parameter(Mandatory)]$PairTest)

    $configuredDefaultPairId = [string](Get-ConfigValue -Object $PairTest -Name 'DefaultPairId' -DefaultValue '')
    if (Test-NonEmptyString $configuredDefaultPairId) {
        return $configuredDefaultPairId
    }

    $firstPair = @(@($PairTest.PairDefinitions) | Select-Object -First 1)
    if (@($firstPair).Count -eq 0) {
        throw 'pair definitions are empty.'
    }

    $pairId = [string](Get-ConfigValue -Object $firstPair[0] -Name 'PairId' -DefaultValue '')
    if (-not (Test-NonEmptyString $pairId)) {
        throw 'first pair definition is missing PairId.'
    }

    return $pairId
}

function Get-PairDefinitionById {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$PairId
    )

    $pair = @(
        @($PairTest.PairDefinitions) | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'PairId' -DefaultValue '') -eq $PairId } | Select-Object -First 1
    )
    if (@($pair).Count -eq 0) {
        throw "알 수 없는 pair id입니다: $PairId"
    }

    return $pair[0]
}

function Get-PairDefinition {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$PairId
    )

    return (Get-PairDefinitionById -PairTest $PairTest -PairId $PairId)
}

function Resolve-PairTargetSelection {
    param(
        [Parameter(Mandatory)]$PairTest,
        [string]$PairId = '',
        [string]$TargetId = ''
    )

    $resolvedTargetId = [string]$TargetId
    $resolvedPairId = [string]$PairId

    if (-not (Test-NonEmptyString $resolvedPairId)) {
        if (Test-NonEmptyString $resolvedTargetId) {
            $matchingPairs = @(
                Select-PairDefinitions -PairDefinitions @($PairTest.PairDefinitions) -TargetId $resolvedTargetId
            )
            if (@($matchingPairs).Count -eq 0) {
                throw ("알 수 없는 target id입니다: " + $resolvedTargetId)
            }
            if (@($matchingPairs).Count -gt 1) {
                throw ("target id가 여러 pair에 매핑됩니다: " + $resolvedTargetId)
            }
            $resolvedPairId = [string](Get-ConfigValue -Object $matchingPairs[0] -Name 'PairId' -DefaultValue '')
        }
        else {
            $resolvedPairId = Get-DefaultPairId -PairTest $PairTest
        }
    }

    $pairDefinition = Get-PairDefinition -PairTest $PairTest -PairId $resolvedPairId
    $topTargetId = [string](Get-ConfigValue -Object $pairDefinition -Name 'TopTargetId' -DefaultValue '')
    $bottomTargetId = [string](Get-ConfigValue -Object $pairDefinition -Name 'BottomTargetId' -DefaultValue '')
    if (-not (Test-NonEmptyString $resolvedTargetId)) {
        $resolvedTargetId = [string](Get-ConfigValue -Object $pairDefinition -Name 'SeedTargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $resolvedTargetId)) {
            $resolvedTargetId = $topTargetId
        }
    }

    if ($resolvedTargetId -notin @($topTargetId, $bottomTargetId)) {
        throw "target id does not belong to pair: target=$resolvedTargetId pair=$resolvedPairId"
    }

    $partnerTargetId = if ($resolvedTargetId -eq $topTargetId) {
        $bottomTargetId
    }
    else {
        $topTargetId
    }

    return [pscustomobject]@{
        PairId = [string]$resolvedPairId
        TargetId = [string]$resolvedTargetId
        PartnerTargetId = [string]$partnerTargetId
        PairDefinition = $pairDefinition
    }
}

function Get-PairPolicyForPair {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$PairId
    )

    $policy = Get-ConfigValue -Object $PairTest.PairPolicies -Name $PairId -DefaultValue $null
    if ($null -ne $policy) {
        return $policy
    }

    $pair = Get-PairDefinitionById -PairTest $PairTest -PairId $PairId
    return [pscustomobject]@{
        PairId = $PairId
        TopTargetId = [string](Get-ConfigValue -Object $pair -Name 'TopTargetId' -DefaultValue '')
        BottomTargetId = [string](Get-ConfigValue -Object $pair -Name 'BottomTargetId' -DefaultValue '')
        DefaultSeedTargetId = [string](Get-ConfigValue -Object $pair -Name 'SeedTargetId' -DefaultValue '')
        DefaultSeedWorkRepoRoot = [string](Get-ConfigValue -Object $PairTest -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')
        DefaultSeedWorkRepoRootSource = if (Test-NonEmptyString ([string](Get-ConfigValue -Object $PairTest -Name 'DefaultSeedWorkRepoRoot' -DefaultValue ''))) { 'global-default' } else { 'unset' }
        DefaultSeedWorkRepoRootInherited = [bool](Test-NonEmptyString ([string](Get-ConfigValue -Object $PairTest -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')))
        DefaultSeedReviewInputPath = [string](Get-ConfigValue -Object $PairTest -Name 'DefaultSeedReviewInputPath' -DefaultValue '')
        DefaultSeedReviewInputSearchRelativePath = [string](Get-ConfigValue -Object $PairTest -Name 'DefaultSeedReviewInputSearchRelativePath' -DefaultValue 'reviewfile')
        DefaultSeedReviewInputFilter = [string](Get-ConfigValue -Object $PairTest -Name 'DefaultSeedReviewInputFilter' -DefaultValue '*.zip')
        DefaultSeedReviewInputNameRegex = [string](Get-ConfigValue -Object $PairTest -Name 'DefaultSeedReviewInputNameRegex' -DefaultValue '')
        DefaultSeedReviewInputMaxAgeHours = [double](Get-ConfigValue -Object $PairTest -Name 'DefaultSeedReviewInputMaxAgeHours' -DefaultValue 72)
        DefaultSeedReviewInputRequireSingleCandidate = [bool](Get-ConfigValue -Object $PairTest -Name 'DefaultSeedReviewInputRequireSingleCandidate' -DefaultValue $false)
        DefaultWatcherMaxForwardCount = [int](Get-ConfigValue -Object $PairTest -Name 'DefaultWatcherMaxForwardCount' -DefaultValue 0)
        DefaultWatcherRunDurationSec = [int](Get-ConfigValue -Object $PairTest -Name 'DefaultWatcherRunDurationSec' -DefaultValue 900)
        DefaultPairMaxRoundtripCount = [int](Get-ConfigValue -Object $PairTest -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0)
        UseExternalWorkRepoRunRoot = [bool](Get-ConfigValue -Object $PairTest -Name 'UseExternalWorkRepoRunRoot' -DefaultValue $false)
        RequireExternalRunRoot = [bool](Get-ConfigValue -Object $PairTest -Name 'RequireExternalRunRoot' -DefaultValue $false)
        ExternalWorkRepoRunRootRelativeRoot = [string](Get-ConfigValue -Object $PairTest -Name 'ExternalWorkRepoRunRootRelativeRoot' -DefaultValue '.relay-runs\bottest-live-visible')
        PublishContractMode = [string](Get-ConfigValue -Object $PairTest -Name 'DefaultPublishContractMode' -DefaultValue 'strict')
        RecoveryPolicy = [string](Get-ConfigValue -Object $PairTest -Name 'DefaultRecoveryPolicy' -DefaultValue 'manual-review')
        PauseAllowed = [bool](Get-ConfigValue -Object $PairTest -Name 'DefaultPauseAllowed' -DefaultValue $true)
    }
}

function Resolve-PairRunRootPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$RunRoot,
        [Parameter(Mandatory)]$PairTest,
        $PairPolicy = $null,
        [string]$WorkRepoRoot = ''
    )

    if (Test-NonEmptyString $RunRoot) {
        return (Resolve-FullPathFromBase -PathValue $RunRoot -BasePath $Root)
    }

    $useExternalRunRoot = Test-UseExternalWorkRepoRunRoot -PairTest $PairTest -PairPolicy $PairPolicy -WorkRepoRoot $WorkRepoRoot
    if ($useExternalRunRoot) {
        if (-not (Test-NonEmptyString $WorkRepoRoot)) {
            throw 'external run root requires a non-empty WorkRepoRoot.'
        }

        $baseRoot = Resolve-ExternalWorkRepoRunRootBase -PairTest $PairTest -PairPolicy $PairPolicy -WorkRepoRoot $WorkRepoRoot
    }
    else {
        $baseRoot = Resolve-FullPathFromBase `
            -PathValue ([string](Get-ConfigValue -Object $PairTest -Name 'RunRootBase' -DefaultValue (Join-Path $Root 'pair-test'))) `
            -BasePath $Root
    }
    $pattern = [string](Get-ConfigValue -Object $PairTest -Name 'RunRootPattern' -DefaultValue 'run_{yyyyMMdd_HHmmss}')
    return [System.IO.Path]::GetFullPath((Join-Path $baseRoot (Expand-RunRootPattern -Pattern $pattern)))
}

function Resolve-PairTestConfig {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ConfigPath,
        $ManifestPairTest = $null
    )

    $config = $null
    $configPairTest = @{}
    if ($null -eq $ManifestPairTest -and (Test-NonEmptyString $ConfigPath)) {
        $config = Import-PowerShellDataFile -Path $ConfigPath
        $configPairTest = Get-ConfigValue -Object $config -Name 'PairTest' -DefaultValue @{}
    }

    $source = if ($null -ne $ManifestPairTest) { $ManifestPairTest } else { $configPairTest }
    $messageTemplates = Get-ConfigValue -Object $source -Name 'MessageTemplates' -DefaultValue @{}
    $headlessExec = Get-ConfigValue -Object $source -Name 'HeadlessExec' -DefaultValue @{}
    $visibleWorker = Get-ConfigValue -Object $source -Name 'VisibleWorker' -DefaultValue @{}
    $typedWindow = Get-ConfigValue -Object $source -Name 'TypedWindow' -DefaultValue @{}
    $visibleWorkerEnabled = [bool](Get-ConfigValue -Object $visibleWorker -Name 'Enabled' -DefaultValue $false)
    $executionPathMode = [string](Get-ConfigValue -Object $source -Name 'ExecutionPathMode' -DefaultValue $(if ($visibleWorkerEnabled) { 'visible-worker' } else { 'typed-window' }))
    $requireUserVisibleCellExecution = [bool](Get-ConfigValue -Object $source -Name 'RequireUserVisibleCellExecution' -DefaultValue $false)
    if ($executionPathMode -notin @('visible-worker', 'typed-window')) {
        throw ("PairTest.ExecutionPathMode must be 'visible-worker' or 'typed-window'. actual={0}" -f $executionPathMode)
    }
    if ($executionPathMode -eq 'visible-worker' -and -not $visibleWorkerEnabled) {
        throw 'PairTest.ExecutionPathMode is visible-worker but PairTest.VisibleWorker.Enabled is false.'
    }
    if ($requireUserVisibleCellExecution -and $executionPathMode -ne 'typed-window') {
        throw 'PairTest.RequireUserVisibleCellExecution requires ExecutionPathMode=typed-window.'
    }
    $initialTemplate = Get-ConfigValue -Object $messageTemplates -Name 'Initial' -DefaultValue @{}
    $handoffTemplate = Get-ConfigValue -Object $messageTemplates -Name 'Handoff' -DefaultValue @{}
    $runRootBase = Resolve-FullPathFromBase `
        -PathValue ([string](Get-ConfigValue -Object $source -Name 'RunRootBase' -DefaultValue (Join-Path $Root 'pair-test'))) `
        -BasePath $Root
    $defaultVisibleWorkerRoot = Join-Path $Root 'runtime\visible-workers'
    $pairDefinitionResolveSource = if ($null -ne $ManifestPairTest) { $ManifestPairTest } elseif ($null -ne $config) { $config } else { $source }
    $pairDefinitionSet = Resolve-ConfiguredPairDefinitions -Source $pairDefinitionResolveSource -SourceLabel $(if ($null -ne $ManifestPairTest) { 'manifest' } else { 'config' })
    $pairPolicies = Resolve-PairPolicyMap -Source $source -PairDefinitions @($pairDefinitionSet.Pairs) -Root $Root
    $forbiddenArtifactPolicy = Get-ForbiddenArtifactPolicy -Source $source
    $configuredDefaultPairId = [string](Get-ConfigValue -Object $source -Name 'DefaultPairId' -DefaultValue '')
    if (Test-NonEmptyString $configuredDefaultPairId) {
        $defaultPairExists = @(
            @($pairDefinitionSet.Pairs) |
                Where-Object { [string](Get-ConfigValue -Object $_ -Name 'PairId' -DefaultValue '') -eq $configuredDefaultPairId } |
                Select-Object -First 1
        )
        if (@($defaultPairExists).Count -eq 0) {
            throw ('PairTest.DefaultPairId has no matching PairDefinitions entry: {0}' -f $configuredDefaultPairId)
        }
    }
    $defaultPairId = if (Test-NonEmptyString $configuredDefaultPairId) {
        $configuredDefaultPairId
    }
    elseif (@($pairDefinitionSet.Pairs).Count -gt 0) {
        $firstPair = @($pairDefinitionSet.Pairs | Select-Object -First 1)
        [string](Get-ConfigValue -Object $firstPair[0] -Name 'PairId' -DefaultValue '')
    }
    else {
        ''
    }
    $visibleWorkerCommandTimeoutSeconds = [int](Get-ConfigValue -Object $visibleWorker -Name 'CommandTimeoutSeconds' -DefaultValue ([math]::Max(60, ([int](Get-ConfigValue -Object $headlessExec -Name 'MaxRunSeconds' -DefaultValue 900) + 60))))

    return [pscustomobject]@{
        RunRootBase       = $runRootBase
        RunRootPattern    = [string](Get-ConfigValue -Object $source -Name 'RunRootPattern' -DefaultValue 'run_{yyyyMMdd_HHmmss}')
        ExecutionPathMode = $executionPathMode
        RequireUserVisibleCellExecution = $requireUserVisibleCellExecution
        AllowedWindowVisibilityMethods = @(
            Get-StringArray (Get-ConfigValue -Object $source -Name 'AllowedWindowVisibilityMethods' -DefaultValue @('hwnd'))
        )
        AcceptanceProfile = [string](Get-ConfigValue -Object $source -Name 'AcceptanceProfile' -DefaultValue 'project-review')
        SmokeSeedTaskText = [string](Get-ConfigValue -Object $source -Name 'SmokeSeedTaskText' -DefaultValue '')
        SummaryFileName   = [string](Get-ConfigValue -Object $source -Name 'SummaryFileName' -DefaultValue 'summary.txt')
        ReviewFolderName  = [string](Get-ConfigValue -Object $source -Name 'ReviewFolderName' -DefaultValue 'reviewfile')
        WorkFolderName    = [string](Get-ConfigValue -Object $source -Name 'WorkFolderName' -DefaultValue 'work')
        MessageFolderName = [string](Get-ConfigValue -Object $source -Name 'MessageFolderName' -DefaultValue 'messages')
        ReviewZipPattern  = [string](Get-ConfigValue -Object $source -Name 'ReviewZipPattern' -DefaultValue 'review_{TargetId}_{yyyyMMdd_HHmmss}_{Guid}.zip')
        CheckScriptFileName = [string](Get-ConfigValue -Object $source -Name 'CheckScriptFileName' -DefaultValue 'check-artifact.ps1')
        SubmitScriptFileName = [string](Get-ConfigValue -Object $source -Name 'SubmitScriptFileName' -DefaultValue 'submit-artifact.ps1')
        PublishScriptFileName = [string](Get-ConfigValue -Object $source -Name 'PublishScriptFileName' -DefaultValue 'publish-artifact.ps1')
        CheckCmdFileName  = [string](Get-ConfigValue -Object $source -Name 'CheckCmdFileName' -DefaultValue 'check-artifact.cmd')
        SubmitCmdFileName = [string](Get-ConfigValue -Object $source -Name 'SubmitCmdFileName' -DefaultValue 'submit-artifact.cmd')
        PublishCmdFileName = [string](Get-ConfigValue -Object $source -Name 'PublishCmdFileName' -DefaultValue 'publish-artifact.cmd')
        SourceOutboxFolderName = [string](Get-ConfigValue -Object $source -Name 'SourceOutboxFolderName' -DefaultValue 'source-outbox')
        SourceSummaryFileName = [string](Get-ConfigValue -Object $source -Name 'SourceSummaryFileName' -DefaultValue 'summary.txt')
        SourceReviewZipFileName = [string](Get-ConfigValue -Object $source -Name 'SourceReviewZipFileName' -DefaultValue 'review.zip')
        PublishReadyFileName = [string](Get-ConfigValue -Object $source -Name 'PublishReadyFileName' -DefaultValue 'publish.ready.json')
        PublishedArchiveFolderName = [string](Get-ConfigValue -Object $source -Name 'PublishedArchiveFolderName' -DefaultValue '.published')
        RequireExternalSeedWorkRepo = [bool](Get-ConfigValue -Object $source -Name 'RequireExternalSeedWorkRepo' -DefaultValue $false)
        DefaultSeedWorkRepoRoot = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')
        DefaultSeedReviewInputPath = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputPath' -DefaultValue '')
        DefaultSeedReviewInputSearchRelativePath = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputSearchRelativePath' -DefaultValue 'reviewfile')
        DefaultSeedReviewInputFilter = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputFilter' -DefaultValue '*.zip')
        DefaultSeedReviewInputNameRegex = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputNameRegex' -DefaultValue '')
        DefaultSeedReviewInputMaxAgeHours = [double](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputMaxAgeHours' -DefaultValue 72)
        DefaultSeedReviewInputRequireSingleCandidate = [bool](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputRequireSingleCandidate' -DefaultValue $false)
        UseExternalWorkRepoRunRoot = [bool](Get-ConfigValue -Object $source -Name 'UseExternalWorkRepoRunRoot' -DefaultValue $false)
        RequireExternalRunRoot = [bool](Get-ConfigValue -Object $source -Name 'RequireExternalRunRoot' -DefaultValue $false)
        ExternalWorkRepoRunRootRelativeRoot = [string](Get-ConfigValue -Object $source -Name 'ExternalWorkRepoRunRootRelativeRoot' -DefaultValue '.relay-runs\bottest-live-visible')
        DefaultWatcherMaxForwardCount = [int](Get-ConfigValue -Object $source -Name 'DefaultWatcherMaxForwardCount' -DefaultValue 0)
        DefaultWatcherRunDurationSec = [int](Get-ConfigValue -Object $source -Name 'DefaultWatcherRunDurationSec' -DefaultValue 900)
        DefaultPairMaxRoundtripCount = [int](Get-ConfigValue -Object $source -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0)
        UseExternalWorkRepoContractPaths = [bool](Get-ConfigValue -Object $source -Name 'UseExternalWorkRepoContractPaths' -DefaultValue $false)
        ExternalWorkRepoContractRelativeRoot = [string](Get-ConfigValue -Object $source -Name 'ExternalWorkRepoContractRelativeRoot' -DefaultValue '.relay-contract\bottest-live-visible')
        DefaultPublishContractMode = [string](Get-ConfigValue -Object $source -Name 'DefaultPublishContractMode' -DefaultValue 'strict')
        DefaultRecoveryPolicy = [string](Get-ConfigValue -Object $source -Name 'DefaultRecoveryPolicy' -DefaultValue 'manual-review')
        DefaultPauseAllowed = [bool](Get-ConfigValue -Object $source -Name 'DefaultPauseAllowed' -DefaultValue $true)
        ForbiddenArtifactLiterals = @($forbiddenArtifactPolicy.Literals)
        ForbiddenArtifactRegexes = @($forbiddenArtifactPolicy.Regexes)
        SeedOutboxStartTimeoutSeconds = [int](Get-ConfigValue -Object $source -Name 'SeedOutboxStartTimeoutSeconds' -DefaultValue 120)
        SeedWaitForUserIdleTimeoutSeconds = [int](Get-ConfigValue -Object $source -Name 'SeedWaitForUserIdleTimeoutSeconds' -DefaultValue 180)
        SeedRetryMaxAttempts = [int](Get-ConfigValue -Object $source -Name 'SeedRetryMaxAttempts' -DefaultValue 3)
        SeedRetryBackoffMs   = @(
            Get-StringArray (Get-ConfigValue -Object $source -Name 'SeedRetryBackoffMs' -DefaultValue @('15000', '45000', '120000')) |
                ForEach-Object { [int]$_ }
        )
        SummaryZipMaxSkewSeconds = [double](Get-ConfigValue -Object $source -Name 'SummaryZipMaxSkewSeconds' -DefaultValue 2)
        HeadlessExec      = [pscustomobject]@{
            Enabled                   = [bool](Get-ConfigValue -Object $headlessExec -Name 'Enabled' -DefaultValue $false)
            CodexExecutable           = [string](Get-ConfigValue -Object $headlessExec -Name 'CodexExecutable' -DefaultValue 'codex')
            Arguments                 = @(Get-StringArray (Get-ConfigValue -Object $headlessExec -Name 'Arguments' -DefaultValue @(
                'exec',
                '--skip-git-repo-check',
                '--dangerously-bypass-approvals-and-sandbox'
            )))
            RequestFileName           = [string](Get-ConfigValue -Object $headlessExec -Name 'RequestFileName' -DefaultValue 'request.json')
            DoneFileName              = [string](Get-ConfigValue -Object $headlessExec -Name 'DoneFileName' -DefaultValue 'done.json')
            ErrorFileName             = [string](Get-ConfigValue -Object $headlessExec -Name 'ErrorFileName' -DefaultValue 'error.json')
            ResultFileName            = [string](Get-ConfigValue -Object $headlessExec -Name 'ResultFileName' -DefaultValue 'result.json')
            OutputLastMessageFileName = [string](Get-ConfigValue -Object $headlessExec -Name 'OutputLastMessageFileName' -DefaultValue 'codex-last-message.txt')
            PromptFileName            = [string](Get-ConfigValue -Object $headlessExec -Name 'PromptFileName' -DefaultValue 'headless-prompt.txt')
            MaxRunSeconds             = [int](Get-ConfigValue -Object $headlessExec -Name 'MaxRunSeconds' -DefaultValue 900)
            MutexScope                = [string](Get-ConfigValue -Object $headlessExec -Name 'MutexScope' -DefaultValue 'pair')
        }
        VisibleWorker    = [pscustomobject]@{
            Enabled          = $visibleWorkerEnabled
            QueueRoot        = Resolve-FullPathFromBase `
                -PathValue ([string](Get-ConfigValue -Object $visibleWorker -Name 'QueueRoot' -DefaultValue (Join-Path $defaultVisibleWorkerRoot 'queue'))) `
                -BasePath $Root
            StatusRoot       = Resolve-FullPathFromBase `
                -PathValue ([string](Get-ConfigValue -Object $visibleWorker -Name 'StatusRoot' -DefaultValue (Join-Path $defaultVisibleWorkerRoot 'status'))) `
                -BasePath $Root
            LogRoot          = Resolve-FullPathFromBase `
                -PathValue ([string](Get-ConfigValue -Object $visibleWorker -Name 'LogRoot' -DefaultValue (Join-Path $defaultVisibleWorkerRoot 'logs'))) `
                -BasePath $Root
            PollIntervalMs   = [int](Get-ConfigValue -Object $visibleWorker -Name 'PollIntervalMs' -DefaultValue 500)
            IdleExitSeconds  = [int](Get-ConfigValue -Object $visibleWorker -Name 'IdleExitSeconds' -DefaultValue 60)
            CommandTimeoutSeconds = $visibleWorkerCommandTimeoutSeconds
            DispatchTimeoutSeconds = [int](Get-ConfigValue -Object $visibleWorker -Name 'DispatchTimeoutSeconds' -DefaultValue $visibleWorkerCommandTimeoutSeconds)
            PreflightTimeoutSeconds = [int](Get-ConfigValue -Object $visibleWorker -Name 'PreflightTimeoutSeconds' -DefaultValue 180)
            WorkerReadyFreshnessSeconds = [int](Get-ConfigValue -Object $visibleWorker -Name 'WorkerReadyFreshnessSeconds' -DefaultValue 30)
            DispatchAcceptedStaleSeconds = [int](Get-ConfigValue -Object $visibleWorker -Name 'DispatchAcceptedStaleSeconds' -DefaultValue 15)
            DispatchRunningStaleSeconds = [int](Get-ConfigValue -Object $visibleWorker -Name 'DispatchRunningStaleSeconds' -DefaultValue 30)
            AcceptanceSeedSoftTimeoutSeconds = [int](Get-ConfigValue -Object $visibleWorker -Name 'AcceptanceSeedSoftTimeoutSeconds' -DefaultValue 120)
        }
        TypedWindow = [pscustomobject]@{
            SubmitProbeSeconds = [int](Get-ConfigValue -Object $typedWindow -Name 'SubmitProbeSeconds' -DefaultValue 10)
            SubmitProbePollMs = [int](Get-ConfigValue -Object $typedWindow -Name 'SubmitProbePollMs' -DefaultValue 1000)
            SubmitRetryLimit = [int](Get-ConfigValue -Object $typedWindow -Name 'SubmitRetryLimit' -DefaultValue 1)
            ProgressCpuDeltaThresholdSeconds = [double](Get-ConfigValue -Object $typedWindow -Name 'ProgressCpuDeltaThresholdSeconds' -DefaultValue 0.05)
        }
        MessageTemplates  = [pscustomobject]@{
            Initial = [pscustomobject]@{
                SlotOrder = @(Get-StringArray (Get-ConfigValue -Object $initialTemplate -Name 'SlotOrder' -DefaultValue (Get-DefaultMessageSlotOrder -TemplateName 'Initial')))
                PrefixBlocks = @(Get-StringArray (Get-ConfigValue -Object $initialTemplate -Name 'PrefixBlocks' -DefaultValue @(
                    '당신은 paired exchange 테스트용 창입니다.',
                    '아래 규칙과 폴더/파일 계약을 기준으로 작업하세요.'
                )))
                SuffixBlocks = @(Get-StringArray (Get-ConfigValue -Object $initialTemplate -Name 'SuffixBlocks' -DefaultValue @(
                    '이번 턴 완료 조건: summary 파일 갱신 + review zip 1개 이상 생성',
                    '상대에게 직접 경로를 다시 타이핑하지 말고, 전달된 partner folder를 기준으로 이어서 작업하세요.',
                    '추가 검토 메모가 필요하면 내 폴더(target folder)에 매번 새 이름의 txt 파일을 만들고, 그 txt를 새 review zip에 포함하세요. 자동 전달되는 새 파일명은 내 폴더 reviewfile의 새 review zip 이름입니다. summary.txt는 같은 이름으로 갱신합니다.'
                )))
            }
            Handoff = [pscustomobject]@{
                SlotOrder = @(Get-StringArray (Get-ConfigValue -Object $handoffTemplate -Name 'SlotOrder' -DefaultValue (Get-DefaultMessageSlotOrder -TemplateName 'Handoff')))
                PrefixBlocks = @(Get-StringArray (Get-ConfigValue -Object $handoffTemplate -Name 'PrefixBlocks' -DefaultValue @(
                    '상대 창에서 새 결과물이 생성되었습니다.',
                    '아래 폴더와 파일을 확인하고 다음 작업을 이어가세요.'
                )))
                SuffixBlocks = @(Get-StringArray (Get-ConfigValue -Object $handoffTemplate -Name 'SuffixBlocks' -DefaultValue @(
                    '최종 결과는 내 SourceOutboxPath 아래의 summary.txt 와 review.zip 으로만 정리하고, 마지막에 publish.ready.json 을 생성하세요.',
                    '직접 target contract 경로에 복사하거나 별도 submit 명령을 다시 실행하지 마세요.'
                )))
            }
        }
        PairOverrides     = Get-ConfigValue -Object $source -Name 'PairOverrides' -DefaultValue @{}
        RoleOverrides     = Get-ConfigValue -Object $source -Name 'RoleOverrides' -DefaultValue @{}
        TargetOverrides   = Get-ConfigValue -Object $source -Name 'TargetOverrides' -DefaultValue @{}
        DefaultPairId     = [string]$defaultPairId
        PairDefinitions   = @($pairDefinitionSet.Pairs)
        PairDefinitionSource = [string]$pairDefinitionSet.Source
        PairDefinitionSourceDetail = [string]$pairDefinitionSet.SourceDetail
        PairTopologyStrategy = [string]$pairDefinitionSet.Strategy
        PairPolicies      = $pairPolicies
    }
}

function Get-PairTemplateBlocks {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TemplateName,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$TargetId
    )

    $messageTemplates = Get-ConfigValue -Object $PairTest -Name 'MessageTemplates' -DefaultValue @{}
    $template = Get-ConfigValue -Object $messageTemplates -Name $TemplateName -DefaultValue @{}
    $prefixBlocks = @(Get-StringArray (Get-ConfigValue -Object $template -Name 'PrefixBlocks' -DefaultValue @()))
    $suffixBlocks = @(Get-StringArray (Get-ConfigValue -Object $template -Name 'SuffixBlocks' -DefaultValue @()))
    $extraPropertyName = ($TemplateName + 'ExtraBlocks')
    $pairOverrides = Get-ConfigValue -Object $PairTest -Name 'PairOverrides' -DefaultValue @{}
    $roleOverrides = Get-ConfigValue -Object $PairTest -Name 'RoleOverrides' -DefaultValue @{}
    $targetOverrides = Get-ConfigValue -Object $PairTest -Name 'TargetOverrides' -DefaultValue @{}
    $overrideSources = @(
        (Get-ConfigValue -Object $pairOverrides -Name $PairId -DefaultValue $null),
        (Get-ConfigValue -Object $roleOverrides -Name $RoleName -DefaultValue $null),
        (Get-ConfigValue -Object $targetOverrides -Name $TargetId -DefaultValue $null)
    )
    $pairSource = $overrideSources[0]
    $roleSource = $overrideSources[1]
    $targetSource = $overrideSources[2]
    $pairBlocks = @(Get-StringArray (Get-ConfigValue -Object $pairSource -Name $extraPropertyName -DefaultValue @()))
    $roleBlocks = @(Get-StringArray (Get-ConfigValue -Object $roleSource -Name $extraPropertyName -DefaultValue @()))
    $targetBlocks = @(Get-StringArray (Get-ConfigValue -Object $targetSource -Name $extraPropertyName -DefaultValue @()))

    $extraBlocks = New-Object System.Collections.Generic.List[string]
    $acceptanceProfile = [string](Get-ConfigValue -Object $PairTest -Name 'AcceptanceProfile' -DefaultValue 'project-review')
    if ($acceptanceProfile -ne 'smoke') {
        foreach ($overrideSource in $overrideSources) {
            foreach ($block in @(Get-StringArray (Get-ConfigValue -Object $overrideSource -Name $extraPropertyName -DefaultValue @()))) {
                $extraBlocks.Add([string]$block)
            }
        }
    }

    return [pscustomobject]@{
        SlotOrder = @(Get-StringArray (Get-ConfigValue -Object $template -Name 'SlotOrder' -DefaultValue (Get-DefaultMessageSlotOrder -TemplateName $TemplateName)))
        PrefixBlocks = @($prefixBlocks)
        ExtraBlocks  = @($extraBlocks)
        SuffixBlocks = @($suffixBlocks)
        Sources = [pscustomobject]@{
            Pair = @($pairBlocks)
            Role = @($roleBlocks)
            Target = @($targetBlocks)
        }
    }
}

function Join-MessageBlocks {
    param([Parameter(Mandatory)][string[]]$Blocks)

    $filtered = @($Blocks | Where-Object { Test-NonEmptyString $_ })
    return ($filtered -join "`r`n`r`n")
}
