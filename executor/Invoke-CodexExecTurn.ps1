[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [string]$PromptFilePath,
    [int]$TimeoutSec = 0,
    [switch]$DryRun,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SupportedSourceOutboxSchemaVersions = @('1.0.0', '1.0')

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function Get-NormalizedFullPath {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    }
    catch {
        return ([string]$Path).ToLowerInvariant()
    }
}

function Test-NormalizedPathMatch {
    param(
        [string]$Left,
        [string]$Right
    )

    if (-not (Test-NonEmptyString $Left) -or -not (Test-NonEmptyString $Right)) {
        return $false
    }

    return ((Get-NormalizedFullPath -Path $Left) -eq (Get-NormalizedFullPath -Path $Right))
}

function Test-RemovableStaleError {
    param(
        $ErrorDoc = $null,
        [string]$RequestPath = '',
        [string]$SummaryPath = '',
        [string]$SourceSummaryPath = '',
        [string]$SourceReviewZipPath = '',
        [string]$PublishReadyPath = ''
    )

    if ($null -eq $ErrorDoc) {
        return $false
    }

    $reason = [string](Get-ConfigValue -Object $ErrorDoc -Name 'Reason' -DefaultValue '')
    if ($reason -notin @('codex-exec-timeout', 'summary-missing-after-exec', 'summary-stale-after-exec', 'zip-missing-after-exec', 'zip-stale-after-exec', 'source-outbox-incomplete-after-exec')) {
        return $false
    }

    $errorRequestPath = [string](Get-ConfigValue -Object $ErrorDoc -Name 'RequestPath' -DefaultValue '')
    $requestMatched = $false
    if (Test-NonEmptyString $errorRequestPath -or Test-NonEmptyString $RequestPath) {
        if (-not (Test-NormalizedPathMatch -Left $errorRequestPath -Right $RequestPath)) {
            return $false
        }
        $requestMatched = $true
    }

    $hasSourceIdentity = $false
    foreach ($pair in @(
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'SourceSummaryPath' -DefaultValue ''), $SourceSummaryPath),
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'SourceReviewZipPath' -DefaultValue ''), $SourceReviewZipPath),
            @([string](Get-ConfigValue -Object $ErrorDoc -Name 'PublishReadyPath' -DefaultValue ''), $PublishReadyPath)
        )) {
        $left = [string]$pair[0]
        $right = [string]$pair[1]
        if (Test-NonEmptyString $left -or Test-NonEmptyString $right) {
            $hasSourceIdentity = $true
            if (-not (Test-NormalizedPathMatch -Left $left -Right $right)) {
                return $false
            }
        }
    }

    if ($hasSourceIdentity) {
        return $true
    }

    return $requestMatched
}

function Test-ZipArchiveReadable {
    param([Parameter(Mandatory)][string]$Path)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    }
    catch {
    }

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $null = $archive.Entries.Count
        }
        finally {
            if ($null -ne $archive) {
                $archive.Dispose()
            }
        }

        return [pscustomobject]@{
            Ok = $true
            ErrorMessage = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Ok = $false
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Get-FileHashHex {
    param([Parameter(Mandatory)][string]$Path)

    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Test-SourceOutboxMarkerContract {
    param(
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$SourceSummaryPath,
        [Parameter(Mandatory)][string]$SourceReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath
    )

    if (-not (Test-Path -LiteralPath $SourceSummaryPath -PathType Leaf)) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'source-summary-missing'
            ErrorMessage = ''
        }
    }

    if (-not (Test-Path -LiteralPath $SourceReviewZipPath -PathType Leaf)) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'source-reviewzip-missing'
            ErrorMessage = ''
        }
    }

    if (-not (Test-Path -LiteralPath $PublishReadyPath -PathType Leaf)) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'ready-missing'
            ErrorMessage = ''
        }
    }

    try {
        $marker = Read-JsonObject -Path $PublishReadyPath
    }
    catch {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-json-invalid'
            ErrorMessage = $_.Exception.Message
        }
    }

    if ($null -eq $marker) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-empty'
            ErrorMessage = ''
        }
    }

    foreach ($requiredField in @('SchemaVersion', 'PairId', 'TargetId', 'SummaryPath', 'ReviewZipPath', 'PublishedAt', 'SummarySizeBytes', 'ReviewZipSizeBytes')) {
        if (-not (Test-NonEmptyString ([string](Get-ConfigValue -Object $marker -Name $requiredField -DefaultValue '')))) {
            return [pscustomobject]@{
                Ok = $false
                Reason = ('marker-missing-field-' + $requiredField)
                ErrorMessage = ''
            }
        }
    }

    $markerSchemaVersion = [string](Get-ConfigValue -Object $marker -Name 'SchemaVersion' -DefaultValue '')
    if ($markerSchemaVersion -notin $SupportedSourceOutboxSchemaVersions) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-schema-version-unsupported'
            ErrorMessage = ('unsupported schema version: ' + $markerSchemaVersion)
        }
    }

    if ([string](Get-ConfigValue -Object $marker -Name 'PairId' -DefaultValue '') -ne $PairId) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-pairid-mismatch'
            ErrorMessage = ''
        }
    }

    if ([string](Get-ConfigValue -Object $marker -Name 'TargetId' -DefaultValue '') -ne $TargetId) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-targetid-mismatch'
            ErrorMessage = ''
        }
    }

    $expectedSummaryPath = Get-NormalizedFullPath -Path $SourceSummaryPath
    $expectedZipPath = Get-NormalizedFullPath -Path $SourceReviewZipPath
    $markerSummaryPath = Get-NormalizedFullPath -Path ([string](Get-ConfigValue -Object $marker -Name 'SummaryPath' -DefaultValue ''))
    $markerZipPath = Get-NormalizedFullPath -Path ([string](Get-ConfigValue -Object $marker -Name 'ReviewZipPath' -DefaultValue ''))
    if ($markerSummaryPath -ne $expectedSummaryPath) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-summary-path-mismatch'
            ErrorMessage = ''
        }
    }

    if ($markerZipPath -ne $expectedZipPath) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-reviewzip-path-mismatch'
            ErrorMessage = ''
        }
    }

    $summaryItem = Get-Item -LiteralPath $SourceSummaryPath -ErrorAction Stop
    $zipItem = Get-Item -LiteralPath $SourceReviewZipPath -ErrorAction Stop
    $readyItem = Get-Item -LiteralPath $PublishReadyPath -ErrorAction Stop
    $zipValidation = Test-ZipArchiveReadable -Path $SourceReviewZipPath
    if (-not [bool]$zipValidation.Ok) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'source-reviewzip-invalid'
            ErrorMessage = [string]$zipValidation.ErrorMessage
        }
    }

    if ($readyItem.LastWriteTimeUtc -lt $summaryItem.LastWriteTimeUtc -or $readyItem.LastWriteTimeUtc -lt $zipItem.LastWriteTimeUtc) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-before-artifacts'
            ErrorMessage = ''
        }
    }

    $summarySizeExpected = 0L
    if (-not [int64]::TryParse([string](Get-ConfigValue -Object $marker -Name 'SummarySizeBytes' -DefaultValue ''), [ref]$summarySizeExpected)) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-summary-size-invalid'
            ErrorMessage = ''
        }
    }

    $reviewZipSizeExpected = 0L
    if (-not [int64]::TryParse([string](Get-ConfigValue -Object $marker -Name 'ReviewZipSizeBytes' -DefaultValue ''), [ref]$reviewZipSizeExpected)) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-reviewzip-size-invalid'
            ErrorMessage = ''
        }
    }

    if ($summarySizeExpected -ne [int64]$summaryItem.Length) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'summary-size-mismatch'
            ErrorMessage = ''
        }
    }

    if ($reviewZipSizeExpected -ne [int64]$zipItem.Length) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'reviewzip-size-mismatch'
            ErrorMessage = ''
        }
    }

    $summaryHashExpected = [string](Get-ConfigValue -Object $marker -Name 'SummarySha256' -DefaultValue '')
    if (Test-NonEmptyString $summaryHashExpected) {
        $summaryHashActual = Get-FileHashHex -Path $SourceSummaryPath
        if ($summaryHashActual.ToLowerInvariant() -ne $summaryHashExpected.ToLowerInvariant()) {
            return [pscustomobject]@{
                Ok = $false
                Reason = 'summary-hash-mismatch'
                ErrorMessage = ''
            }
        }
    }

    $reviewZipHashExpected = [string](Get-ConfigValue -Object $marker -Name 'ReviewZipSha256' -DefaultValue '')
    if (Test-NonEmptyString $reviewZipHashExpected) {
        $reviewZipHashActual = Get-FileHashHex -Path $SourceReviewZipPath
        if ($reviewZipHashActual.ToLowerInvariant() -ne $reviewZipHashExpected.ToLowerInvariant()) {
            return [pscustomobject]@{
                Ok = $false
                Reason = 'reviewzip-hash-mismatch'
                ErrorMessage = ''
            }
        }
    }

    return [pscustomobject]@{
        Ok = $true
        Reason = 'ready'
        ErrorMessage = ''
    }
}

function Format-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return ('"' + $escaped + '"')
}

function Join-ProcessArguments {
    param([Parameter(Mandatory)][string[]]$Arguments)

    return (($Arguments | ForEach-Object { Format-ProcessArgument -Value $_ }) -join ' ')
}

function New-ProcessInvocationResult {
    param(
        [int]$ExitCode = 0,
        [string]$StdOut = '',
        [string]$StdErr = '',
        [bool]$TimedOut = $false,
        [bool]$Killed = $false,
        [string]$KillReason = '',
        [int]$DurationMs = 0
    )

    return [pscustomobject]@{
        ExitCode   = [int]$ExitCode
        StdOut     = [string]$StdOut
        StdErr     = [string]$StdErr
        TimedOut   = [bool]$TimedOut
        Killed     = [bool]$Killed
        KillReason = [string]$KillReason
        DurationMs = [int]$DurationMs
    }
}

function New-ProcessInvocationException {
    param(
        [Parameter(Mandatory)][string]$Message,
        $Result = $null
    )

    $exception = [System.Exception]::new($Message)
    if ($null -ne $Result) {
        $exception.Data['ProcessInvocationResult'] = $Result
    }
    return $exception
}

function Get-ExceptionDataValue {
    param(
        [System.Exception]$Exception,
        [Parameter(Mandatory)][string]$Key
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($null -ne $current.Data -and $current.Data.Contains($Key)) {
            return $current.Data[$Key]
        }
        $current = $current.InnerException
    }

    return $null
}

function Set-StatusFromProcessInvocationResult {
    param(
        [Parameter(Mandatory)]$Status,
        $Result = $null
    )

    if ($null -eq $Result) {
        return
    }

    $Status.ExitCode = [int]$Result.ExitCode
    $Status.TimedOut = [bool]$Result.TimedOut
    $Status.Killed = [bool]$Result.Killed
    $Status.KillReason = [string]$Result.KillReason
    $Status.DurationMs = [int]$Result.DurationMs
    $Status.StdOutChars = if (Test-NonEmptyString ([string]$Result.StdOut)) { [string]$Result.StdOut.Length } else { 0 }
    $Status.StdErrChars = if (Test-NonEmptyString ([string]$Result.StdErr)) { [string]$Result.StdErr.Length } else { 0 }
}

function New-ExecResultPayload {
    param(
        [Parameter(Mandatory)]$Status,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)]$TargetEntry,
        [Parameter(Mandatory)][string]$PromptSourcePath,
        [Parameter(Mandatory)][string]$HeadlessPromptPath,
        [Parameter(Mandatory)][string]$OutputLastMessagePath,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$SourceSummaryPath,
        [Parameter(Mandatory)][string]$SourceReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath,
        [bool]$SourceSummaryPresent = $false,
        [bool]$SourceReviewZipPresent = $false,
        [bool]$PublishReadyPresent = $false
    )

    return [ordered]@{
        CompletedAt                 = [string]$Status.CompletedAt
        PairId                      = [string]$PairId
        TargetId                    = [string]$TargetEntry.TargetId
        PartnerTargetId             = [string]$TargetEntry.PartnerTargetId
        ExitCode                    = $Status.ExitCode
        PromptSourcePath            = [string]$PromptSourcePath
        HeadlessPromptPath          = [string]$HeadlessPromptPath
        OutputLastMessagePath       = [string]$OutputLastMessagePath
        SummaryPath                 = [string]$SummaryPath
        LatestZipPath               = [string]$Status.LatestZipPath
        SourceSummaryPath           = [string]$SourceSummaryPath
        SourceReviewZipPath         = [string]$SourceReviewZipPath
        PublishReadyPath            = [string]$PublishReadyPath
        SummaryPresent              = [bool]$Status.SummaryPresent
        SummaryFresh                = [bool]$Status.SummaryFresh
        LatestZipFresh              = [bool]$Status.LatestZipFresh
        SourceSummaryPresent        = [bool]$SourceSummaryPresent
        SourceReviewZipPresent      = [bool]$SourceReviewZipPresent
        PublishReadyPresent         = [bool]$PublishReadyPresent
        ContractArtifactsReady      = [bool]$Status.ContractArtifactsReady
        ContractArtifactsReadyReason = [string]$Status.ContractArtifactsReadyReason
        SourceOutboxReady           = [bool]$Status.SourceOutboxReady
        SourceOutboxReadyReason     = [string]$Status.SourceOutboxReadyReason
        TimedOut                    = [bool]$Status.TimedOut
        Killed                      = [bool]$Status.Killed
        KillReason                  = [string]$Status.KillReason
        DurationMs                  = [int]$Status.DurationMs
        StdOutChars                 = [int]$Status.StdOutChars
        StdErrChars                 = [int]$Status.StdErrChars
    }
}

function New-ExecErrorPayload {
    param(
        [Parameter(Mandatory)]$Status,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)]$TargetEntry,
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$PromptSourcePath,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ResultPath,
        [string]$SourceSummaryPath = '',
        [string]$SourceReviewZipPath = '',
        [string]$PublishReadyPath = ''
    )

    return [ordered]@{
        FailedAt                    = [string]$Status.CompletedAt
        PairId                      = [string]$PairId
        TargetId                    = [string]$TargetEntry.TargetId
        PartnerTargetId             = [string]$TargetEntry.PartnerTargetId
        Reason                      = [string]$Status.Error
        ExitCode                    = $Status.ExitCode
        RequestPath                 = [string]$RequestPath
        PromptSourcePath            = [string]$PromptSourcePath
        SummaryPath                 = [string]$SummaryPath
        LatestZipPath               = [string]$Status.LatestZipPath
        SummaryFresh                = [bool]$Status.SummaryFresh
        LatestZipFresh              = [bool]$Status.LatestZipFresh
        ContractArtifactsReadyReason = [string]$Status.ContractArtifactsReadyReason
        SourceOutboxReadyReason      = [string]$Status.SourceOutboxReadyReason
        SourceSummaryPath           = [string]$SourceSummaryPath
        SourceReviewZipPath         = [string]$SourceReviewZipPath
        PublishReadyPath            = [string]$PublishReadyPath
        ResultPath                  = [string]$ResultPath
        TimedOut                    = [bool]$Status.TimedOut
        Killed                      = [bool]$Status.Killed
        KillReason                  = [string]$Status.KillReason
        DurationMs                  = [int]$Status.DurationMs
        StdOutChars                 = [int]$Status.StdOutChars
        StdErrChars                 = [int]$Status.StdErrChars
    }
}

function Get-PairExecMutexName {
    param(
        [Parameter(Mandatory)][string]$RunRootPath,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$Scope
    )

    $scopeKey = if ($Scope -eq 'target') { $TargetKey } else { $PairId }
    $hashInput = ('{0}|{1}|{2}' -f $RunRootPath.ToLowerInvariant(), $scopeKey.ToLowerInvariant(), $Scope.ToLowerInvariant())
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return ('Global\RelayPairExec_' + $hash)
}

function Acquire-Mutex {
    param([Parameter(Mandatory)][string]$Name)

    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, $Name, [ref]$createdNew)
    $acquired = $false

    try {
        try {
            $acquired = $mutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw "pair exec mutex already held: $Name"
        }

        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Get-LatestZipFile {
    param([Parameter(Mandatory)][string]$ReviewFolderPath)

    if (-not (Test-Path -LiteralPath $ReviewFolderPath)) {
        return $null
    }

    return (Get-ChildItem -LiteralPath $ReviewFolderPath -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, Name -Descending |
        Select-Object -First 1)
}

function Get-FileState {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [pscustomobject]@{
        Path             = $item.FullName
        LastWriteTimeUtc = $item.LastWriteTimeUtc
        Length           = if ($item.PSIsContainer) { 0 } else { [int64]$item.Length }
    }
}

function Test-FileFresh {
    param(
        [string]$Path,
        $Baseline = $null,
        [DateTime]$StartedAtUtc = [DateTime]::MinValue
    )

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.LastWriteTimeUtc -ge $StartedAtUtc) {
        return $true
    }

    if ($null -eq $Baseline) {
        return $false
    }

    if (-not (Test-NormalizedPathMatch -Left ([string]$Baseline.Path) -Right $item.FullName)) {
        return $true
    }

    $itemLength = if ($item.PSIsContainer) { 0 } else { [int64]$item.Length }
    return (($item.LastWriteTimeUtc.Ticks -ne [int64]$Baseline.LastWriteTimeUtc.Ticks) -or
        ($itemLength -ne [int64]$Baseline.Length))
}

function Test-SummaryReadyForZip {
    param(
        [Parameter(Mandatory)][string]$SummaryPath,
        $ZipFile = $null,
        [double]$MaxSkewSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $SummaryPath)) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'summary-missing'
        }
    }

    if ($null -eq $ZipFile) {
        return [pscustomobject]@{
            IsReady = $true
            Reason  = ''
        }
    }

    $summaryItem = Get-Item -LiteralPath $SummaryPath -ErrorAction Stop
    $deltaSeconds = ($ZipFile.LastWriteTimeUtc - $summaryItem.LastWriteTimeUtc).TotalSeconds
    if ($deltaSeconds -gt $MaxSkewSeconds) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'summary-stale'
        }
    }

    return [pscustomobject]@{
        IsReady = $true
        Reason  = ''
    }
}

function Test-SourceOutboxFreshReady {
    param(
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$SourceSummaryPath,
        [Parameter(Mandatory)][string]$SourceReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath,
        $SourceSummaryBaseline = $null,
        $SourceReviewZipBaseline = $null,
        $PublishReadyBaseline = $null,
        $StartedAtUtc = $null
    )

    $sourceSummaryPresent = [bool](Test-Path -LiteralPath $SourceSummaryPath)
    $sourceReviewZipPresent = [bool](Test-Path -LiteralPath $SourceReviewZipPath)
    $publishReadyPresent = [bool](Test-Path -LiteralPath $PublishReadyPath)

    $sourceSummaryFresh = $false
    $sourceReviewZipFresh = $false
    $publishReadyFresh = $false
    $reason = ''

    if ($sourceSummaryPresent) {
        $sourceSummaryFresh = if ($null -ne $StartedAtUtc) {
            [bool](Test-FileFresh -Path $SourceSummaryPath -Baseline $SourceSummaryBaseline -StartedAtUtc $StartedAtUtc)
        }
        else {
            $true
        }
    }

    if ($sourceReviewZipPresent) {
        $sourceReviewZipFresh = if ($null -ne $StartedAtUtc) {
            [bool](Test-FileFresh -Path $SourceReviewZipPath -Baseline $SourceReviewZipBaseline -StartedAtUtc $StartedAtUtc)
        }
        else {
            $true
        }
    }

    if ($publishReadyPresent) {
        $publishReadyFresh = if ($null -ne $StartedAtUtc) {
            [bool](Test-FileFresh -Path $PublishReadyPath -Baseline $PublishReadyBaseline -StartedAtUtc $StartedAtUtc)
        }
    else {
            $true
        }
    }

    if (-not $sourceSummaryPresent) {
        $reason = 'source-summary-missing'
    }
    elseif (-not $sourceReviewZipPresent) {
        $reason = 'source-reviewzip-missing'
    }
    elseif (-not $publishReadyPresent) {
        $reason = 'ready-missing'
    }
    elseif (-not $sourceSummaryFresh) {
        $reason = 'source-summary-not-fresh'
    }
    elseif (-not $sourceReviewZipFresh) {
        $reason = 'source-reviewzip-not-fresh'
    }
    elseif (-not $publishReadyFresh) {
        $reason = 'publish-ready-not-fresh'
    }
    else {
        $markerValidation = Test-SourceOutboxMarkerContract `
            -PairId $PairId `
            -TargetId $TargetId `
            -SourceSummaryPath $SourceSummaryPath `
            -SourceReviewZipPath $SourceReviewZipPath `
            -PublishReadyPath $PublishReadyPath
        $reason = [string]$markerValidation.Reason
    }

    return [pscustomobject]@{
        SourceSummaryPresent = $sourceSummaryPresent
        SourceReviewZipPresent = $sourceReviewZipPresent
        PublishReadyPresent = $publishReadyPresent
        SourceSummaryFresh = $sourceSummaryFresh
        SourceReviewZipFresh = $sourceReviewZipFresh
        PublishReadyFresh = $publishReadyFresh
        Reason = $reason
        IsReady = ([string]$reason -eq 'ready')
    }
}

function Resolve-LaunchCommand {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $command = Get-Command -Name $Executable -ErrorAction Stop | Select-Object -First 1
    $resolvedPath = if (Test-NonEmptyString ([string]$command.Source)) { [string]$command.Source } elseif (Test-NonEmptyString ([string]$command.Path)) { [string]$command.Path } else { [string]$Executable }
    $extension = [System.IO.Path]::GetExtension($resolvedPath)
    $leafName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
    $resolvedDirectory = Split-Path -Parent $resolvedPath

    if (([string]$leafName).Equals('codex', [System.StringComparison]::OrdinalIgnoreCase) -and (Test-NonEmptyString $resolvedDirectory)) {
        $codexEntryPath = Join-Path $resolvedDirectory 'node_modules\@openai\codex\bin\codex.js'
        if (Test-Path -LiteralPath $codexEntryPath -PathType Leaf) {
            $nodePath = ''
            $localNodePath = Join-Path $resolvedDirectory 'node.exe'
            if (Test-Path -LiteralPath $localNodePath -PathType Leaf) {
                $nodePath = $localNodePath
            }
            else {
                foreach ($nodeName in @('node.exe', 'node')) {
                    $nodeCommand = Get-Command -Name $nodeName -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($null -eq $nodeCommand) {
                        continue
                    }

                    if (Test-NonEmptyString ([string]$nodeCommand.Source)) {
                        $nodePath = [string]$nodeCommand.Source
                        break
                    }
                    if (Test-NonEmptyString ([string]$nodeCommand.Path)) {
                        $nodePath = [string]$nodeCommand.Path
                        break
                    }

                    $nodePath = $nodeName
                    break
                }
            }

            if (-not (Test-NonEmptyString $nodePath)) {
                throw ("node executable not found for codex shim: {0}" -f $resolvedPath)
            }

            return [pscustomobject]@{
                FilePath  = $nodePath
                Arguments = @($codexEntryPath) + $Arguments
                Resolved  = $resolvedPath
            }
        }
    }

    if ($extension -ieq '.ps1') {
        $hostPath = ''
        foreach ($hostName in @('pwsh.exe', 'powershell.exe')) {
            $hostCommand = Get-Command -Name $hostName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $hostCommand) {
                continue
            }

            if (Test-NonEmptyString ([string]$hostCommand.Source)) {
                $hostPath = [string]$hostCommand.Source
                break
            }
            if (Test-NonEmptyString ([string]$hostCommand.Path)) {
                $hostPath = [string]$hostCommand.Path
                break
            }

            $hostPath = $hostName
            break
        }

        if (-not (Test-NonEmptyString $hostPath)) {
            throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
        }

        return [pscustomobject]@{
            FilePath  = $hostPath
            Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolvedPath) + $Arguments
            Resolved  = $resolvedPath
        }
    }

    return [pscustomobject]@{
        FilePath  = $resolvedPath
        Arguments = @($Arguments)
        Resolved  = $resolvedPath
    }
}

function Invoke-ProcessWithStdin {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$InputText,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stdOutTask = $null
    $stdErrTask = $null

    try {
        [void]$process.Start()
        $stdOutTask = $process.StandardOutput.ReadToEndAsync()
        $stdErrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()

        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $killReason = 'timeout'
            $killed = $false
            try {
                $process.Kill()
                $killed = $true
            }
            catch {
                $killReason = 'timeout-kill-failed'
            }

            $null = $process.WaitForExit(2000)
            if ($null -ne $stdOutTask -and $null -ne $stdErrTask) {
                [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdOutTask, $stdErrTask), 2000)
            }
            $timeoutExitCode = if ($process.HasExited) { [int]$process.ExitCode } else { -1 }
            $timeoutStdOut = if ($null -ne $stdOutTask -and $stdOutTask.IsCompleted) { [string]$stdOutTask.Result } else { '' }
            $timeoutStdErr = if ($null -ne $stdErrTask -and $stdErrTask.IsCompleted) { [string]$stdErrTask.Result } else { '' }
            $result = New-ProcessInvocationResult `
                -ExitCode $timeoutExitCode `
                -StdOut $timeoutStdOut `
                -StdErr $timeoutStdErr `
                -TimedOut $true `
                -Killed $killed `
                -KillReason $killReason `
                -DurationMs ([int]$stopwatch.ElapsedMilliseconds)
            throw (New-ProcessInvocationException -Message "codex exec timed out after $TimeoutMilliseconds ms" -Result $result)
        }

        [void]$process.WaitForExit()
        if ($null -ne $stdOutTask -and $null -ne $stdErrTask) {
            [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdOutTask, $stdErrTask), 5000)
        }
        $completedStdOut = if ($null -ne $stdOutTask) { [string]$stdOutTask.Result } else { '' }
        $completedStdErr = if ($null -ne $stdErrTask) { [string]$stdErrTask.Result } else { '' }

        return (New-ProcessInvocationResult `
            -ExitCode ([int]$process.ExitCode) `
            -StdOut $completedStdOut `
            -StdErr $completedStdErr `
            -TimedOut $false `
            -Killed $false `
            -KillReason '' `
            -DurationMs ([int]$stopwatch.ElapsedMilliseconds))
    }
    finally {
        $stopwatch.Stop()
        $process.Dispose()
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$resolvedRunRoot = Resolve-PairRunRootPath -Root $root -RunRoot $RunRoot -PairTest $pairTest
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "manifest not found: $manifestPath"
}

$manifest = Read-JsonObject -Path $manifestPath
$targetEntry = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq [string]$TargetId } | Select-Object -First 1)
if ($targetEntry.Count -eq 0) {
    throw "target not found in manifest: $TargetId"
}
$targetEntry = $targetEntry[0]

$targetFolder = [string]$targetEntry.TargetFolder
$contract = Get-TargetContractPaths -PairTest $pairTest -TargetEntry $targetEntry
$requestPath = [string]$contract.RequestPath
$request = if (Test-Path -LiteralPath $requestPath) { Read-JsonObject -Path $requestPath } else { $null }
if ($null -eq $request) {
    throw "request file not found or empty: $requestPath"
}
$contract = Get-TargetContractPaths -PairTest $pairTest -TargetEntry $targetEntry -Request $request

$effectivePromptSourcePath = ''
if (Test-NonEmptyString $PromptFilePath) {
    $effectivePromptSourcePath = (Resolve-Path -LiteralPath $PromptFilePath).Path
}
elseif (Test-NonEmptyString ([string]$request.MessagePath) -and (Test-Path -LiteralPath ([string]$request.MessagePath))) {
    $effectivePromptSourcePath = [string]$request.MessagePath
}
elseif (Test-NonEmptyString ([string]$request.InstructionPath) -and (Test-Path -LiteralPath ([string]$request.InstructionPath))) {
    $effectivePromptSourcePath = [string]$request.InstructionPath
}
else {
    throw "no prompt source found for target: $TargetId"
}

$promptText = Get-Content -LiteralPath $effectivePromptSourcePath -Raw -Encoding UTF8
$headlessPromptPath = if (Test-NonEmptyString ([string]$request.HeadlessPromptFilePath)) { [string]$request.HeadlessPromptFilePath } else { Join-Path $targetFolder ([string]$pairTest.HeadlessExec.PromptFileName) }
$outputLastMessagePath = if (Test-NonEmptyString ([string]$request.OutputLastMessagePath)) { [string]$request.OutputLastMessagePath } else { Join-Path $targetFolder ([string]$pairTest.HeadlessExec.OutputLastMessageFileName) }
$reviewFolderPath = [string]$contract.ReviewFolderPath
$donePath = [string]$contract.DonePath
$errorPath = [string]$contract.ErrorPath
$resultPath = [string]$contract.ResultPath
$summaryPath = [string]$contract.SummaryPath
$sourceOutboxPath = if (Test-NonEmptyString ([string]$request.SourceOutboxPath)) { [string]$request.SourceOutboxPath } else { Join-Path $targetFolder ([string]$pairTest.SourceOutboxFolderName) }
$sourceSummaryPath = if (Test-NonEmptyString ([string]$request.SourceSummaryPath)) { [string]$request.SourceSummaryPath } else { Join-Path $sourceOutboxPath ([string]$pairTest.SourceSummaryFileName) }
$sourceReviewZipPath = if (Test-NonEmptyString ([string]$request.SourceReviewZipPath)) { [string]$request.SourceReviewZipPath } else { Join-Path $sourceOutboxPath ([string]$pairTest.SourceReviewZipFileName) }
$publishReadyPath = if (Test-NonEmptyString ([string]$request.PublishReadyPath)) { [string]$request.PublishReadyPath } else { Join-Path $sourceOutboxPath ([string]$pairTest.PublishReadyFileName) }

$timeoutSeconds = if ($TimeoutSec -gt 0) { $TimeoutSec } else { [int]$pairTest.HeadlessExec.MaxRunSeconds }
$timeoutMilliseconds = [Math]::Max(1, ($timeoutSeconds * 1000))
$argumentList = @([string[]]$pairTest.HeadlessExec.Arguments)
$argumentList += @('-C', $targetFolder, '-o', $outputLastMessagePath, '--color', 'never')
$launchResolveError = ''
$launchCommand = $null
if ($DryRun) {
    try {
        $launchCommand = Resolve-LaunchCommand -Executable ([string]$pairTest.HeadlessExec.CodexExecutable) -Arguments $argumentList
    }
    catch {
        $launchResolveError = $_.Exception.Message
        $launchCommand = [pscustomobject]@{
            FilePath  = ''
            Arguments = @($argumentList)
            Resolved  = ''
        }
    }
}
else {
    if (-not [bool]$pairTest.HeadlessExec.Enabled) {
        throw "headless exec is disabled in config: $resolvedConfigPath"
    }
    $launchCommand = Resolve-LaunchCommand -Executable ([string]$pairTest.HeadlessExec.CodexExecutable) -Arguments $argumentList
}
$mutexScope = [string]$pairTest.HeadlessExec.MutexScope
$pairId = [string]$targetEntry.PairId
$mutexName = Get-PairExecMutexName -RunRootPath $resolvedRunRoot -PairId $pairId -TargetKey ([string]$targetEntry.TargetId) -Scope $mutexScope

$status = [ordered]@{
    ConfigPath            = $resolvedConfigPath
    RunRoot               = $resolvedRunRoot
    PairId                = $pairId
    TargetId              = [string]$targetEntry.TargetId
    PartnerTargetId       = [string]$targetEntry.PartnerTargetId
    TargetFolder          = $targetFolder
    RequestPath           = $requestPath
    SummaryPath           = $summaryPath
    ReviewFolderPath      = $reviewFolderPath
    PromptSourcePath      = $effectivePromptSourcePath
    HeadlessPromptPath    = $headlessPromptPath
    OutputLastMessagePath = $outputLastMessagePath
    ResultPath            = $resultPath
    DonePath              = $donePath
    ErrorPath             = $errorPath
    MutexName             = $mutexName
    CodexExecutable       = [string]$pairTest.HeadlessExec.CodexExecutable
    CodexResolvedPath     = [string]$launchCommand.Resolved
    LaunchFilePath        = [string]$launchCommand.FilePath
    ArgumentList          = @($launchCommand.Arguments)
    LaunchResolveError    = $launchResolveError
    HeadlessExecEnabled   = [bool]$pairTest.HeadlessExec.Enabled
    TimeoutSec            = $timeoutSeconds
    DryRun                = [bool]$DryRun
    ExitCode              = $null
    CompletedAt           = ''
    LatestZipPath         = ''
    SummaryPresent        = $false
    SummaryFresh          = $false
    LatestZipFresh        = $false
    ContractArtifactsReady = $false
    ContractArtifactsReadyReason = ''
    SourceOutboxReady     = $false
    SourceOutboxReadyReason = ''
    TimedOut              = $false
    Killed                = $false
    KillReason            = ''
    DurationMs            = 0
    StdOutChars           = 0
    StdErrChars           = 0
    Error                 = ''
}

if ($DryRun) {
    $status.CompletedAt = (Get-Date).ToString('o')
    if ($AsJson) {
        [pscustomobject]$status | ConvertTo-Json -Depth 8
    }
    else {
        [pscustomobject]$status
    }
    return
}

$mutex = $null
$preExecSummaryState = $null
$preExecLatestZipState = $null
$preExecSourceSummaryState = $null
$preExecSourceReviewZipState = $null
$preExecPublishReadyState = $null
$executionStartedAtUtc = $null
try {
    $preExecSummaryState = Get-FileState -Path $summaryPath
    $preExecLatestZip = Get-LatestZipFile -ReviewFolderPath $reviewFolderPath
    $preExecLatestZipState = if ($null -ne $preExecLatestZip) { Get-FileState -Path $preExecLatestZip.FullName } else { $null }
    $preExecSourceSummaryState = Get-FileState -Path $sourceSummaryPath
    $preExecSourceReviewZipState = Get-FileState -Path $sourceReviewZipPath
    $preExecPublishReadyState = Get-FileState -Path $publishReadyPath
    Ensure-Directory -Path $targetFolder
    [System.IO.File]::WriteAllText($headlessPromptPath, $promptText, (New-Utf8NoBomEncoding))
    $mutex = Acquire-Mutex -Name $mutexName
    $executionStartedAtUtc = (Get-Date).ToUniversalTime()
    $invocationResult = Invoke-ProcessWithStdin -FilePath ([string]$launchCommand.FilePath) -Arguments @($launchCommand.Arguments) -WorkingDirectory $targetFolder -InputText $promptText -TimeoutMilliseconds $timeoutMilliseconds
    Set-StatusFromProcessInvocationResult -Status $status -Result $invocationResult
    $status.CompletedAt = (Get-Date).ToString('o')

    $latestZip = Get-LatestZipFile -ReviewFolderPath $reviewFolderPath
    $status.LatestZipPath = if ($null -ne $latestZip) { $latestZip.FullName } else { '' }
    $status.SummaryPresent = [bool](Test-Path -LiteralPath $summaryPath)
    $summaryReadiness = Test-SummaryReadyForZip -SummaryPath $summaryPath -ZipFile $latestZip -MaxSkewSeconds ([double]$pairTest.SummaryZipMaxSkewSeconds)
    $status.SummaryFresh = [bool](Test-FileFresh -Path $summaryPath -Baseline $preExecSummaryState -StartedAtUtc $executionStartedAtUtc)
    $status.LatestZipFresh = if ($null -ne $latestZip) {
        [bool](Test-FileFresh -Path $latestZip.FullName -Baseline $preExecLatestZipState -StartedAtUtc $executionStartedAtUtc)
    }
    else {
        $false
    }
    $sourceOutboxState = Test-SourceOutboxFreshReady `
        -PairId $pairId `
        -TargetId ([string]$targetEntry.TargetId) `
        -SourceSummaryPath $sourceSummaryPath `
        -SourceReviewZipPath $sourceReviewZipPath `
        -PublishReadyPath $publishReadyPath `
        -SourceSummaryBaseline $preExecSourceSummaryState `
        -SourceReviewZipBaseline $preExecSourceReviewZipState `
        -PublishReadyBaseline $preExecPublishReadyState `
        -StartedAtUtc $executionStartedAtUtc
    $sourceSummaryPresent = [bool]$sourceOutboxState.SourceSummaryPresent
    $sourceReviewZipPresent = [bool]$sourceOutboxState.SourceReviewZipPresent
    $publishReadyPresent = [bool]$sourceOutboxState.PublishReadyPresent
    $status.SourceOutboxReady = [bool]$sourceOutboxState.IsReady
    $status.SourceOutboxReadyReason = [string]$sourceOutboxState.Reason
    $status.ContractArtifactsReadyReason = if ($status.TimedOut) {
        'timed-out'
    }
    elseif ($status.ExitCode -ne 0) {
        'nonzero-exit'
    }
    elseif (-not $status.SummaryPresent) {
        'summary-missing'
    }
    elseif (-not (Test-NonEmptyString $status.LatestZipPath)) {
        'zip-missing'
    }
    elseif (-not $status.SummaryFresh) {
        'summary-not-fresh'
    }
    elseif (-not $status.LatestZipFresh) {
        'zip-not-fresh'
    }
    elseif (-not [bool]$summaryReadiness.IsReady) {
        [string]$summaryReadiness.Reason
    }
    else {
        'ready'
    }
    $contractArtifactsReady = ([string]$status.ContractArtifactsReadyReason -eq 'ready')
    $status.ContractArtifactsReady = [bool]$contractArtifactsReady

    $resultPayload = New-ExecResultPayload `
        -Status $status `
        -PairId $pairId `
        -TargetEntry $targetEntry `
        -PromptSourcePath $effectivePromptSourcePath `
        -HeadlessPromptPath $headlessPromptPath `
        -OutputLastMessagePath $outputLastMessagePath `
        -SummaryPath $summaryPath `
        -SourceSummaryPath $sourceSummaryPath `
        -SourceReviewZipPath $sourceReviewZipPath `
        -PublishReadyPath $publishReadyPath `
        -SourceSummaryPresent ([bool]$sourceSummaryPresent) `
        -SourceReviewZipPresent ([bool]$sourceReviewZipPresent) `
        -PublishReadyPresent ([bool]$publishReadyPresent)
    $resultPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    if ($contractArtifactsReady) {
        $donePayload = [ordered]@{
            CompletedAt           = $status.CompletedAt
            PairId                = $pairId
            TargetId              = [string]$targetEntry.TargetId
            PartnerTargetId       = [string]$targetEntry.PartnerTargetId
            RequestPath           = $requestPath
            PromptSourcePath      = $effectivePromptSourcePath
            HeadlessPromptPath    = $headlessPromptPath
            OutputLastMessagePath = $outputLastMessagePath
            SummaryPath           = $summaryPath
            LatestZipPath         = $status.LatestZipPath
            ResultPath            = $resultPath
        }
        $donePayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $donePath -Encoding UTF8
        if (Test-Path -LiteralPath $errorPath) {
            $existingError = $null
            try {
                $existingError = Read-JsonObject -Path $errorPath
            }
            catch {
                $existingError = $null
            }
            if (Test-RemovableStaleError -ErrorDoc $existingError -RequestPath $requestPath -SummaryPath $summaryPath -SourceSummaryPath $sourceSummaryPath -SourceReviewZipPath $sourceReviewZipPath -PublishReadyPath $publishReadyPath) {
                Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    elseif (($status.ExitCode -eq 0) -and $status.SourceOutboxReady) {
        # source-outbox mode publishes asynchronously after this exec returns,
        # so root contract summary/reviewfile are not expected yet.
        $donePayload = [ordered]@{
            CompletedAt            = $status.CompletedAt
            Mode                   = 'source-outbox-publish'
            PairId                 = $pairId
            TargetId               = [string]$targetEntry.TargetId
            PartnerTargetId        = [string]$targetEntry.PartnerTargetId
            RequestPath            = $requestPath
            PromptSourcePath       = $effectivePromptSourcePath
            HeadlessPromptPath     = $headlessPromptPath
            OutputLastMessagePath  = $outputLastMessagePath
            SummarySourcePath      = $sourceSummaryPath
            ReviewZipSourcePath    = $sourceReviewZipPath
            PublishReadyPath       = $publishReadyPath
            SummaryPath            = $summaryPath
            LatestZipPath          = $status.LatestZipPath
            ResultPath             = $resultPath
            ContractArtifactsReady = [bool]$contractArtifactsReady
            ContractArtifactsReadyReason = [string]$status.ContractArtifactsReadyReason
            SourceOutboxReadyReason = [string]$status.SourceOutboxReadyReason
        }
        $donePayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $donePath -Encoding UTF8
        if (Test-Path -LiteralPath $errorPath) {
            $existingError = $null
            try {
                $existingError = Read-JsonObject -Path $errorPath
            }
            catch {
                $existingError = $null
            }
            if (Test-RemovableStaleError -ErrorDoc $existingError -RequestPath $requestPath -SummaryPath $summaryPath -SourceSummaryPath $sourceSummaryPath -SourceReviewZipPath $sourceReviewZipPath -PublishReadyPath $publishReadyPath) {
                Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        $status.Error = if ($status.TimedOut) {
            'codex-exec-timeout'
        }
        elseif ($status.ExitCode -ne 0) {
            'codex-exec-nonzero-exit'
        }
        elseif ($sourceSummaryPresent -or $sourceReviewZipPresent -or $publishReadyPresent) {
            'source-outbox-incomplete-after-exec'
        }
        elseif (-not $status.SummaryPresent) {
            'summary-missing-after-exec'
        }
        elseif (-not $status.SummaryFresh -or [string]$status.ContractArtifactsReadyReason -eq 'summary-stale') {
            'summary-stale-after-exec'
        }
        elseif (-not (Test-NonEmptyString $status.LatestZipPath)) {
            'zip-missing-after-exec'
        }
        elseif (-not $status.LatestZipFresh) {
            'zip-stale-after-exec'
        }
        else {
            'zip-missing-after-exec'
        }
        $errorPayload = New-ExecErrorPayload `
            -Status $status `
            -PairId $pairId `
            -TargetEntry $targetEntry `
            -RequestPath $requestPath `
            -PromptSourcePath $effectivePromptSourcePath `
            -SummaryPath $summaryPath `
            -ResultPath $resultPath `
            -SourceSummaryPath $sourceSummaryPath `
            -SourceReviewZipPath $sourceReviewZipPath `
            -PublishReadyPath $publishReadyPath
        $errorPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $errorPath -Encoding UTF8
        if (Test-Path -LiteralPath $donePath) {
            Remove-Item -LiteralPath $donePath -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    $processResult = Get-ExceptionDataValue -Exception $_.Exception -Key 'ProcessInvocationResult'
    Set-StatusFromProcessInvocationResult -Status $status -Result $processResult
    $status.CompletedAt = (Get-Date).ToString('o')
    $status.Error = if ($status.TimedOut) { 'codex-exec-timeout' } else { $_.Exception.Message }
    if ($status.TimedOut -and -not (Test-NonEmptyString $status.ContractArtifactsReadyReason)) {
        $status.ContractArtifactsReadyReason = 'timed-out'
    }
    $latestZip = Get-LatestZipFile -ReviewFolderPath $reviewFolderPath
    $status.LatestZipPath = if ($null -ne $latestZip) { $latestZip.FullName } else { '' }
    $status.SummaryPresent = [bool](Test-Path -LiteralPath $summaryPath)
    if ($null -ne $executionStartedAtUtc) {
        $status.SummaryFresh = [bool](Test-FileFresh -Path $summaryPath -Baseline $preExecSummaryState -StartedAtUtc $executionStartedAtUtc)
        $status.LatestZipFresh = if ($null -ne $latestZip) {
            [bool](Test-FileFresh -Path $latestZip.FullName -Baseline $preExecLatestZipState -StartedAtUtc $executionStartedAtUtc)
        }
        else {
            $false
        }
    }
    $sourceOutboxState = Test-SourceOutboxFreshReady `
        -PairId $pairId `
        -TargetId ([string]$targetEntry.TargetId) `
        -SourceSummaryPath $sourceSummaryPath `
        -SourceReviewZipPath $sourceReviewZipPath `
        -PublishReadyPath $publishReadyPath `
        -SourceSummaryBaseline $preExecSourceSummaryState `
        -SourceReviewZipBaseline $preExecSourceReviewZipState `
        -PublishReadyBaseline $preExecPublishReadyState `
        -StartedAtUtc $executionStartedAtUtc
    $status.SourceOutboxReady = [bool]$sourceOutboxState.IsReady
    $status.SourceOutboxReadyReason = [string]$sourceOutboxState.Reason
    if ($null -ne $processResult) {
        $resultPayload = New-ExecResultPayload `
            -Status $status `
            -PairId $pairId `
            -TargetEntry $targetEntry `
            -PromptSourcePath $effectivePromptSourcePath `
            -HeadlessPromptPath $headlessPromptPath `
            -OutputLastMessagePath $outputLastMessagePath `
            -SummaryPath $summaryPath `
            -SourceSummaryPath $sourceSummaryPath `
            -SourceReviewZipPath $sourceReviewZipPath `
            -PublishReadyPath $publishReadyPath `
            -SourceSummaryPresent ([bool]$sourceOutboxState.SourceSummaryPresent) `
            -SourceReviewZipPresent ([bool]$sourceOutboxState.SourceReviewZipPresent) `
            -PublishReadyPresent ([bool]$sourceOutboxState.PublishReadyPresent)
        $resultPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    }
    if ($status.SourceOutboxReady) {
        $donePayload = [ordered]@{
            CompletedAt            = $status.CompletedAt
            Mode                   = 'source-outbox-publish'
            PairId                 = $pairId
            TargetId               = [string]$targetEntry.TargetId
            PartnerTargetId        = [string]$targetEntry.PartnerTargetId
            RequestPath            = $requestPath
            PromptSourcePath       = $effectivePromptSourcePath
            HeadlessPromptPath     = $headlessPromptPath
            OutputLastMessagePath  = $outputLastMessagePath
            SummarySourcePath      = $sourceSummaryPath
            ReviewZipSourcePath    = $sourceReviewZipPath
            PublishReadyPath       = $publishReadyPath
            SummaryPath            = $summaryPath
            LatestZipPath          = $status.LatestZipPath
            ResultPath             = $resultPath
            ContractArtifactsReady = [bool]$status.ContractArtifactsReady
            ContractArtifactsReadyReason = [string]$status.ContractArtifactsReadyReason
            SourceOutboxReadyReason = [string]$status.SourceOutboxReadyReason
            TimedOut               = [bool]$status.TimedOut
            Killed                 = [bool]$status.Killed
            KillReason             = [string]$status.KillReason
        }
        $donePayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $donePath -Encoding UTF8
        if (Test-Path -LiteralPath $errorPath) {
            $existingError = $null
            try {
                $existingError = Read-JsonObject -Path $errorPath
            }
            catch {
                $existingError = $null
            }
            if (Test-RemovableStaleError -ErrorDoc $existingError -RequestPath $requestPath -SummaryPath $summaryPath -SourceSummaryPath $sourceSummaryPath -SourceReviewZipPath $sourceReviewZipPath -PublishReadyPath $publishReadyPath) {
                Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
            }
        }
        $status.Error = ''
    }
    else {
        $errorPayload = New-ExecErrorPayload `
            -Status $status `
            -PairId $pairId `
            -TargetEntry $targetEntry `
            -RequestPath $requestPath `
            -PromptSourcePath $effectivePromptSourcePath `
            -SummaryPath $summaryPath `
            -ResultPath $resultPath `
            -SourceSummaryPath $sourceSummaryPath `
            -SourceReviewZipPath $sourceReviewZipPath `
            -PublishReadyPath $publishReadyPath
        $errorPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $errorPath -Encoding UTF8
        if (Test-Path -LiteralPath $donePath) {
            Remove-Item -LiteralPath $donePath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}
finally {
    if ($null -ne $mutex) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }

        $mutex.Dispose()
    }
}

if ($AsJson) {
    [pscustomobject]$status | ConvertTo-Json -Depth 8
}
else {
    [pscustomobject]$status
}
