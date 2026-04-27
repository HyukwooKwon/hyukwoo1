[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string[]]$IncludePairId,
    [string[]]$InitialTargetId,
    [string[]]$SeedTargetId,
    [string]$SeedWorkRepoRoot,
    [string]$SeedReviewInputPath,
    [string]$SeedTaskText,
    [string]$SeedTaskFilePath,
    [switch]$SendInitialMessages,
    [switch]$UseHeadlessDispatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return $Value.Replace("'", "''")
}

function Normalize-MultilineText {
    param([Parameter(Mandatory)][string]$Value)

    return (($Value -replace "`r?`n", "`r`n").TrimEnd([char[]]"`r`n"))
}

function Resolve-OptionalLiteralPath {
    param([AllowEmptyString()][string]$PathValue)

    if (-not (Test-NonEmptyString $PathValue)) {
        return ''
    }

    return (Resolve-Path -LiteralPath $PathValue).Path
}

function Resolve-FullPathFromBase {
    param(
        [AllowEmptyString()][string]$PathValue,
        [Parameter(Mandatory)][string]$BasePath
    )

    if (-not (Test-NonEmptyString $PathValue)) {
        return ''
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Get-SeedReviewInputCandidates {
    param(
        [Parameter(Mandatory)][string]$DirectoryPath,
        [Parameter(Mandatory)][string]$Filter,
        [AllowEmptyString()][string]$NameRegex = '',
        [double]$MaxAgeHours = 0
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        return @()
    }

    $cutoffUtc = $null
    if ($MaxAgeHours -gt 0) {
        $cutoffUtc = (Get-Date).ToUniversalTime().AddHours(-1 * $MaxAgeHours)
    }

    $items = @(
        Get-ChildItem -LiteralPath $DirectoryPath -Filter $Filter -File -ErrorAction SilentlyContinue |
            Where-Object {
                $nameMatches = if (Test-NonEmptyString $NameRegex) { ($_.Name -match $NameRegex) } else { $true }
                $ageMatches = (($null -eq $cutoffUtc) -or ($_.LastWriteTimeUtc -ge $cutoffUtc))
                ($nameMatches -and $ageMatches)
            } |
            Sort-Object LastWriteTimeUtc, Name -Descending
    )

    return @($items)
}

function Resolve-SeedReviewInputSelection {
    param(
        [AllowEmptyString()][string]$ExplicitPath = '',
        [AllowEmptyString()][string]$SearchRoot = '',
        [Parameter(Mandatory)][string]$Filter,
        [AllowEmptyString()][string]$NameRegex = '',
        [double]$MaxAgeHours = 0,
        [bool]$RequireSingleCandidate = $false
    )

    if (Test-NonEmptyString $ExplicitPath) {
        $resolvedPath = Resolve-OptionalLiteralPath -PathValue $ExplicitPath
        $selectedItem = if (Test-NonEmptyString $resolvedPath) { Get-Item -LiteralPath $resolvedPath -ErrorAction Stop } else { $null }
        return [pscustomobject]@{
            Path                     = $resolvedPath
            SelectionMode            = 'explicit'
            SearchRoot               = if (Test-NonEmptyString $SearchRoot) { [System.IO.Path]::GetFullPath($SearchRoot) } else { '' }
            CandidateCount           = if ($null -ne $selectedItem) { 1 } else { 0 }
            SelectedLastWriteTimeUtc = if ($null -ne $selectedItem) { $selectedItem.LastWriteTimeUtc.ToString('o') } else { '' }
            RejectionReason          = ''
        }
    }

    if (-not (Test-NonEmptyString $SearchRoot)) {
        return [pscustomobject]@{
            Path                     = ''
            SelectionMode            = 'auto-no-search-root'
            SearchRoot               = ''
            CandidateCount           = 0
            SelectedLastWriteTimeUtc = ''
            RejectionReason          = 'search-root-missing'
        }
    }

    $resolvedSearchRoot = [System.IO.Path]::GetFullPath($SearchRoot)
    if (-not (Test-Path -LiteralPath $resolvedSearchRoot -PathType Container)) {
        return [pscustomobject]@{
            Path                     = ''
            SelectionMode            = 'auto-search-root-missing'
            SearchRoot               = $resolvedSearchRoot
            CandidateCount           = 0
            SelectedLastWriteTimeUtc = ''
            RejectionReason          = 'search-root-missing'
        }
    }

    $candidates = @(Get-SeedReviewInputCandidates -DirectoryPath $resolvedSearchRoot -Filter $Filter -NameRegex $NameRegex -MaxAgeHours $MaxAgeHours)
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            Path                     = ''
            SelectionMode            = 'auto-no-candidates'
            SearchRoot               = $resolvedSearchRoot
            CandidateCount           = 0
            SelectedLastWriteTimeUtc = ''
            RejectionReason          = if ($MaxAgeHours -gt 0) { 'no-fresh-candidates' } else { 'no-candidates' }
        }
    }

    if ($RequireSingleCandidate -and $candidates.Count -ne 1) {
        return [pscustomobject]@{
            Path                     = ''
            SelectionMode            = 'auto-rejected-multiple'
            SearchRoot               = $resolvedSearchRoot
            CandidateCount           = $candidates.Count
            SelectedLastWriteTimeUtc = ''
            RejectionReason          = 'multiple-candidates'
        }
    }

    $selected = $candidates[0]
    return [pscustomobject]@{
        Path                     = [string]$selected.FullName
        SelectionMode            = if ($candidates.Count -eq 1) { 'auto-single-candidate' } else { 'auto-latest-candidate' }
        SearchRoot               = $resolvedSearchRoot
        CandidateCount           = $candidates.Count
        SelectedLastWriteTimeUtc = $selected.LastWriteTimeUtc.ToString('o')
        RejectionReason          = ''
    }
}

function Compose-RelayPayloadPreview {
    param(
        [Parameter(Mandatory)][string]$Body,
        [AllowEmptyString()][string]$FixedSuffix = ''
    )

    $normalizedBody = Normalize-MultilineText -Value $Body
    $effectiveFixedSuffix = if ($null -eq $FixedSuffix) { '' } else { [string]$FixedSuffix }
    if ($effectiveFixedSuffix.Trim() -eq '여기에 고정문구 입력') {
        $FixedSuffix = ''
    }
    if ([string]::IsNullOrWhiteSpace($FixedSuffix)) {
        return $normalizedBody
    }

    $normalizedSuffix = Normalize-MultilineText -Value $FixedSuffix
    return ($normalizedBody + "`r`n`r`n" + $normalizedSuffix)
}

function Get-EffectiveRelayPayloadPreviewFixedSuffix {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Target
    )

    $placeholderFixedSuffix = '여기에 고정문구 입력'
    $targetFixedSuffixValue = Get-ConfigValue -Object $Target -Name 'FixedSuffix' -DefaultValue $null
    if ($null -ne $targetFixedSuffixValue) {
        $targetFixedSuffix = [string]$targetFixedSuffixValue
        if ($targetFixedSuffix.Trim() -eq $placeholderFixedSuffix) {
            return ''
        }

        return $targetFixedSuffix
    }

    $defaultFixedSuffix = [string](Get-ConfigValue -Object $Config -Name 'DefaultFixedSuffix' -DefaultValue '')
    if ($defaultFixedSuffix.Trim() -eq $placeholderFixedSuffix) {
        return ''
    }

    return $defaultFixedSuffix
}

function Assert-RelayPayloadBudget {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$Body
    )

    $target = @($Config.Targets | Where-Object { [string]$_.Id -eq $TargetId } | Select-Object -First 1)
    if ($target.Count -eq 0) {
        throw "target relay config not found: $TargetId"
    }

    $fixedSuffix = Get-EffectiveRelayPayloadPreviewFixedSuffix -Config $Config -Target $target[0]
    $payload = Compose-RelayPayloadPreview -Body $Body -FixedSuffix $fixedSuffix
    $payloadChars = $payload.Length
    $payloadBytes = (New-Utf8NoBomEncoding).GetByteCount($payload)
    if ($payloadChars -gt [int]$Config.MaxPayloadChars) {
        throw ("initial relay payload chars exceeded target={0} chars={1} limit={2}" -f $TargetId, $payloadChars, [int]$Config.MaxPayloadChars)
    }
    if ($payloadBytes -gt [int]$Config.MaxPayloadBytes) {
        throw ("initial relay payload bytes exceeded target={0} bytes={1} limit={2}" -f $TargetId, $payloadBytes, [int]$Config.MaxPayloadBytes)
    }
}

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }

        if ($command.Source) {
            return [string]$command.Source
        }
        if ($command.Path) {
            return [string]$command.Path
        }
        return [string]$name
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Invoke-InitialHeadlessTurn {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PromptFilePath,
        [Parameter(Mandatory)][string]$LogPath
    )

    $powershellPath = Resolve-PowerShellExecutable
    $stderrLogPath = ($LogPath + '.stderr')
    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'invoke-codex-exec-turn.ps1'),
        '-ConfigPath', $ConfigPath,
        '-RunRoot', $RunRoot,
        '-TargetId', $TargetId,
        '-PromptFilePath', $PromptFilePath
    )
    $process = Start-Process -FilePath $powershellPath -ArgumentList $argumentList -Wait -PassThru -NoNewWindow -RedirectStandardOutput $LogPath -RedirectStandardError $stderrLogPath

    if ($process.ExitCode -ne 0) {
        throw "headless initial dispatch failed target=$TargetId exitCode=$($process.ExitCode) stdout=$LogPath stderr=$stderrLogPath"
    }
}

function New-TargetCheckScriptContent {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId
    )

    $rootLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $Root
    $configLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $ResolvedConfigPath
    $runRootLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $RunRoot
    $targetLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $TargetId

    return @"
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]`$SummarySourcePath,
    [Parameter(Mandatory)][string]`$ReviewZipSourcePath,
    [switch]`$KeepZipFileName,
    [switch]`$AsJson
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$repoRoot = '$rootLiteral'
`$arguments = @{
    ConfigPath          = '$configLiteral'
    RunRoot             = '$runRootLiteral'
    TargetId            = '$targetLiteral'
    SummarySourcePath   = `$SummarySourcePath
    ReviewZipSourcePath = `$ReviewZipSourcePath
    KeepZipFileName     = [bool]`$KeepZipFileName
    AsJson              = [bool]`$AsJson
}

& (Join-Path `$repoRoot 'check-paired-exchange-artifact.ps1') @arguments
"@
}

function New-TargetSubmitScriptContent {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId
    )

    $rootLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $Root
    $configLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $ResolvedConfigPath
    $runRootLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $RunRoot
    $targetLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $TargetId

    return @"
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]`$SummarySourcePath,
    [Parameter(Mandatory)][string]`$ReviewZipSourcePath,
    [switch]`$KeepZipFileName,
    [switch]`$Overwrite,
    [switch]`$DryRun,
    [switch]`$AsJson
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$repoRoot = '$rootLiteral'
`$arguments = @{
    ConfigPath          = '$configLiteral'
    RunRoot             = '$runRootLiteral'
    TargetId            = '$targetLiteral'
    SummarySourcePath   = `$SummarySourcePath
    ReviewZipSourcePath = `$ReviewZipSourcePath
    KeepZipFileName     = [bool]`$KeepZipFileName
    Overwrite           = [bool]`$Overwrite
    DryRun              = [bool]`$DryRun
    AsJson              = [bool]`$AsJson
}

& (Join-Path `$repoRoot 'import-paired-exchange-artifact.ps1') @arguments
"@
}

function New-TargetCmdLauncherContent {
    param([Parameter(Mandatory)][string]$Ps1FileName)

    return (@(
        '@echo off',
        'set "PSBIN=pwsh"',
        'where pwsh >nul 2>nul',
        'if errorlevel 1 set "PSBIN=powershell"',
        ('%PSBIN% -NoProfile -ExecutionPolicy Bypass -File "%~dp0{0}" %*' -f $Ps1FileName)
    ) -join "`r`n")
}

function Write-TargetAutomationScripts {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][string]$TargetId
    )

    $checkScriptPath = Join-Path $TargetFolder ([string]$PairTest.CheckScriptFileName)
    $submitScriptPath = Join-Path $TargetFolder ([string]$PairTest.SubmitScriptFileName)
    $checkCmdPath = Join-Path $TargetFolder ([string]$PairTest.CheckCmdFileName)
    $submitCmdPath = Join-Path $TargetFolder ([string]$PairTest.SubmitCmdFileName)

    [System.IO.File]::WriteAllText(
        $checkScriptPath,
        (New-TargetCheckScriptContent -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot -TargetId $TargetId),
        (New-Utf8NoBomEncoding)
    )
    [System.IO.File]::WriteAllText(
        $submitScriptPath,
        (New-TargetSubmitScriptContent -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot -TargetId $TargetId),
        (New-Utf8NoBomEncoding)
    )
    [System.IO.File]::WriteAllText(
        $checkCmdPath,
        (New-TargetCmdLauncherContent -Ps1FileName ([string]$PairTest.CheckScriptFileName)),
        (New-Utf8NoBomEncoding)
    )
    [System.IO.File]::WriteAllText(
        $submitCmdPath,
        (New-TargetCmdLauncherContent -Ps1FileName ([string]$PairTest.SubmitScriptFileName)),
        (New-Utf8NoBomEncoding)
    )

    return [pscustomobject]@{
        CheckScriptPath  = $checkScriptPath
        SubmitScriptPath = $submitScriptPath
        CheckCmdPath     = $checkCmdPath
        SubmitCmdPath    = $submitCmdPath
    }
}

function Get-PairDefinitions {
    param(
        [Parameter(Mandatory)]$PairTest,
        [string[]]$IncludePairId
    )

    return @(Select-PairDefinitions -PairDefinitions @($PairTest.PairDefinitions) -IncludePairId $IncludePairId)
}

function New-DisabledSeedReviewSelection {
    return [pscustomobject]@{
        Path                     = ''
        SelectionMode            = 'disabled'
        SearchRoot               = ''
        CandidateCount           = 0
        SelectedLastWriteTimeUtc = ''
        RejectionReason          = ''
    }
}

function Resolve-TargetSeedContext {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$PairPolicy,
        [bool]$IsSeedTarget = $false,
        [string]$ExplicitSeedWorkRepoRoot = '',
        [string]$ExplicitSeedReviewInputPath = '',
        [string]$ExplicitSeedTaskText = ''
    )

    if (-not $IsSeedTarget) {
        return [pscustomobject]@{
            WorkRepoRoot = ''
            ReviewInputPath = ''
            SeedTaskText = ''
            ReviewInputSelection = (New-DisabledSeedReviewSelection)
        }
    }

    $workRepoRootCandidate = if (Test-NonEmptyString $ExplicitSeedWorkRepoRoot) {
        $ExplicitSeedWorkRepoRoot
    }
    else {
        [string](Get-ConfigValue -Object $PairPolicy -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')
    }
    $resolvedWorkRepoRoot = Resolve-OptionalLiteralPath -PathValue $workRepoRootCandidate

    $reviewInputCandidate = if (Test-NonEmptyString $ExplicitSeedReviewInputPath) {
        $ExplicitSeedReviewInputPath
    }
    else {
        [string](Get-ConfigValue -Object $PairPolicy -Name 'DefaultSeedReviewInputPath' -DefaultValue '')
    }
    $seedReviewSearchRoot = if (-not (Test-NonEmptyString $reviewInputCandidate) -and (Test-NonEmptyString $resolvedWorkRepoRoot)) {
        Join-Path $resolvedWorkRepoRoot ([string](Get-ConfigValue -Object $PairPolicy -Name 'DefaultSeedReviewInputSearchRelativePath' -DefaultValue ([string]$PairTest.DefaultSeedReviewInputSearchRelativePath)))
    }
    else {
        ''
    }
    $seedReviewSelection = Resolve-SeedReviewInputSelection `
        -ExplicitPath $reviewInputCandidate `
        -SearchRoot $seedReviewSearchRoot `
        -Filter ([string](Get-ConfigValue -Object $PairPolicy -Name 'DefaultSeedReviewInputFilter' -DefaultValue ([string]$PairTest.DefaultSeedReviewInputFilter))) `
        -NameRegex ([string](Get-ConfigValue -Object $PairPolicy -Name 'DefaultSeedReviewInputNameRegex' -DefaultValue ([string]$PairTest.DefaultSeedReviewInputNameRegex))) `
        -MaxAgeHours ([double](Get-ConfigValue -Object $PairPolicy -Name 'DefaultSeedReviewInputMaxAgeHours' -DefaultValue ([double]$PairTest.DefaultSeedReviewInputMaxAgeHours))) `
        -RequireSingleCandidate ([bool](Get-ConfigValue -Object $PairPolicy -Name 'DefaultSeedReviewInputRequireSingleCandidate' -DefaultValue ([bool]$PairTest.DefaultSeedReviewInputRequireSingleCandidate)))

    return [pscustomobject]@{
        WorkRepoRoot = $resolvedWorkRepoRoot
        ReviewInputPath = [string]$seedReviewSelection.Path
        SeedTaskText = [string]$ExplicitSeedTaskText
        ReviewInputSelection = $seedReviewSelection
    }
}

function Get-PathLeafName {
    param([Parameter(Mandatory)][string]$Path)

    $trimmed = $Path.TrimEnd([char[]]"\ /")
    if (-not (Test-NonEmptyString $trimmed)) {
        return ''
    }

    return [System.IO.Path]::GetFileName($trimmed)
}

function Resolve-PairWorkRepoRoot {
    param(
        [Parameter(Mandatory)]$PairPolicy,
        [string]$ExplicitSeedWorkRepoRoot = ''
    )

    $workRepoRootCandidate = if (Test-NonEmptyString $ExplicitSeedWorkRepoRoot) {
        $ExplicitSeedWorkRepoRoot
    }
    else {
        [string](Get-ConfigValue -Object $PairPolicy -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')
    }

    return (Resolve-OptionalLiteralPath -PathValue $workRepoRootCandidate)
}

function Test-UseExternalWorkRepoContractPaths {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$PairPolicy,
        [string]$PairWorkRepoRoot = ''
    )

    if (-not (Test-NonEmptyString $PairWorkRepoRoot)) {
        return $false
    }

    return [bool](Get-ConfigValue -Object $PairPolicy -Name 'UseExternalWorkRepoContractPaths' -DefaultValue ([bool](Get-ConfigValue -Object $PairTest -Name 'UseExternalWorkRepoContractPaths' -DefaultValue $false)))
}

function Get-TargetSourceContractPaths {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$PairPolicy,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$TargetFolder,
        [string]$PairWorkRepoRoot = ''
    )

    $useExternal = Test-UseExternalWorkRepoContractPaths -PairTest $PairTest -PairPolicy $PairPolicy -PairWorkRepoRoot $PairWorkRepoRoot
    if ($useExternal) {
        $contractRootSpec = [string](Get-ConfigValue -Object $PairPolicy -Name 'ExternalWorkRepoContractRelativeRoot' -DefaultValue ([string](Get-ConfigValue -Object $PairTest -Name 'ExternalWorkRepoContractRelativeRoot' -DefaultValue '.relay-contract\bottest-live-visible')))
        $resolvedContractBase = if ([System.IO.Path]::IsPathRooted($contractRootSpec)) {
            [System.IO.Path]::GetFullPath($contractRootSpec)
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path $PairWorkRepoRoot $contractRootSpec))
        }
        $runLeaf = Get-PathLeafName -Path $RunRoot
        $contractRootPath = Join-Path $resolvedContractBase (Join-Path $runLeaf (Join-Path $PairId $TargetId))
        $sourceOutboxPath = Join-Path $contractRootPath ([string]$PairTest.SourceOutboxFolderName)
        $sourceSummaryPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
        $sourceReviewZipPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
        $publishReadyPath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishReadyFileName)
        $publishedArchivePath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishedArchiveFolderName)

        return [pscustomobject]@{
            ContractPathMode    = 'external-workrepo'
            ContractRootPath    = $contractRootPath
            ContractBasePath    = $resolvedContractBase
            SourceOutboxPath    = $sourceOutboxPath
            SourceSummaryPath   = $sourceSummaryPath
            SourceReviewZipPath = $sourceReviewZipPath
            PublishReadyPath    = $publishReadyPath
            PublishedArchivePath = $publishedArchivePath
        }
    }

    $sourceOutboxPath = Join-Path $TargetFolder ([string]$PairTest.SourceOutboxFolderName)
    $sourceSummaryPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
    $sourceReviewZipPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
    $publishReadyPath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishReadyFileName)
    $publishedArchivePath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishedArchiveFolderName)

    return [pscustomobject]@{
        ContractPathMode    = 'runroot'
        ContractRootPath    = $TargetFolder
        ContractBasePath    = $RunRoot
        SourceOutboxPath    = $sourceOutboxPath
        SourceSummaryPath   = $sourceSummaryPath
        SourceReviewZipPath = $sourceReviewZipPath
        PublishReadyPath    = $publishReadyPath
        PublishedArchivePath = $publishedArchivePath
    }
}

function Get-NormalizedAbsolutePath {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathDescendsFromRoot {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$CandidatePath
    )

    $normalizedRoot = (Get-NormalizedAbsolutePath -Path $RootPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $normalizedCandidate = Get-NormalizedAbsolutePath -Path $CandidatePath
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($normalizedCandidate.Equals($normalizedRoot, $comparison)) {
        return $true
    }

    $rootWithSeparator = ($normalizedRoot + [System.IO.Path]::DirectorySeparatorChar)
    return $normalizedCandidate.StartsWith($rootWithSeparator, $comparison)
}

function Assert-ExternalContractPathValidation {
    param(
        [Parameter(Mandatory)]$PairRows,
        [Parameter(Mandatory)]$TargetContractPathMap
    )

    $ownerByPath = @{}
    foreach ($pair in @($PairRows)) {
        $pairId = [string]$pair.PairId
        $pairWorkRepoRoot = [string]$pair.PairWorkRepoRoot
        $useExternal = [bool]$pair.UseExternalWorkRepoContractPaths

        foreach ($targetId in @([string]$pair.TopTargetId, [string]$pair.BottomTargetId)) {
            $contractKey = ($pairId + '|' + $targetId)
            $contractPaths = $TargetContractPathMap[$contractKey]
            if ($null -eq $contractPaths) {
                throw ("external-contract-paths-missing pair={0} target={1}" -f $pairId, $targetId)
            }

            $ownerLabel = ($pairId + ':' + $targetId)
            $requiredFields = @(
                'ContractRootPath',
                'SourceOutboxPath',
                'SourceSummaryPath',
                'SourceReviewZipPath',
                'PublishReadyPath',
                'PublishedArchivePath'
            )
            foreach ($fieldName in $requiredFields) {
                $fieldValue = [string](Get-ConfigValue -Object $contractPaths -Name $fieldName -DefaultValue '')
                if (-not (Test-NonEmptyString $fieldValue)) {
                    throw ("external-contract-path-missing field={0} pair={1} target={2}" -f $fieldName, $pairId, $targetId)
                }

                $normalizedValue = Get-NormalizedAbsolutePath -Path $fieldValue
                $existingOwner = [string](Get-ConfigValue -Object $ownerByPath -Name $normalizedValue -DefaultValue '')
                if ((Test-NonEmptyString $existingOwner) -and ($existingOwner -ne $ownerLabel)) {
                    throw ("external-contract-path-collision path={0} owner={1} other={2}" -f $normalizedValue, $ownerLabel, $existingOwner)
                }
                $ownerByPath[$normalizedValue] = $ownerLabel

                if ($useExternal -and -not (Test-PathDescendsFromRoot -RootPath $pairWorkRepoRoot -CandidatePath $normalizedValue)) {
                    throw ("external-contract-path-outside-workrepo pair={0} target={1} field={2} workRepoRoot={3} path={4}" -f $pairId, $targetId, $fieldName, $pairWorkRepoRoot, $normalizedValue)
                }
            }

            $normalizedSourceOutboxPath = Get-NormalizedAbsolutePath -Path ([string]$contractPaths.SourceOutboxPath)
            $normalizedContractRootPath = Get-NormalizedAbsolutePath -Path ([string]$contractPaths.ContractRootPath)
            if (-not (Test-PathDescendsFromRoot -RootPath $normalizedContractRootPath -CandidatePath $normalizedSourceOutboxPath)) {
                throw ("external-contract-source-outbox-outside-root pair={0} target={1} contractRoot={2} sourceOutbox={3}" -f $pairId, $targetId, $normalizedContractRootPath, $normalizedSourceOutboxPath)
            }

            foreach ($childField in @('SourceSummaryPath', 'SourceReviewZipPath', 'PublishReadyPath', 'PublishedArchivePath')) {
                $childPath = Get-NormalizedAbsolutePath -Path ([string](Get-ConfigValue -Object $contractPaths -Name $childField -DefaultValue ''))
                if (-not (Test-PathDescendsFromRoot -RootPath $normalizedSourceOutboxPath -CandidatePath $childPath)) {
                    throw ("external-contract-child-outside-outbox pair={0} target={1} field={2} sourceOutbox={3} path={4}" -f $pairId, $targetId, $childField, $normalizedSourceOutboxPath, $childPath)
                }
            }
        }
    }
}

function Get-AutomaticPathGuideBlock {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][string]$PartnerFolder,
        [Parameter(Mandatory)][string]$ReviewSummaryPath,
        [Parameter(Mandatory)][string]$ReviewZipPath,
        [Parameter(Mandatory)][string]$OutputSummaryPath,
        [Parameter(Mandatory)][string]$OutputReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath,
        [string]$WorkRepoRoot = '',
        [string]$ExternalReviewInputPath = ''
    )

    $availableReviewInputPaths = New-Object System.Collections.Generic.List[string]
    $seenReviewInputPaths = @{}
    foreach ($candidate in @($ReviewSummaryPath, $ReviewZipPath, $ExternalReviewInputPath)) {
        if (-not (Test-NonEmptyString $candidate)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $normalized = [System.IO.Path]::GetFullPath($candidate)
        if ($seenReviewInputPaths.ContainsKey($normalized)) {
            continue
        }
        $seenReviewInputPaths[$normalized] = $true
        $availableReviewInputPaths.Add($normalized)
    }

    $lines = @(
        '[자동 경로 안내]'
        ('현재 대상: ' + $TargetId)
        ('프로젝트 작업 repo: ' + $(if (Test-NonEmptyString $WorkRepoRoot) { $WorkRepoRoot } else { '(not-set)' }))
        ('내 작업 폴더: ' + $TargetFolder)
        ('상대 작업 폴더: ' + $PartnerFolder)
        ''
    )
    if ($availableReviewInputPaths.Count -gt 0) {
        $lines += '먼저 확인할 파일:'
        foreach ($path in @($availableReviewInputPaths)) {
            $lines += ('- ' + $path)
        }
    }
    else {
        $lines += '먼저 확인할 검토 입력 파일 없음. 현재 작업 파일 기준으로 검토 후 내 출력 파일을 생성하세요.'
    }
    $lines += @(
        ''
        '내가 생성할 파일:'
        ('- summary.txt: ' + $OutputSummaryPath)
        ('- review.zip: ' + $OutputReviewZipPath)
        ('- publish.ready.json: ' + $PublishReadyPath)
    )

    return ($lines -join "`r`n")
}

function Get-TargetInstructionText {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PartnerTargetId,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][string]$PartnerFolder,
        [string]$PartnerSourceSummaryPath = '',
        [string]$PartnerSourceReviewZipPath = '',
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ReviewFolderPath,
        [Parameter(Mandatory)][string]$DoneFilePath,
        [Parameter(Mandatory)][string]$ResultFilePath,
        [Parameter(Mandatory)][string]$WorkFolderPath,
        [Parameter(Mandatory)][string]$SourceOutboxPath,
        [Parameter(Mandatory)][string]$SourceSummaryPath,
        [Parameter(Mandatory)][string]$SourceReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath,
        [Parameter(Mandatory)][string]$PublishedArchivePath,
        [Parameter(Mandatory)][string]$CheckScriptPath,
        [Parameter(Mandatory)][string]$SubmitScriptPath,
        [Parameter(Mandatory)][string]$CheckCmdPath,
        [Parameter(Mandatory)][string]$SubmitCmdPath,
        [Parameter(Mandatory)][string]$InitialRoleMode,
        [string]$WorkRepoRoot = '',
        [string]$ReviewInputPath = '',
        [string]$SeedTaskText = '',
        $OneTimeItems = @()
    )

    $templateBlocks = Get-PairTemplateBlocks -PairTest $PairTest -TemplateName 'Initial' -PairId $PairId -RoleName $RoleName -TargetId $TargetId
    if ($InitialRoleMode -eq 'handoff_wait') {
        $templateBlocks = [pscustomobject]@{
            SlotOrder = @($templateBlocks.SlotOrder)
            PrefixBlocks = @($templateBlocks.PrefixBlocks)
            ExtraBlocks = @()
            SuffixBlocks = @($templateBlocks.SuffixBlocks)
            Sources = [pscustomobject]@{
                Pair = @()
                Role = @()
                Target = @()
            }
        }
    }
    $summaryFileName = [string]$PairTest.SummaryFileName
    $reviewFolderName = [string]$PairTest.ReviewFolderName
    $reviewZipPattern = [string]$PairTest.ReviewZipPattern
    $sourceSummaryFileName = [string]$PairTest.SourceSummaryFileName
    $sourceReviewZipFileName = [string]$PairTest.SourceReviewZipFileName
    $publishReadyFileName = [string]$PairTest.PublishReadyFileName
    $oneTimeSplit = Split-OneTimeQueueItemsByPlacement -Items $OneTimeItems
    if (-not (Test-NonEmptyString $PartnerSourceSummaryPath)) {
        $partnerSourceOutboxPath = Join-Path $PartnerFolder ([string]$PairTest.SourceOutboxFolderName)
        $PartnerSourceSummaryPath = Join-Path $partnerSourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
    }
    if (-not (Test-NonEmptyString $PartnerSourceReviewZipPath)) {
        $partnerSourceOutboxPath = Join-Path $PartnerFolder ([string]$PairTest.SourceOutboxFolderName)
        $PartnerSourceReviewZipPath = Join-Path $partnerSourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
    }
    $pathGuideBlock = Get-AutomaticPathGuideBlock `
        -TargetId $TargetId `
        -TargetFolder $TargetFolder `
        -PartnerFolder $PartnerFolder `
        -ReviewSummaryPath $PartnerSourceSummaryPath `
        -ReviewZipPath $PartnerSourceReviewZipPath `
        -OutputSummaryPath $SourceSummaryPath `
        -OutputReviewZipPath $SourceReviewZipPath `
        -PublishReadyPath $PublishReadyPath `
        -WorkRepoRoot $WorkRepoRoot `
        -ExternalReviewInputPath $ReviewInputPath

    $primaryBlock = switch ($InitialRoleMode) {
        'seed' {
@"
[initial-role]
mode: seed
WorkRepoRoot: $WorkRepoRoot
ReviewInputPath: $ReviewInputPath
SourceOutboxPath: $SourceOutboxPath

지금은 이 target이 초기 seed 대상입니다. 작업을 바로 시작하세요.
최종 결과는 SourceOutboxPath 아래의 summary.txt, review.zip, publish.ready.json 세 파일로만 publish 합니다.
직접 contract folder 복사나 별도 submit 명령은 금지입니다.
$(if (Test-NonEmptyString $SeedTaskText) { "`r`nTask:`r`n$SeedTaskText" } else { '' })
"@
        }
        'handoff_wait' {
@"
[initial-role]
mode: handoff-wait
SourceOutboxPath: $SourceOutboxPath

지금은 초기 seed 대상이 아닙니다.
partner handoff message가 오기 전까지 작업을 시작하지 마세요.
handoff를 받으면 partner가 넘긴 summary/review zip을 입력으로 사용하고, 최종 결과만 SourceOutboxPath 아래의 summary.txt, review.zip, publish.ready.json 세 파일로 publish 합니다.
"@
        }
        default {
@"
[initial-role]
mode: standard
SourceOutboxPath: $SourceOutboxPath
"@
        }
    }

    $bodyBlock = @"
$primaryBlock

[paired-exchange]
pair: $PairId
role: $RoleName
me: $TargetId
partner: $PartnerTargetId

$pathGuideBlock

파일 계약:
- summary file name: $summaryFileName
- review folder name: $reviewFolderName
- review zip pattern: $reviewZipPattern

이번 target의 절대 경로 계약:
- SummaryPath: $SummaryPath
- ReviewFolderPath: $ReviewFolderPath
- DoneFilePath: $DoneFilePath
- ResultFilePath: $ResultFilePath
- WorkFolderPath: $WorkFolderPath
- SourceOutboxPath: $SourceOutboxPath
- SourceSummaryPath: $SourceSummaryPath
- SourceReviewZipPath: $SourceReviewZipPath
- PublishReadyPath: $PublishReadyPath
- PublishedArchivePath: $PublishedArchivePath
- CheckScriptPath: $CheckScriptPath
- SubmitScriptPath: $SubmitScriptPath
- CheckCmdPath: $CheckCmdPath
- SubmitCmdPath: $SubmitCmdPath

이번 테스트에서는 아래 규칙으로 움직이세요.
1. 프로젝트 작업은 현재 work repo 또는 '$WorkFolderPath' 아래에서 자유롭게 진행합니다.
2. 최종 source 산출물은 '$SourceOutboxPath' 아래의 '$sourceSummaryFileName' 와 '$sourceReviewZipFileName' 으로만 정리합니다.
3. publish 완료 신호는 '$PublishReadyPath' 파일입니다. 이 파일은 반드시 summary/zip 작성이 끝난 뒤 마지막에 생성합니다.
4. '$publishReadyFileName' 필수 필드는 SchemaVersion, PairId, TargetId, SummaryPath, ReviewZipPath, PublishedAt, SummarySizeBytes, ReviewZipSizeBytes 입니다. SchemaVersion 값은 정확히 '1.0.0' 으로 작성합니다. SummarySha256, ReviewZipSha256, SourceContext 는 선택입니다.
5. marker의 SummaryPath / ReviewZipPath 는 '$SourceSummaryPath' 와 '$SourceReviewZipPath' 를 가리켜야 합니다. 크기나 선택 해시가 실제 파일과 다르면 자동 publish가 거부됩니다.
6. 직접 paired contract 경로(SummaryPath / ReviewFolderPath / Done/Result)에 복사하지 마세요. watcher가 source-outbox marker를 감지하면 기존 import를 자동 호출합니다.
7. 자동 publish가 성공하면 ready marker는 '$PublishedArchivePath' 아래로 archive 되고, 기존 handoff는 contract folder 기준으로 계속 진행됩니다.
8. 자동 publish가 실패하거나 legacy RunRoot 복구가 필요할 때만 '$CheckCmdPath' 또는 '$SubmitCmdPath' / PowerShell wrapper를 수동 recovery 용도로 사용합니다.
9. 일반 프로젝트 폴더나 다른 target 폴더에만 파일을 만들고 끝내면 watcher가 인식하지 않습니다.
10. handoff를 받으면 상대 폴더의 '$summaryFileName' 와 '$reviewFolderName' zip을 읽고 다음 작업을 이어갑니다.
"@

    $blocks = Get-OrderedMessageBlocks -TemplateBlocks $templateBlocks -BodyText $bodyBlock -OneTimeItems $OneTimeItems
    return (Join-MessageBlocks -Blocks $blocks)
}

function Get-TargetInitialSeedMessageText {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PartnerTargetId,
        [Parameter(Mandatory)][string]$InitialRoleMode,
        [Parameter(Mandatory)][string]$InstructionPath,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][string]$PartnerFolder,
        [string]$PartnerSourceSummaryPath = '',
        [string]$PartnerSourceReviewZipPath = '',
        [Parameter(Mandatory)][string]$SourceOutboxPath,
        [Parameter(Mandatory)][string]$SourceSummaryPath,
        [Parameter(Mandatory)][string]$SourceReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath,
        [string]$WorkRepoRoot = '',
        [string]$ReviewInputPath = '',
        [string]$SeedTaskText = '',
        $OneTimeItems = @()
    )

    $templateBlocks = Get-PairTemplateBlocks -PairTest $PairTest -TemplateName 'Initial' -PairId $PairId -RoleName $RoleName -TargetId $TargetId
    if ($InitialRoleMode -eq 'handoff_wait') {
        $templateBlocks = [pscustomobject]@{
            SlotOrder = @($templateBlocks.SlotOrder)
            PrefixBlocks = @($templateBlocks.PrefixBlocks)
            ExtraBlocks = @()
            SuffixBlocks = @($templateBlocks.SuffixBlocks)
            Sources = [pscustomobject]@{
                Pair = @()
                Role = @()
                Target = @()
            }
        }
    }
    if (-not (Test-NonEmptyString $PartnerSourceSummaryPath)) {
        $partnerSourceOutboxPath = Join-Path $PartnerFolder ([string]$PairTest.SourceOutboxFolderName)
        $PartnerSourceSummaryPath = Join-Path $partnerSourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
    }
    if (-not (Test-NonEmptyString $PartnerSourceReviewZipPath)) {
        $partnerSourceOutboxPath = Join-Path $PartnerFolder ([string]$PairTest.SourceOutboxFolderName)
        $PartnerSourceReviewZipPath = Join-Path $partnerSourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
    }
    $pathGuideBlock = Get-AutomaticPathGuideBlock `
        -TargetId $TargetId `
        -TargetFolder $TargetFolder `
        -PartnerFolder $PartnerFolder `
        -ReviewSummaryPath $PartnerSourceSummaryPath `
        -ReviewZipPath $PartnerSourceReviewZipPath `
        -OutputSummaryPath $SourceSummaryPath `
        -OutputReviewZipPath $SourceReviewZipPath `
        -PublishReadyPath $PublishReadyPath `
        -WorkRepoRoot $WorkRepoRoot `
        -ExternalReviewInputPath $ReviewInputPath
    $bodyBlock = switch ($InitialRoleMode) {
        'seed' {
@"
[paired-exchange-seed]
pair: $PairId
me: $TargetId
partner: $PartnerTargetId

$pathGuideBlock

지금은 이 target만 먼저 시작합니다. partner는 handoff를 받은 뒤 자동으로 이어집니다.
WorkRepoRoot: $WorkRepoRoot
ReviewInputPath: $ReviewInputPath
최종 결과는 아래 source-outbox 계약만 따르세요.
- SourceOutboxPath: $SourceOutboxPath
- summary.txt: $SourceSummaryPath
- review.zip: $SourceReviewZipPath
- publish.ready.json: $PublishReadyPath

규칙:
1. summary.txt 와 review.zip 작성이 끝난 뒤 마지막에 publish.ready.json 을 생성합니다.
2. publish.ready.json 최소 필드는 SchemaVersion, PairId, TargetId, SummaryPath, ReviewZipPath, PublishedAt, SummarySizeBytes, ReviewZipSizeBytes 입니다. SchemaVersion 값은 정확히 '1.0.0' 으로 작성합니다.
3. marker의 SummaryPath / ReviewZipPath 는 위 source-outbox 파일을 가리켜야 합니다.
4. 직접 target contract 경로에 복사하거나 별도 submit 명령을 다시 실행하지 마세요.
5. 상세 계약과 recovery 경로는 instructions.txt 를 확인하세요: $InstructionPath
$(if (Test-NonEmptyString $SeedTaskText) { "`r`nTask:`r`n$SeedTaskText" } else { '' })
"@
        }
        'handoff_wait' {
@"
[handoff-wait]
pair: $PairId
me: $TargetId
partner: $PartnerTargetId

$pathGuideBlock

지금은 초기 seed 대상이 아닙니다.
partner handoff message가 오기 전까지 작업을 시작하지 마세요.
handoff를 받으면 partner가 넘긴 summary/review zip을 입력으로 사용하세요.
내 최종 결과는 아래 source-outbox 계약만 따르세요.
- SourceOutboxPath: $SourceOutboxPath
- summary.txt: $SourceSummaryPath
- review.zip: $SourceReviewZipPath
- publish.ready.json: $PublishReadyPath

상세 계약은 instructions.txt 를 확인하세요: $InstructionPath
"@
        }
        default {
@"
[paired-exchange-seed]
pair: $PairId
me: $TargetId
partner: $PartnerTargetId

$pathGuideBlock

SourceOutboxPath: $SourceOutboxPath
summary.txt: $SourceSummaryPath
review.zip: $SourceReviewZipPath
publish.ready.json: $PublishReadyPath

상세 계약은 instructions.txt 를 확인하세요: $InstructionPath
"@
        }
    }

    $blocks = Get-OrderedMessageBlocks -TemplateBlocks $templateBlocks -BodyText $bodyBlock -OneTimeItems $OneTimeItems
    return (Join-MessageBlocks -Blocks $blocks)
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')
. (Join-Path $PSScriptRoot 'OneTimeMessageQueue.ps1')
. (Join-Path $PSScriptRoot 'PairActivation.ps1')
. (Join-Path $root 'router\RelayMessageMetadata.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$selectedPairs = @(Get-PairDefinitions -PairTest $pairTest -IncludePairId $IncludePairId)

$requestedSeedTargetIds = @(
    if ($PSBoundParameters.ContainsKey('SeedTargetId') -and @($SeedTargetId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        @($SeedTargetId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }
    elseif ($PSBoundParameters.ContainsKey('InitialTargetId') -and @($InitialTargetId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        @($InitialTargetId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }
    else {
        @(
            foreach ($pair in @($selectedPairs)) {
                $pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId ([string]$pair.PairId)
                [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedTargetId' -DefaultValue ([string]$pair.TopTargetId))
            }
        ) | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique
    }
)
$seedTargetId = if ($requestedSeedTargetIds.Count -eq 1) { [string]$requestedSeedTargetIds[0] } else { '' }
$seedTaskTextSpecified = $PSBoundParameters.ContainsKey('SeedTaskText') -and (Test-NonEmptyString $SeedTaskText)
$seedTaskFileSpecified = $PSBoundParameters.ContainsKey('SeedTaskFilePath') -and (Test-NonEmptyString $SeedTaskFilePath)
if ($seedTaskTextSpecified -and $seedTaskFileSpecified) {
    throw 'SeedTaskText and SeedTaskFilePath cannot both be provided.'
}

$resolvedSeedTaskText = ''
if ($seedTaskFileSpecified) {
    $resolvedSeedTaskFilePath = (Resolve-Path -LiteralPath $SeedTaskFilePath).Path
    $resolvedSeedTaskText = [System.IO.File]::ReadAllText($resolvedSeedTaskFilePath, (New-Utf8NoBomEncoding))
}
elseif ($seedTaskTextSpecified) {
    $resolvedSeedTaskText = [string]$SeedTaskText
}

$hasExplicitSeedContext = (
    ($PSBoundParameters.ContainsKey('SeedWorkRepoRoot') -and (Test-NonEmptyString $SeedWorkRepoRoot)) -or
    ($PSBoundParameters.ContainsKey('SeedReviewInputPath') -and (Test-NonEmptyString $SeedReviewInputPath)) -or
    (Test-NonEmptyString $resolvedSeedTaskText)
)
if ($hasExplicitSeedContext -and $requestedSeedTargetIds.Count -ne 1) {
    throw 'SeedWorkRepoRoot / SeedReviewInputPath / SeedTaskText require exactly one SeedTargetId (or InitialTargetId).'
}
$seedTargetPairPolicy = $null
if (Test-NonEmptyString $seedTargetId) {
    $seedTargetPair = @($selectedPairs | Where-Object {
            ([string]$_.TopTargetId -eq $seedTargetId) -or ([string]$_.BottomTargetId -eq $seedTargetId)
        } | Select-Object -First 1)
    if (@($seedTargetPair).Count -gt 0) {
        $seedTargetPairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId ([string]$seedTargetPair[0].PairId)
    }
}
$manifestSeedContext = if ($null -ne $seedTargetPairPolicy) {
    Resolve-TargetSeedContext `
        -PairTest $pairTest `
        -PairPolicy $seedTargetPairPolicy `
        -IsSeedTarget $true `
        -ExplicitSeedWorkRepoRoot $SeedWorkRepoRoot `
        -ExplicitSeedReviewInputPath $SeedReviewInputPath `
        -ExplicitSeedTaskText $resolvedSeedTaskText
}
else {
    [pscustomobject]@{
        WorkRepoRoot = ''
        ReviewInputPath = ''
        SeedTaskText = ''
        ReviewInputSelection = [pscustomobject]@{
            Path                     = ''
            SelectionMode            = 'disabled-multiple-seed-targets'
            SearchRoot               = ''
            CandidateCount           = 0
            SelectedLastWriteTimeUtc = ''
            RejectionReason          = ''
        }
    }
}
$resolvedSeedWorkRepoRoot = [string]$manifestSeedContext.WorkRepoRoot
$seedReviewSelection = $manifestSeedContext.ReviewInputSelection
$resolvedSeedReviewInputPath = [string]$manifestSeedContext.ReviewInputPath
if ($null -ne $seedTargetPairPolicy) {
    Assert-SeedWorkRepoPolicy `
        -PairTest $pairTest `
        -PairPolicy $seedTargetPairPolicy `
        -AutomationRoot $root `
        -WorkRepoRoot $resolvedSeedWorkRepoRoot `
        -ReviewInputPath $resolvedSeedReviewInputPath
}

$pairRows = @()
$pairActivationSummary = @()
foreach ($pair in @($selectedPairs)) {
    $pairId = [string]$pair.PairId
    $pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId $pairId
    $pairWorkRepoRoot = Resolve-PairWorkRepoRoot -PairPolicy $pairPolicy -ExplicitSeedWorkRepoRoot $SeedWorkRepoRoot
    $pairUsesExternalContractPaths = Test-UseExternalWorkRepoContractPaths -PairTest $pairTest -PairPolicy $pairPolicy -PairWorkRepoRoot $pairWorkRepoRoot
    $pairUsesExternalRunRoot = Test-UseExternalWorkRepoRunRoot -PairTest $pairTest -PairPolicy $pairPolicy -WorkRepoRoot $pairWorkRepoRoot
    $pairRows += [pscustomobject]@{
        PairId = $pairId
        TopTargetId = [string]$pair.TopTargetId
        BottomTargetId = [string]$pair.BottomTargetId
        SeedTargetId = [string]$pair.SeedTargetId
        Policy = $pairPolicy
        PairWorkRepoRoot = $pairWorkRepoRoot
        UseExternalWorkRepoContractPaths = $pairUsesExternalContractPaths
        UseExternalWorkRepoRunRoot = $pairUsesExternalRunRoot
    }
}

$runRootPolicy = $null
$runRootWorkRepoRoot = ''
$externalRunRootPairs = @($pairRows | Where-Object { [bool]$_.UseExternalWorkRepoRunRoot })
if ($externalRunRootPairs.Count -gt 0) {
    $distinctWorkRepoRoots = @(
        $externalRunRootPairs |
            ForEach-Object { [string]$_.PairWorkRepoRoot } |
            Where-Object { Test-NonEmptyString $_ } |
            Sort-Object -Unique
    )
    if ($distinctWorkRepoRoots.Count -ne 1) {
        throw ('external run root requires exactly one shared WorkRepoRoot for the selected pairs. actual={0}' -f ($distinctWorkRepoRoots -join ', '))
    }

    $runRootPolicy = $externalRunRootPairs[0].Policy
    $runRootWorkRepoRoot = [string]$distinctWorkRepoRoots[0]
}
elseif ($pairRows.Count -gt 0) {
    $runRootPolicy = $pairRows[0].Policy
}

$RunRoot = Resolve-PairRunRootPath `
    -Root $root `
    -RunRoot $RunRoot `
    -PairTest $pairTest `
    -PairPolicy $runRootPolicy `
    -WorkRepoRoot $runRootWorkRepoRoot

foreach ($pairRow in @($pairRows)) {
    Assert-RunRootPolicy `
        -PairTest $pairTest `
        -PairPolicy $pairRow.Policy `
        -AutomationRoot $root `
        -RunRoot $RunRoot `
        -WorkRepoRoot ([string]$pairRow.PairWorkRepoRoot)

    Assert-BookkeepingRootsPolicy `
        -Config $config `
        -PairTest $pairTest `
        -PairPolicy $pairRow.Policy `
        -AutomationRoot $root `
        -BasePath $root `
        -WorkRepoRoot ([string]$pairRow.PairWorkRepoRoot)
}

Ensure-Directory -Path $RunRoot
$messagesRoot = Join-Path $RunRoot ([string]$pairTest.MessageFolderName)
Ensure-Directory -Path $messagesRoot

$targetFolderMap = @{}
$targetContractPathMap = @{}

foreach ($pair in @($selectedPairs)) {
    $pairId = [string]$pair.PairId
    $pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId $pairId
    $pairWorkRepoRoot = Resolve-PairWorkRepoRoot -PairPolicy $pairPolicy -ExplicitSeedWorkRepoRoot $SeedWorkRepoRoot
    $pairUsesExternalContractPaths = Test-UseExternalWorkRepoContractPaths -PairTest $pairTest -PairPolicy $pairPolicy -PairWorkRepoRoot $pairWorkRepoRoot
    $pairActivationSummary += @(Assert-PairActivationEnabled -Root $root -Config $config -PairId $pairId)
    $pairRoot = Join-Path $RunRoot $pairId
    Ensure-Directory -Path $pairRoot

    foreach ($entry in @(
        [pscustomobject]@{ TargetId = [string]$pair.TopTargetId; RoleName = 'top' }
        [pscustomobject]@{ TargetId = [string]$pair.BottomTargetId; RoleName = 'bottom' }
    )) {
        $targetRoot = Join-Path $pairRoot ([string]$entry.TargetId)
        $reviewRoot = Join-Path $targetRoot ([string]$pairTest.ReviewFolderName)
        $workRoot = Join-Path $targetRoot ([string]$pairTest.WorkFolderName)
        $contractPaths = Get-TargetSourceContractPaths `
            -PairTest $pairTest `
            -PairPolicy $pairPolicy `
            -RunRoot $RunRoot `
            -PairId $pairId `
            -TargetId ([string]$entry.TargetId) `
            -TargetFolder $targetRoot `
            -PairWorkRepoRoot $pairWorkRepoRoot
        $sourceOutboxRoot = [string]$contractPaths.SourceOutboxPath
        $publishedArchiveRoot = [string]$contractPaths.PublishedArchivePath
        Ensure-Directory -Path $targetRoot
        Ensure-Directory -Path $reviewRoot
        Ensure-Directory -Path $workRoot
        Ensure-Directory -Path $sourceOutboxRoot
        Ensure-Directory -Path $publishedArchiveRoot
        $targetFolderMap[[string]$entry.TargetId] = $targetRoot
        $targetContractPathMap[($pairId + '|' + [string]$entry.TargetId)] = $contractPaths
    }

}

$externalContractPathsValidated = $false
if (@($pairRows | Where-Object { [bool]$_.UseExternalWorkRepoContractPaths }).Count -gt 0) {
    Assert-ExternalContractPathValidation -PairRows $pairRows -TargetContractPathMap $targetContractPathMap
    $externalContractPathsValidated = $true
}

$messageFiles = @()
$oneTimeQueueStateByPair = @{}
foreach ($pair in $pairRows) {
    $oneTimeQueueStateByPair[[string]$pair.PairId] = Get-OneTimeQueueDocument -Root $root -Config $config -PairId ([string]$pair.PairId)
}

foreach ($pair in $pairRows) {
    foreach ($entry in @(
        [pscustomobject]@{
            PairId          = [string]$pair.PairId
            RoleName        = 'top'
            TargetId        = [string]$pair.TopTargetId
            PartnerTargetId = [string]$pair.BottomTargetId
        }
        [pscustomobject]@{
            PairId          = [string]$pair.PairId
            RoleName        = 'bottom'
            TargetId        = [string]$pair.BottomTargetId
            PartnerTargetId = [string]$pair.TopTargetId
        }
    )) {
        $pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId ([string]$entry.PairId)
        $isSeedTarget = ([string]$entry.TargetId -in $requestedSeedTargetIds)
        $targetSeedContext = Resolve-TargetSeedContext `
            -PairTest $pairTest `
            -PairPolicy $pairPolicy `
            -IsSeedTarget $isSeedTarget `
            -ExplicitSeedWorkRepoRoot $SeedWorkRepoRoot `
            -ExplicitSeedReviewInputPath $SeedReviewInputPath `
            -ExplicitSeedTaskText $resolvedSeedTaskText
        $initialRoleMode = if ($isSeedTarget) { 'seed' } else { 'handoff_wait' }
        $targetWorkRepoRoot = [string]$targetSeedContext.WorkRepoRoot
        $effectiveTargetWorkRepoRoot = if (Test-NonEmptyString $targetWorkRepoRoot) {
            $targetWorkRepoRoot
        }
        elseif ([bool]$pair.UseExternalWorkRepoContractPaths -and (Test-NonEmptyString ([string]$pair.PairWorkRepoRoot))) {
            [string]$pair.PairWorkRepoRoot
        }
        else {
            ''
        }
        $targetReviewInputPath = [string]$targetSeedContext.ReviewInputPath
        $targetSeedTaskText = [string]$targetSeedContext.SeedTaskText
        $targetReviewInputSelection = $targetSeedContext.ReviewInputSelection
        if ($isSeedTarget) {
            Assert-SeedWorkRepoPolicy `
                -PairTest $pairTest `
                -PairPolicy $pairPolicy `
                -AutomationRoot $root `
                -WorkRepoRoot $effectiveTargetWorkRepoRoot `
                -ReviewInputPath $targetReviewInputPath
        }
        $targetFolder = [string]$targetFolderMap[[string]$entry.TargetId]
        $partnerFolder = [string]$targetFolderMap[[string]$entry.PartnerTargetId]
        $contractKey = ([string]$entry.PairId + '|' + [string]$entry.TargetId)
        $partnerContractKey = ([string]$entry.PairId + '|' + [string]$entry.PartnerTargetId)
        $contractPaths = $targetContractPathMap[$contractKey]
        $partnerContractPaths = $targetContractPathMap[$partnerContractKey]
        $summaryPath = Join-Path $targetFolder ([string]$pairTest.SummaryFileName)
        $reviewFolderPath = Join-Path $targetFolder ([string]$pairTest.ReviewFolderName)
        $doneFilePath = Join-Path $targetFolder ([string]$pairTest.HeadlessExec.DoneFileName)
        $errorFilePath = Join-Path $targetFolder ([string]$pairTest.HeadlessExec.ErrorFileName)
        $resultFilePath = Join-Path $targetFolder ([string]$pairTest.HeadlessExec.ResultFileName)
        $outputLastMessagePath = Join-Path $targetFolder ([string]$pairTest.HeadlessExec.OutputLastMessageFileName)
        $headlessPromptFilePath = Join-Path $targetFolder ([string]$pairTest.HeadlessExec.PromptFileName)
        $workFolderPath = Join-Path $targetFolder ([string]$pairTest.WorkFolderName)
        $sourceOutboxPath = [string]$contractPaths.SourceOutboxPath
        $sourceSummaryPath = [string]$contractPaths.SourceSummaryPath
        $sourceReviewZipPath = [string]$contractPaths.SourceReviewZipPath
        $publishReadyPath = [string]$contractPaths.PublishReadyPath
        $publishedArchivePath = [string]$contractPaths.PublishedArchivePath
        $contractPathMode = [string]$contractPaths.ContractPathMode
        $contractRootPath = [string]$contractPaths.ContractRootPath
        $partnerSourceOutboxPath = [string]$partnerContractPaths.SourceOutboxPath
        $partnerSourceSummaryPath = [string]$partnerContractPaths.SourceSummaryPath
        $partnerSourceReviewZipPath = [string]$partnerContractPaths.SourceReviewZipPath
        $availableReviewInputPaths = @()
        foreach ($candidate in @($partnerSourceSummaryPath, $partnerSourceReviewZipPath, $targetReviewInputPath)) {
            if (-not (Test-NonEmptyString $candidate)) {
                continue
            }
            if (-not (Test-Path -LiteralPath $candidate)) {
                continue
            }
            $availableReviewInputPaths += [System.IO.Path]::GetFullPath($candidate)
        }
        $availableReviewInputPaths = @($availableReviewInputPaths | Select-Object -Unique)
        $automationPaths = Write-TargetAutomationScripts `
            -Root $root `
            -ResolvedConfigPath $resolvedConfigPath `
            -RunRoot $RunRoot `
            -PairTest $pairTest `
            -TargetFolder $targetFolder `
            -TargetId ([string]$entry.TargetId)
        $queueState = $oneTimeQueueStateByPair[[string]$entry.PairId]
        $initialOneTimeItems = if ($null -ne $queueState) {
            @(Get-ApplicableOneTimeQueueItems `
                -QueueDocument $queueState.Document `
                -PairId ([string]$entry.PairId) `
                -RoleName ([string]$entry.RoleName) `
                -TargetId ([string]$entry.TargetId) `
                -MessageType 'initial')
        }
        else {
            @()
        }
        $effectiveInitialOneTimeItems = if ($isSeedTarget) { @($initialOneTimeItems) } else { @() }
        $instructionText = Get-TargetInstructionText `
            -PairTest $pairTest `
            -PairId ([string]$entry.PairId) `
            -RoleName ([string]$entry.RoleName) `
            -TargetId ([string]$entry.TargetId) `
            -PartnerTargetId ([string]$entry.PartnerTargetId) `
            -TargetFolder $targetFolder `
            -PartnerFolder $partnerFolder `
            -PartnerSourceSummaryPath $partnerSourceSummaryPath `
            -PartnerSourceReviewZipPath $partnerSourceReviewZipPath `
            -SummaryPath $summaryPath `
            -ReviewFolderPath $reviewFolderPath `
            -DoneFilePath $doneFilePath `
            -ResultFilePath $resultFilePath `
            -WorkFolderPath $workFolderPath `
            -SourceOutboxPath $sourceOutboxPath `
            -SourceSummaryPath $sourceSummaryPath `
            -SourceReviewZipPath $sourceReviewZipPath `
            -PublishReadyPath $publishReadyPath `
            -PublishedArchivePath $publishedArchivePath `
            -CheckScriptPath ([string]$automationPaths.CheckScriptPath) `
            -SubmitScriptPath ([string]$automationPaths.SubmitScriptPath) `
            -CheckCmdPath ([string]$automationPaths.CheckCmdPath) `
            -SubmitCmdPath ([string]$automationPaths.SubmitCmdPath) `
            -InitialRoleMode $initialRoleMode `
            -WorkRepoRoot $effectiveTargetWorkRepoRoot `
            -ReviewInputPath $targetReviewInputPath `
            -SeedTaskText $targetSeedTaskText `
            -OneTimeItems $effectiveInitialOneTimeItems

        $instructionPath = Join-Path $targetFolder 'instructions.txt'
        [System.IO.File]::WriteAllText($instructionPath, $instructionText, (New-Utf8NoBomEncoding))

        $messageText = Get-TargetInitialSeedMessageText `
            -PairTest $pairTest `
            -PairId ([string]$entry.PairId) `
            -RoleName ([string]$entry.RoleName) `
            -TargetId ([string]$entry.TargetId) `
            -PartnerTargetId ([string]$entry.PartnerTargetId) `
            -InitialRoleMode $initialRoleMode `
            -InstructionPath $instructionPath `
            -TargetFolder $targetFolder `
            -PartnerFolder $partnerFolder `
            -PartnerSourceSummaryPath $partnerSourceSummaryPath `
            -PartnerSourceReviewZipPath $partnerSourceReviewZipPath `
            -SourceOutboxPath $sourceOutboxPath `
            -SourceSummaryPath $sourceSummaryPath `
            -SourceReviewZipPath $sourceReviewZipPath `
            -PublishReadyPath $publishReadyPath `
            -WorkRepoRoot $effectiveTargetWorkRepoRoot `
            -ReviewInputPath $targetReviewInputPath `
            -SeedTaskText $targetSeedTaskText `
            -OneTimeItems $effectiveInitialOneTimeItems
        Assert-RelayPayloadBudget -Config $config -TargetId ([string]$entry.TargetId) -Body $messageText

        $messagePath = Join-Path $messagesRoot ([string]$entry.TargetId + '.txt')
        [System.IO.File]::WriteAllText($messagePath, $messageText, (New-Utf8NoBomEncoding))
        $messageType = switch ($initialRoleMode) {
            'seed' { 'pair-seed' }
            'handoff_wait' { 'pair-handoff-wait' }
            default { 'pair-initial' }
        }
        $messageMetadata = New-PairedRelayMessageMetadata `
            -RunRoot $RunRoot `
            -PairId ([string]$entry.PairId) `
            -TargetId ([string]$entry.TargetId) `
            -PartnerTargetId ([string]$entry.PartnerTargetId) `
            -RoleName ([string]$entry.RoleName) `
            -InitialRoleMode $initialRoleMode `
            -MessageType $messageType `
            -MessagePath $messagePath
        $messageMetadataPath = Write-RelayMessageMetadata -MessagePath $messagePath -Metadata $messageMetadata

        $requestPath = Join-Path $targetFolder ([string]$pairTest.HeadlessExec.RequestFileName)
        $requestCreatedAt = (Get-Date).ToString('o')
        $requestPayload = [pscustomobject]@{
            CreatedAt              = $requestCreatedAt
            PairId                 = [string]$entry.PairId
            RoleName               = [string]$entry.RoleName
            TargetId               = [string]$entry.TargetId
            PartnerTargetId        = [string]$entry.PartnerTargetId
            OwnTargetFolder        = $targetFolder
            PartnerTargetFolder    = $partnerFolder
            TargetFolder           = $targetFolder
            PartnerFolder          = $partnerFolder
            InstructionPath        = $instructionPath
            MessagePath            = $messagePath
            MessageMetadataPath    = $messageMetadataPath
            ReviewInputFiles       = [pscustomobject]@{
                PartnerSummaryPath      = $partnerSourceSummaryPath
                PartnerReviewZipPath    = $partnerSourceReviewZipPath
                ExternalReviewInputPath = $targetReviewInputPath
                AvailablePaths          = @($availableReviewInputPaths)
                HasAny                  = [bool]($availableReviewInputPaths.Count -gt 0)
            }
            OutputFiles            = [pscustomobject]@{
                SummaryPath      = $sourceSummaryPath
                ReviewZipPath    = $sourceReviewZipPath
                PublishReadyPath = $publishReadyPath
            }
            SummaryPath            = $summaryPath
            ReviewFolderPath       = $reviewFolderPath
            SummaryFileName        = [string]$pairTest.SummaryFileName
            ReviewFolderName       = [string]$pairTest.ReviewFolderName
            WorkFolderName         = [string]$pairTest.WorkFolderName
            WorkFolderPath         = $workFolderPath
            SourceOutboxFolderName = [string]$pairTest.SourceOutboxFolderName
            SourceSummaryFileName  = [string]$pairTest.SourceSummaryFileName
            SourceReviewZipFileName = [string]$pairTest.SourceReviewZipFileName
            PublishReadyFileName   = [string]$pairTest.PublishReadyFileName
            PublishedArchiveFolderName = [string]$pairTest.PublishedArchiveFolderName
            SourceOutboxPath       = $sourceOutboxPath
            SourceSummaryPath      = $sourceSummaryPath
            SourceReviewZipPath    = $sourceReviewZipPath
            PublishReadyPath       = $publishReadyPath
            PublishedArchivePath   = $publishedArchivePath
            ContractPathMode       = $contractPathMode
            ContractRootPath       = $contractRootPath
            ContractReferenceTimeUtc = $requestCreatedAt
            SeedEnabled            = [bool]$isSeedTarget
            SeedTargetId           = $seedTargetId
            SeedTargetIds          = @($requestedSeedTargetIds)
            InitialRoleMode        = $initialRoleMode
            PairPolicy             = $pairPolicy
            WorkRepoRoot           = $effectiveTargetWorkRepoRoot
            ReviewInputPath        = $targetReviewInputPath
            ReviewInputSelectionMode = if ($isSeedTarget) { [string]$targetReviewInputSelection.SelectionMode } else { '' }
            ReviewInputSearchRoot  = if ($isSeedTarget) { [string]$targetReviewInputSelection.SearchRoot } else { '' }
            ReviewInputCandidateCount = if ($isSeedTarget) { [int]$targetReviewInputSelection.CandidateCount } else { 0 }
            ReviewInputSelectedLastWriteTimeUtc = if ($isSeedTarget) { [string]$targetReviewInputSelection.SelectedLastWriteTimeUtc } else { '' }
            ReviewInputSelectionWarning = if ($isSeedTarget) { [string]$targetReviewInputSelection.RejectionReason } else { '' }
            SeedTaskText           = $targetSeedTaskText
            ReviewZipPattern       = [string]$pairTest.ReviewZipPattern
            RequestFilePath        = $requestPath
            CheckScriptPath        = [string]$automationPaths.CheckScriptPath
            SubmitScriptPath       = [string]$automationPaths.SubmitScriptPath
            CheckCmdPath           = [string]$automationPaths.CheckCmdPath
            SubmitCmdPath          = [string]$automationPaths.SubmitCmdPath
            DoneFilePath           = $doneFilePath
            ErrorFilePath          = $errorFilePath
            ResultFilePath         = $resultFilePath
            OutputLastMessagePath  = $outputLastMessagePath
            HeadlessPromptFilePath = $headlessPromptFilePath
            PendingOneTimeItemIds  = @($initialOneTimeItems | ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'Id' -DefaultValue '') } | Where-Object { Test-NonEmptyString $_ })
        }
        $requestPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -Encoding UTF8

        $messageFiles += [pscustomobject]@{
            PairId          = [string]$entry.PairId
            RoleName        = [string]$entry.RoleName
            TargetId        = [string]$entry.TargetId
            PartnerTargetId = [string]$entry.PartnerTargetId
            OwnTargetFolder = $targetFolder
            PartnerTargetFolder = $partnerFolder
            TargetFolder    = $targetFolder
            PartnerFolder   = $partnerFolder
            ReviewInputFiles = [pscustomobject]@{
                PartnerSummaryPath      = $partnerSourceSummaryPath
                PartnerReviewZipPath    = $partnerSourceReviewZipPath
                ExternalReviewInputPath = $targetReviewInputPath
                AvailablePaths          = @($availableReviewInputPaths)
                HasAny                  = [bool]($availableReviewInputPaths.Count -gt 0)
            }
            OutputFiles = [pscustomobject]@{
                SummaryPath      = $sourceSummaryPath
                ReviewZipPath    = $sourceReviewZipPath
                PublishReadyPath = $publishReadyPath
            }
            SummaryPath     = $summaryPath
            ReviewFolderPath = $reviewFolderPath
            WorkFolderPath  = $workFolderPath
            SourceOutboxPath = $sourceOutboxPath
            SourceSummaryPath = $sourceSummaryPath
            SourceReviewZipPath = $sourceReviewZipPath
            PublishReadyPath = $publishReadyPath
            PublishedArchivePath = $publishedArchivePath
            ContractPathMode = $contractPathMode
            ContractRootPath = $contractRootPath
            ContractReferenceTimeUtc = $requestCreatedAt
            SeedEnabled     = [bool]$isSeedTarget
            SeedTargetId    = $seedTargetId
            SeedTargetIds   = @($requestedSeedTargetIds)
            InitialRoleMode = $initialRoleMode
            PairPolicy      = $pairPolicy
            WorkRepoRoot    = $effectiveTargetWorkRepoRoot
            ReviewInputPath = $targetReviewInputPath
            ReviewInputSelectionMode = if ($isSeedTarget) { [string]$targetReviewInputSelection.SelectionMode } else { '' }
            ReviewInputSearchRoot = if ($isSeedTarget) { [string]$targetReviewInputSelection.SearchRoot } else { '' }
            ReviewInputCandidateCount = if ($isSeedTarget) { [int]$targetReviewInputSelection.CandidateCount } else { 0 }
            ReviewInputSelectedLastWriteTimeUtc = if ($isSeedTarget) { [string]$targetReviewInputSelection.SelectedLastWriteTimeUtc } else { '' }
            ReviewInputSelectionWarning = if ($isSeedTarget) { [string]$targetReviewInputSelection.RejectionReason } else { '' }
            SeedTaskText    = $targetSeedTaskText
            CheckScriptPath = [string]$automationPaths.CheckScriptPath
            SubmitScriptPath = [string]$automationPaths.SubmitScriptPath
            CheckCmdPath    = [string]$automationPaths.CheckCmdPath
            SubmitCmdPath   = [string]$automationPaths.SubmitCmdPath
            MessagePath     = $messagePath
            MessageMetadataPath = $messageMetadataPath
            RequestPath     = $requestPath
            PendingOneTimeItemIds = @($effectiveInitialOneTimeItems | ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'Id' -DefaultValue '') } | Where-Object { Test-NonEmptyString $_ })
        }
    }
}

$bookkeepingExternalized = ($externalRunRootPairs.Count -gt 0)
$fullExternalized = (($bookkeepingExternalized) -and (@($pairRows | Where-Object { [bool]$_.UseExternalWorkRepoContractPaths }).Count -gt 0))

$manifest = [pscustomobject]@{
    CreatedAt  = (Get-Date).ToString('o')
    RunRoot    = $RunRoot
    ConfigPath = $resolvedConfigPath
    ExternalWorkRepoUsed = [bool](@($pairRows | Where-Object { Test-NonEmptyString ([string]$_.PairWorkRepoRoot) }).Count -gt 0)
    PrimaryContractExternalized = [bool](@($pairRows | Where-Object { [bool]$_.UseExternalWorkRepoContractPaths }).Count -gt 0)
    ExternalRunRootUsed = [bool](@($pairRows | Where-Object { [bool]$_.UseExternalWorkRepoRunRoot }).Count -gt 0)
    BookkeepingExternalized = [bool]$bookkeepingExternalized
    FullExternalized = [bool]$fullExternalized
    ExternalContractPathsValidated = $externalContractPathsValidated
    RunRootPathValidated = $true
    InternalResidualRoots = @(Get-BookkeepingResidualRootsEvidence -Config $config -BasePath $root)
    PairTest   = $pairTest
    PairActivationSummary = @($pairActivationSummary)
    SeedTargetId = $seedTargetId
    SeedTargetIds = @($requestedSeedTargetIds)
    SeedWorkRepoRoot = $resolvedSeedWorkRepoRoot
    SeedReviewInputPath = $resolvedSeedReviewInputPath
    SeedReviewInputSelection = $seedReviewSelection
    SeedTaskText = $resolvedSeedTaskText
    Pairs      = @($pairRows)
    Targets    = @($messageFiles)
}

$manifestPath = Join-Path $RunRoot 'manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "prepared pair test root: $RunRoot"
Write-Host "manifest: $manifestPath"

foreach ($item in $messageFiles | Sort-Object TargetId) {
    Write-Host ("prepared {0} pair={1} role={2} folder={3}" -f $item.TargetId, $item.PairId, $item.RoleName, $item.TargetFolder)
}

if ($SendInitialMessages) {
    if ($UseHeadlessDispatch -and -not [bool]$pairTest.HeadlessExec.Enabled) {
        throw "headless dispatch requested but HeadlessExec.Enabled is false in config: $resolvedConfigPath"
    }

    $initialTargets = if ($requestedSeedTargetIds.Count -gt 0) {
        $requestedInitialTargetSet = @{}
        foreach ($targetId in $requestedSeedTargetIds) {
            $requestedInitialTargetSet[$targetId] = $true
        }

        $selected = @($messageFiles | Where-Object { $requestedInitialTargetSet.ContainsKey([string]$_.TargetId) } | Sort-Object TargetId)
        $selectedTargetIds = @($selected | ForEach-Object { [string]$_.TargetId })
        $missingTargetIds = @($requestedSeedTargetIds | Where-Object { $_ -notin $selectedTargetIds })
        if ($missingTargetIds.Count -gt 0) {
            throw ("initial target id(s) not found in prepared run: " + ($missingTargetIds -join ', '))
        }

        $selected
    }
    else {
        @($messageFiles | Sort-Object TargetId)
    }

    $headlessLogRoot = Join-Path $RunRoot '.state\headless-initial'
    if ($UseHeadlessDispatch) {
        Ensure-Directory -Path $headlessLogRoot
    }

    foreach ($item in $initialTargets) {
        if ($UseHeadlessDispatch) {
            $logPath = Join-Path $headlessLogRoot ("initial_{0}_{1}.log" -f [string]$item.TargetId, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
            Invoke-InitialHeadlessTurn `
                -Root $root `
                -ConfigPath $resolvedConfigPath `
                -RunRoot $RunRoot `
                -TargetId ([string]$item.TargetId) `
                -PromptFilePath ([string]$item.MessagePath) `
                -LogPath $logPath

            $pendingOneTimeItemIds = @($item.PendingOneTimeItemIds | Where-Object { Test-NonEmptyString $_ })
            if ($pendingOneTimeItemIds.Count -gt 0) {
                [void](Complete-OneTimeQueueItems `
                    -Root $root `
                    -Config $config `
                    -PairId ([string]$item.PairId) `
                    -ItemIds $pendingOneTimeItemIds `
                    -IgnoreMissing)
            }

            Write-Host ("headless initial turn completed for {0} log={1}" -f $item.TargetId, $logPath)
        }
        else {
            & (Join-Path $root 'producer-example.ps1') `
                -ConfigPath $resolvedConfigPath `
                -TargetId ([string]$item.TargetId) `
                -TextFilePath ([string]$item.MessagePath) | Out-Null

            Write-Host ("queued initial instruction for {0}" -f $item.TargetId)
        }
    }

    if ($requestedSeedTargetIds.Count -gt 0) {
        Write-Host ("initial targets limited to: {0}" -f ($requestedSeedTargetIds -join ', '))
    }
}
else {
    Write-Host 'initial messages were not sent.'
    Write-Host ("send later: pwsh -NoProfile -ExecutionPolicy Bypass -File {0} -ConfigPath {1} -RunRoot {2} [-TargetId target01]" -f `
        (Join-Path $root 'tests\Send-InitialPairSeed.ps1'), `
        $resolvedConfigPath, `
        $RunRoot)
    Write-Host ("safe reseed later: pwsh -NoProfile -ExecutionPolicy Bypass -File {0} -ConfigPath {1} -RunRoot {2} [-TargetId target01] [-MaxAttempts 3] [-DelaySeconds 5]" -f `
        (Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1'), `
        $resolvedConfigPath, `
        $RunRoot)
}

Write-Host ("watch later: pwsh -NoProfile -ExecutionPolicy Bypass -File {0} -ConfigPath {1} -RunRoot {2}" -f `
    (Join-Path $root 'tests\Watch-PairedExchange.ps1'), `
    $resolvedConfigPath, `
    $RunRoot)
