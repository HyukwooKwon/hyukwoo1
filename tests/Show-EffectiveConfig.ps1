[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string[]]$PairId,
    [string]$TargetId,
    [ValidateSet('both', 'initial', 'handoff')][string]$Mode = 'both',
    [int]$StaleRunThresholdSec = 1800,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PathLastWriteAt {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    return (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTime.ToString('o')
}

function Get-PathAgeSeconds {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [math]::Round(((Get-Date) - $item.LastWriteTime).TotalSeconds, 3)
}

function Test-ExistingLiteralPathSafe {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path)) {
        return $false
    }

    try {
        return [bool](Test-Path -LiteralPath $Path)
    }
    catch {
        return $false
    }
}

function Get-FileHashHex {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function New-WarningRecord {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Severity,
        [Parameter(Mandatory)][string]$Message,
        [string]$Decision = 'review',
        [int]$Priority = 100,
        [bool]$BlocksOperations = $false,
        [bool]$BlocksEvidence = $false
    )

    return [pscustomobject]@{
        Code = $Code
        Severity = $Severity
        Message = $Message
        Decision = $Decision
        Priority = $Priority
        BlocksOperations = $BlocksOperations
        BlocksEvidence = $BlocksEvidence
    }
}

function Get-WarningSeverityRank {
    param([string]$Severity)

    switch ($Severity) {
        'error' { return 3 }
        'warning' { return 2 }
        'info' { return 1 }
        default { return 0 }
    }
}

function Get-WarningDecisionRank {
    param([string]$Decision)

    switch ($Decision) {
        'block' { return 3 }
        'review' { return 2 }
        'info' { return 1 }
        default { return 0 }
    }
}

function Get-WarningPolicy {
    return @{
        'runroot-missing' = [pscustomobject]@{
            Severity = 'warning'
            Decision = 'review'
            Priority = 10
            BlocksOperations = $false
            BlocksEvidence = $true
        }
        'runroot-next-preview' = [pscustomobject]@{
            Severity = 'warning'
            Decision = 'review'
            Priority = 20
            BlocksOperations = $false
            BlocksEvidence = $true
        }
        'manifest-missing' = [pscustomobject]@{
            Severity = 'warning'
            Decision = 'review'
            Priority = 30
            BlocksOperations = $false
            BlocksEvidence = $true
        }
        'pair-definition-fallback' = [pscustomobject]@{
            Severity = 'warning'
            Decision = 'review'
            Priority = 40
            BlocksOperations = $false
            BlocksEvidence = $true
        }
        'runroot-stale' = [pscustomobject]@{
            Severity = 'warning'
            Decision = 'review'
            Priority = 50
            BlocksOperations = $false
            BlocksEvidence = $true
        }
        'runroot-latest-existing' = [pscustomobject]@{
            Severity = 'warning'
            Decision = 'review'
            Priority = 60
            BlocksOperations = $false
            BlocksEvidence = $false
        }
    }
}

function New-PolicyWarningRecord {
    param(
        [Parameter(Mandatory)][hashtable]$PolicyMap,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )

    $policy = $PolicyMap[$Code]
    if ($null -eq $policy) {
        throw ("missing warning policy for code: " + $Code)
    }

    return New-WarningRecord `
        -Code $Code `
        -Severity ([string]$policy.Severity) `
        -Message $Message `
        -Decision ([string]$policy.Decision) `
        -Priority ([int]$policy.Priority) `
        -BlocksOperations ([bool]$policy.BlocksOperations) `
        -BlocksEvidence ([bool]$policy.BlocksEvidence)
}

function Get-WarningSummary {
    param($WarningRecords)

    $ordered = @($WarningRecords | Sort-Object Priority, Code)
    if ($ordered.Count -eq 0) {
        return [pscustomobject]@{
            HighestSeverity = 'none'
            HighestDecision = 'none'
            HighestCode = ''
            HighestPriority = $null
            BlockingCount = 0
            EvidenceRiskCount = 0
            WarningCount = 0
            OrderedCodes = @()
        }
    }

    $highestSeverity = ($ordered | Sort-Object @{ Expression = { -(Get-WarningSeverityRank -Severity ([string]$_.Severity)) } }, Priority | Select-Object -First 1)
    $highestDecision = ($ordered | Sort-Object @{ Expression = { -(Get-WarningDecisionRank -Decision ([string]$_.Decision)) } }, Priority | Select-Object -First 1)

    return [pscustomobject]@{
        HighestSeverity = [string]$highestSeverity.Severity
        HighestDecision = [string]$highestDecision.Decision
        HighestCode = [string]$ordered[0].Code
        HighestPriority = [int]$ordered[0].Priority
        BlockingCount = @($ordered | Where-Object { [bool]$_.BlocksOperations }).Count
        EvidenceRiskCount = @($ordered | Where-Object { [bool]$_.BlocksEvidence }).Count
        WarningCount = $ordered.Count
        OrderedCodes = @($ordered | ForEach-Object { [string]$_.Code })
    }
}

function Resolve-LatestExistingRunRoot {
    param([Parameter(Mandatory)]$PairTest)

    $runRootBase = [string]$PairTest.RunRootBase
    if (-not (Test-Path -LiteralPath $runRootBase)) {
        return ''
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $runRootBase -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $manifestPath = Join-Path $_.FullName 'manifest.json'
                [pscustomobject]@{
                    FullName = $_.FullName
                    LastWriteTimeUtc = $_.LastWriteTimeUtc
                    HasManifest = [bool](Test-Path -LiteralPath $manifestPath)
                }
            }
    )

    if ($candidates.Count -eq 0) {
        return ''
    }

    $latest = $candidates |
        Sort-Object `
            @{ Expression = { if ([bool]$_.HasManifest) { 0 } else { 1 } } }, `
            @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true } |
        Select-Object -First 1

    if ($null -eq $latest) {
        return ''
    }

    return $latest.FullName
}

function Resolve-DisplayRunContext {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$PairTest,
        [string]$RequestedRunRoot
    )

    $requested = ''
    if (Test-NonEmptyString $RequestedRunRoot) {
        $requested = Resolve-PairRunRootPath -Root $Root -RunRoot $RequestedRunRoot -PairTest $PairTest
    }

    $latestExisting = Resolve-LatestExistingRunRoot -PairTest $PairTest
    $nextPreview = Resolve-PairRunRootPath -Root $Root -RunRoot '' -PairTest $PairTest
    $selected = ''
    $selectedSource = 'none'

    if (Test-NonEmptyString $requested) {
        $selected = $requested
        $selectedSource = 'requested'
    }
    elseif (Test-NonEmptyString $latestExisting) {
        $selected = $latestExisting
        $selectedSource = 'latest-existing'
    }
    else {
        $selected = $nextPreview
        $selectedSource = 'next-preview'
    }

    $manifestPath = Join-Path $selected 'manifest.json'
    $manifestExists = Test-Path -LiteralPath $manifestPath
    $manifest = $null
    if ($manifestExists) {
        $manifest = ConvertFrom-RelayJsonText -Json (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8)
    }

    return [pscustomobject]@{
        RequestedRunRoot = $requested
        RequestedRunRootExists = if (Test-NonEmptyString $requested) { [bool](Test-Path -LiteralPath $requested) } else { $false }
        LatestExistingRunRoot = $latestExisting
        LatestExistingRunRootLastWriteAt = (Get-PathLastWriteAt -Path $latestExisting)
        NextRunRootPreview = $nextPreview
        SelectedRunRoot = $selected
        SelectedRunRootSource = $selectedSource
        SelectedRunRootExists = if (Test-NonEmptyString $selected) { [bool](Test-Path -LiteralPath $selected) } else { $false }
        SelectedRunRootLastWriteAt = (Get-PathLastWriteAt -Path $selected)
        SelectedRunRootAgeSeconds = (Get-PathAgeSeconds -Path $selected)
        ManifestPath = $manifestPath
        ManifestExists = [bool]$manifestExists
        Manifest = $manifest
    }
}

function Resolve-PairDefinitions {
    param(
        [Parameter(Mandatory)]$PairTest,
        $Manifest = $null,
        [string[]]$RequestedPairIds = @(),
        [string]$RequestedTargetId = ''
    )

    $pairSet = if ($null -ne $Manifest -and $null -ne $Manifest.Pairs -and @($Manifest.Pairs).Count -gt 0) {
        Resolve-ConfiguredPairDefinitions -Source $Manifest -SourceLabel 'manifest'
    }
    else {
        [pscustomobject]@{
            Source = [string](Get-ConfigValue -Object $PairTest -Name 'PairDefinitionSource' -DefaultValue 'fallback')
            Pairs = @($PairTest.PairDefinitions)
        }
    }

    return [pscustomobject]@{
        Source = [string]$pairSet.Source
        Pairs = @(Select-PairDefinitions -PairDefinitions @($pairSet.Pairs) -IncludePairId $RequestedPairIds -TargetId $RequestedTargetId)
    }
}

function Get-ConfigTargetMap {
    param($Config)

    $map = @{}
    foreach ($target in @($Config.Targets)) {
        $targetId = [string](Get-ConfigValue -Object $target -Name 'Id' -DefaultValue '')
        if (Test-NonEmptyString $targetId) {
            $map[$targetId] = $target
        }
    }

    return $map
}

function Get-TemplateMergeDetails {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TemplateName,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$TargetId
    )

    $messageTemplates = Get-ConfigValue -Object $PairTest -Name 'MessageTemplates' -DefaultValue @{}
    $template = Get-ConfigValue -Object $messageTemplates -Name $TemplateName -DefaultValue @{}
    $pairOverrides = Get-ConfigValue -Object $PairTest -Name 'PairOverrides' -DefaultValue @{}
    $roleOverrides = Get-ConfigValue -Object $PairTest -Name 'RoleOverrides' -DefaultValue @{}
    $targetOverrides = Get-ConfigValue -Object $PairTest -Name 'TargetOverrides' -DefaultValue @{}
    $extraPropertyName = ($TemplateName + 'ExtraBlocks')

    $pairSource = Get-ConfigValue -Object $pairOverrides -Name $PairId -DefaultValue $null
    $roleSource = Get-ConfigValue -Object $roleOverrides -Name $RoleName -DefaultValue $null
    $targetSource = Get-ConfigValue -Object $targetOverrides -Name $TargetId -DefaultValue $null

    $pairBlocks = @(Get-StringArray (Get-ConfigValue -Object $pairSource -Name $extraPropertyName -DefaultValue @()))
    $roleBlocks = @(Get-StringArray (Get-ConfigValue -Object $roleSource -Name $extraPropertyName -DefaultValue @()))
    $targetBlocks = @(Get-StringArray (Get-ConfigValue -Object $targetSource -Name $extraPropertyName -DefaultValue @()))

    $appliedSources = New-Object System.Collections.Generic.List[string]
    if ($pairBlocks.Count -gt 0) {
        $appliedSources.Add(('pair:' + $PairId))
    }
    if ($roleBlocks.Count -gt 0) {
        $appliedSources.Add(('role:' + $RoleName))
    }
    if ($targetBlocks.Count -gt 0) {
        $appliedSources.Add(('target:' + $TargetId))
    }

    return [pscustomobject]@{
        SlotOrder = @(Get-StringArray (Get-ConfigValue -Object $template -Name 'SlotOrder' -DefaultValue (Get-DefaultMessageSlotOrder -TemplateName $TemplateName)))
        PrefixBlocks = @(Get-StringArray (Get-ConfigValue -Object $template -Name 'PrefixBlocks' -DefaultValue @()))
        SuffixBlocks = @(Get-StringArray (Get-ConfigValue -Object $template -Name 'SuffixBlocks' -DefaultValue @()))
        ExtraBlocks = @($pairBlocks + $roleBlocks + $targetBlocks)
        Sources = [pscustomobject]@{
            Pair = @($pairBlocks)
            Role = @($roleBlocks)
            Target = @($targetBlocks)
            Applied = @($appliedSources)
        }
    }
}

function Get-ReviewZipPreviewName {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$TargetId
    )

    return [regex]::Replace($Pattern, '\{([^}]+)\}', {
        param($match)

        $token = [string]$match.Groups[1].Value
        if ($token -eq 'TargetId') {
            return $TargetId
        }

        return ('<' + $token + '>')
    })
}

function New-MessagePlanBlock {
    param(
        [Parameter(Mandatory)][int]$Order,
        [Parameter(Mandatory)][string]$Slot,
        [Parameter(Mandatory)][string]$SourceKind,
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][string]$Text,
        [string]$State = '',
        [bool]$ConsumeOnce = $false
    )

    return [pscustomobject]@{
        Order = $Order
        Slot = $Slot
        SourceKind = $SourceKind
        SourceId = $SourceId
        Text = $Text
        State = $State
        ConsumeOnce = $ConsumeOnce
    }
}

function Split-OneTimeItemsByPlacement {
    param($OneTimeItems)

    return [pscustomobject]@{
        Prefix = @(@($OneTimeItems) | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'Placement' -DefaultValue '') -eq 'one-time-prefix' })
        Suffix = @(@($OneTimeItems) | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'Placement' -DefaultValue '') -eq 'one-time-suffix' })
    }
}

function Get-MessagePlan {
    param(
        [Parameter(Mandatory)]$TemplateBlocks,
        [Parameter(Mandatory)][string]$BodyText,
        $OneTimeItems = @()
    )

    $blocks = New-Object System.Collections.ArrayList
    $order = 1
    $oneTimeSplit = Split-OneTimeItemsByPlacement -OneTimeItems $OneTimeItems

    $slotOrder = Get-OrderedMessageSlotSequence -RequestedSlotOrder @(Get-ConfigValue -Object $TemplateBlocks -Name 'SlotOrder' -DefaultValue @()) -TemplateName ''
    foreach ($slot in @($slotOrder)) {
        switch ([string]$slot) {
            'global-prefix' {
                foreach ($text in @($TemplateBlocks.PrefixBlocks)) {
                    [void]$blocks.Add((New-MessagePlanBlock -Order $order -Slot 'global-prefix' -SourceKind 'template-prefix' -SourceId 'global' -Text ([string]$text)))
                    $order += 1
                }
            }
            'pair-extra' {
                foreach ($text in @($TemplateBlocks.Sources.Pair)) {
                    [void]$blocks.Add((New-MessagePlanBlock -Order $order -Slot 'pair-extra' -SourceKind 'pair-override' -SourceId 'pair' -Text ([string]$text)))
                    $order += 1
                }
            }
            'role-extra' {
                foreach ($text in @($TemplateBlocks.Sources.Role)) {
                    [void]$blocks.Add((New-MessagePlanBlock -Order $order -Slot 'role-extra' -SourceKind 'role-override' -SourceId 'role' -Text ([string]$text)))
                    $order += 1
                }
            }
            'target-extra' {
                foreach ($text in @($TemplateBlocks.Sources.Target)) {
                    [void]$blocks.Add((New-MessagePlanBlock -Order $order -Slot 'target-extra' -SourceKind 'target-override' -SourceId 'target' -Text ([string]$text)))
                    $order += 1
                }
            }
            'one-time-prefix' {
                foreach ($item in @($oneTimeSplit.Prefix)) {
                    [void]$blocks.Add((New-MessagePlanBlock `
                        -Order $order `
                        -Slot 'one-time-prefix' `
                        -SourceKind 'one-time-queue' `
                        -SourceId ([string](Get-ConfigValue -Object $item -Name 'Id' -DefaultValue '')) `
                        -Text ([string](Get-ConfigValue -Object $item -Name 'Text' -DefaultValue '')) `
                        -State ([string](Get-ConfigValue -Object $item -Name 'State' -DefaultValue 'queued')) `
                        -ConsumeOnce ([bool](Get-ConfigValue -Object $item -Name 'ConsumeOnce' -DefaultValue $true))))
                    $order += 1
                }
            }
            'body' {
                [void]$blocks.Add((New-MessagePlanBlock -Order $order -Slot 'body' -SourceKind 'dynamic-body' -SourceId 'generated' -Text $BodyText))
                $order += 1
            }
            'one-time-suffix' {
                foreach ($item in @($oneTimeSplit.Suffix)) {
                    [void]$blocks.Add((New-MessagePlanBlock `
                        -Order $order `
                        -Slot 'one-time-suffix' `
                        -SourceKind 'one-time-queue' `
                        -SourceId ([string](Get-ConfigValue -Object $item -Name 'Id' -DefaultValue '')) `
                        -Text ([string](Get-ConfigValue -Object $item -Name 'Text' -DefaultValue '')) `
                        -State ([string](Get-ConfigValue -Object $item -Name 'State' -DefaultValue 'queued')) `
                        -ConsumeOnce ([bool](Get-ConfigValue -Object $item -Name 'ConsumeOnce' -DefaultValue $true))))
                    $order += 1
                }
            }
            'global-suffix' {
                foreach ($text in @($TemplateBlocks.SuffixBlocks)) {
                    [void]$blocks.Add((New-MessagePlanBlock -Order $order -Slot 'global-suffix' -SourceKind 'template-suffix' -SourceId 'global' -Text ([string]$text)))
                    $order += 1
                }
            }
        }
    }

    return [pscustomobject]@{
        Order = @($blocks | ForEach-Object { [string]$_.Slot })
        Blocks = @($blocks)
    }
}

function Get-PathState {
    param(
        [string]$Path,
        [ValidateSet('file', 'directory')][string]$ExpectedType = 'file'
    )

    $exists = $false
    if (Test-NonEmptyString $Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($ExpectedType -eq 'directory') {
                $exists = [bool]$item.PSIsContainer
            }
            else {
                $exists = -not [bool]$item.PSIsContainer
            }
        }
        catch {
            $exists = $false
        }
    }

    return [pscustomobject]@{
        Path = [string]$Path
        Exists = [bool]$exists
        LastWriteAt = (Get-PathLastWriteAt -Path $Path)
        AgeSeconds = (Get-PathAgeSeconds -Path $Path)
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
        [Parameter(Mandatory)][string]$PublishReadyPath
    )

    $availableReviewInputPaths = New-Object System.Collections.Generic.List[string]
    $seenReviewInputPaths = @{}
    foreach ($candidate in @($ReviewSummaryPath, $ReviewZipPath)) {
        if (-not (Test-NonEmptyString $candidate)) {
            continue
        }
        if (-not (Test-ExistingLiteralPathSafe -Path $candidate)) {
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

function Get-InitialInstructionPreview {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PartnerTargetId,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][string]$PartnerFolder,
        [Parameter(Mandatory)][string]$SourceSummaryPath,
        [Parameter(Mandatory)][string]$SourceReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath,
        $OneTimeItems = @()
    )

    $templateBlocks = Get-TemplateMergeDetails -PairTest $PairTest -TemplateName 'Initial' -PairId $PairId -RoleName $RoleName -TargetId $TargetId
    $summaryFileName = [string]$PairTest.SummaryFileName
    $reviewFolderName = [string]$PairTest.ReviewFolderName
    $reviewZipPattern = [string]$PairTest.ReviewZipPattern
    $oneTimeSplit = Split-OneTimeItemsByPlacement -OneTimeItems $OneTimeItems
    $partnerSourceOutboxPath = Join-Path $PartnerFolder ([string]$PairTest.SourceOutboxFolderName)
    $partnerSourceSummaryPath = Join-Path $partnerSourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
    $partnerSourceReviewZipPath = Join-Path $partnerSourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
    $pathGuideBlock = Get-AutomaticPathGuideBlock `
        -TargetId $TargetId `
        -TargetFolder $TargetFolder `
        -PartnerFolder $PartnerFolder `
        -ReviewSummaryPath $partnerSourceSummaryPath `
        -ReviewZipPath $partnerSourceReviewZipPath `
        -OutputSummaryPath $SourceSummaryPath `
        -OutputReviewZipPath $SourceReviewZipPath `
        -PublishReadyPath $PublishReadyPath

    $bodyBlock = @"
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

이번 테스트에서는 아래 규칙으로 움직이세요.
1. 내 폴더의 '$summaryFileName'로 이번 작업 요약을 작성합니다.
2. 추가 검토 메모가 필요하면 내 폴더(target folder)에 매번 새 이름의 txt 파일을 생성합니다.
3. 그 txt를 내 폴더의 '$reviewFolderName' 하위에 만드는 새 review zip에 포함합니다.
4. zip 파일이 만들어지면 상대 창으로 handoff 메시지가 전달됩니다.
5. handoff를 받으면 상대 폴더의 '$summaryFileName' 와 '$reviewFolderName' zip을 읽고 다음 작업을 이어갑니다.
6. 다음 handoff에 자동 전달되는 새 파일명은 새 review zip 이름입니다. summary.txt는 같은 이름으로 갱신됩니다.
"@

    $preview = Join-MessageBlocks -Blocks (Get-OrderedMessageBlocks -TemplateBlocks $templateBlocks -BodyText $bodyBlock -OneTimeItems $OneTimeItems)
    return [pscustomobject]@{
        Preview = $preview
        TemplateBlocks = $templateBlocks
        PendingOneTimeItems = @($OneTimeItems)
        MessagePlan = (Get-MessagePlan -TemplateBlocks $templateBlocks -BodyText $bodyBlock -OneTimeItems $OneTimeItems)
    }
}

function Get-HandoffInstructionPreview {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PartnerTargetId,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][string]$PartnerFolder,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$SourceSummaryPath,
        [Parameter(Mandatory)][string]$SourceReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath,
        $OneTimeItems = @()
    )

    $templateBlocks = Get-TemplateMergeDetails -PairTest $PairTest -TemplateName 'Handoff' -PairId $PairId -RoleName $RoleName -TargetId $TargetId
    $summaryFileName = [string]$PairTest.SummaryFileName
    $reviewFolderName = [string]$PairTest.ReviewFolderName
    $zipFileName = (($ZipPath -split '[\\/]') | Select-Object -Last 1)
    $oneTimeSplit = Split-OneTimeItemsByPlacement -OneTimeItems $OneTimeItems
    $pathGuideBlock = Get-AutomaticPathGuideBlock `
        -TargetId $PartnerTargetId `
        -TargetFolder $PartnerFolder `
        -PartnerFolder $TargetFolder `
        -ReviewSummaryPath $SummaryPath `
        -ReviewZipPath $ZipPath `
        -OutputSummaryPath $SourceSummaryPath `
        -OutputReviewZipPath $SourceReviewZipPath `
        -PublishReadyPath $PublishReadyPath

    $bodyBlock = @(
        '[paired-exchange handoff]'
        ('pair: ' + $PairId)
        ('from: ' + $TargetId)
        ('to: ' + $PartnerTargetId)
        ''
        $pathGuideBlock
        ''
        '다음 작업:'
        ('1. 상대가 보낸 {0} 와 review zip 을 입력으로 확인합니다.' -f $summaryFileName)
        '2. 필요한 수정이나 검토를 진행합니다.'
        '3. 최종 결과만 내 SourceOutboxPath 아래의 summary.txt 와 review.zip 으로 생성합니다.'
        '4. summary.txt 와 review.zip 작성이 끝난 뒤 마지막에 publish.ready.json 을 생성합니다.'
        '5. 직접 target contract 경로에 복사하거나 별도 submit 명령을 다시 실행하지 마세요.'
    ) -join "`r`n"

    $preview = Join-MessageBlocks -Blocks (Get-OrderedMessageBlocks -TemplateBlocks $templateBlocks -BodyText $bodyBlock -OneTimeItems $OneTimeItems)
    return [pscustomobject]@{
        Preview = $preview
        TemplateBlocks = $templateBlocks
        PendingOneTimeItems = @($OneTimeItems)
        MessagePlan = (Get-MessagePlan -TemplateBlocks $templateBlocks -BodyText $bodyBlock -OneTimeItems $OneTimeItems)
    }
}

function Get-PairTargetRows {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$SelectedRunRoot,
        [Parameter(Mandatory)]$Pairs,
        [Parameter(Mandatory)][hashtable]$OneTimeQueueStateByPair,
        [string]$RequestedTargetId = ''
    )

    $targetConfigMap = Get-ConfigTargetMap -Config $Config
    $messagesRoot = Join-Path $SelectedRunRoot ([string]$PairTest.MessageFolderName)
    $rows = @()

    foreach ($pair in @($Pairs)) {
        foreach ($entry in @(
            [pscustomobject]@{ RoleName = 'top'; TargetId = [string]$pair.TopTargetId; PartnerTargetId = [string]$pair.BottomTargetId }
            [pscustomobject]@{ RoleName = 'bottom'; TargetId = [string]$pair.BottomTargetId; PartnerTargetId = [string]$pair.TopTargetId }
        )) {
            if ((Test-NonEmptyString $RequestedTargetId) -and ([string]$entry.TargetId -ne $RequestedTargetId)) {
                continue
            }

            $targetFolder = Join-Path (Join-Path $SelectedRunRoot ([string]$pair.PairId)) ([string]$entry.TargetId)
            $partnerFolder = Join-Path (Join-Path $SelectedRunRoot ([string]$pair.PairId)) ([string]$entry.PartnerTargetId)
            $targetConfig = if ($targetConfigMap.ContainsKey([string]$entry.TargetId)) { $targetConfigMap[[string]$entry.TargetId] } else { $null }
            $windowTitle = [string](Get-ConfigValue -Object $targetConfig -Name 'WindowTitle' -DefaultValue '')
            $inboxFolder = [string](Get-ConfigValue -Object $targetConfig -Name 'Folder' -DefaultValue '')
            $requestPath = Join-Path $targetFolder ([string]$PairTest.HeadlessExec.RequestFileName)
            $donePath = Join-Path $targetFolder ([string]$PairTest.HeadlessExec.DoneFileName)
            $errorPath = Join-Path $targetFolder ([string]$PairTest.HeadlessExec.ErrorFileName)
            $resultPath = Join-Path $targetFolder ([string]$PairTest.HeadlessExec.ResultFileName)
            $promptPath = Join-Path $targetFolder ([string]$PairTest.HeadlessExec.PromptFileName)
            $summaryPath = Join-Path $targetFolder ([string]$PairTest.SummaryFileName)
            $reviewFolderPath = Join-Path $targetFolder ([string]$PairTest.ReviewFolderName)
            $workFolderPath = Join-Path $targetFolder ([string]$PairTest.WorkFolderName)
            $sourceOutboxPath = Join-Path $targetFolder ([string]$PairTest.SourceOutboxFolderName)
            $sourceSummaryPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
            $sourceReviewZipPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
            $publishReadyPath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishReadyFileName)
            $publishedArchivePath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishedArchiveFolderName)
            $partnerSourceOutboxPath = Join-Path $partnerFolder ([string]$PairTest.SourceOutboxFolderName)
            $partnerSourceSummaryPath = Join-Path $partnerSourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
            $partnerSourceReviewZipPath = Join-Path $partnerSourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
            $availableReviewInputPaths = @()
            foreach ($candidate in @($partnerSourceSummaryPath, $partnerSourceReviewZipPath)) {
                if (-not (Test-NonEmptyString $candidate)) {
                    continue
                }
                if (-not (Test-ExistingLiteralPathSafe -Path $candidate)) {
                    continue
                }
                $availableReviewInputPaths += [System.IO.Path]::GetFullPath($candidate)
            }
            $availableReviewInputPaths = @($availableReviewInputPaths | Select-Object -Unique)
            $agentInstructionPathBlock = Get-AutomaticPathGuideBlock `
                -TargetId ([string]$entry.TargetId) `
                -TargetFolder $targetFolder `
                -PartnerFolder $partnerFolder `
                -ReviewSummaryPath $partnerSourceSummaryPath `
                -ReviewZipPath $partnerSourceReviewZipPath `
                -OutputSummaryPath $sourceSummaryPath `
                -OutputReviewZipPath $sourceReviewZipPath `
                -PublishReadyPath $publishReadyPath
            $checkScriptPath = Join-Path $targetFolder ([string]$PairTest.CheckScriptFileName)
            $submitScriptPath = Join-Path $targetFolder ([string]$PairTest.SubmitScriptFileName)
            $checkCmdPath = Join-Path $targetFolder ([string]$PairTest.CheckCmdFileName)
            $submitCmdPath = Join-Path $targetFolder ([string]$PairTest.SubmitCmdFileName)
            $initialMessagePath = Join-Path $messagesRoot ([string]$entry.TargetId + '.txt')
            $handoffMessagePattern = Join-Path $messagesRoot ('handoff_{0}_to_{1}_<yyyyMMdd_HHmmss_fff>.txt' -f [string]$entry.TargetId, [string]$entry.PartnerTargetId)
            $reviewZipPreviewPath = Join-Path $reviewFolderPath (Get-ReviewZipPreviewName -Pattern ([string]$PairTest.ReviewZipPattern) -TargetId ([string]$entry.TargetId))
            $queueState = $OneTimeQueueStateByPair[[string]$pair.PairId]
            $initialOneTimeItems = @()
            $handoffOneTimeItems = @()
            if ($null -ne $queueState) {
                $initialOneTimeItems = @(Get-ApplicableOneTimeQueueItems -QueueDocument $queueState.Document -PairId ([string]$pair.PairId) -RoleName ([string]$entry.RoleName) -TargetId ([string]$entry.TargetId) -MessageType 'initial')
                $handoffOneTimeItems = @(Get-ApplicableOneTimeQueueItems -QueueDocument $queueState.Document -PairId ([string]$pair.PairId) -RoleName ([string]$entry.RoleName) -TargetId ([string]$entry.TargetId) -MessageType 'handoff')
            }
            $initialPreview = Get-InitialInstructionPreview `
                -PairTest $PairTest `
                -PairId ([string]$pair.PairId) `
                -RoleName ([string]$entry.RoleName) `
                -TargetId ([string]$entry.TargetId) `
                -PartnerTargetId ([string]$entry.PartnerTargetId) `
                -TargetFolder $targetFolder `
                -PartnerFolder $partnerFolder `
                -SourceSummaryPath $sourceSummaryPath `
                -SourceReviewZipPath $sourceReviewZipPath `
                -PublishReadyPath $publishReadyPath `
                -OneTimeItems $initialOneTimeItems
            $handoffPreview = Get-HandoffInstructionPreview `
                -PairTest $PairTest `
                -PairId ([string]$pair.PairId) `
                -RoleName ([string]$entry.RoleName) `
                -TargetId ([string]$entry.TargetId) `
                -PartnerTargetId ([string]$entry.PartnerTargetId) `
                -TargetFolder $targetFolder `
                -PartnerFolder $partnerFolder `
                -SummaryPath $summaryPath `
                -ZipPath $reviewZipPreviewPath `
                -SourceSummaryPath $sourceSummaryPath `
                -SourceReviewZipPath $sourceReviewZipPath `
                -PublishReadyPath $publishReadyPath `
                -OneTimeItems $handoffOneTimeItems

            $rows += [pscustomobject]@{
                PairId = [string]$pair.PairId
                RoleName = [string]$entry.RoleName
                TargetId = [string]$entry.TargetId
                PartnerTargetId = [string]$entry.PartnerTargetId
                WindowTitle = $windowTitle
                InboxFolder = $inboxFolder
                OwnTargetFolder = $targetFolder
                PartnerTargetFolder = $partnerFolder
                PairTargetFolder = $targetFolder
                PartnerFolder = $partnerFolder
                ReviewInputFiles = [pscustomobject]@{
                    PartnerSummaryPath = $partnerSourceSummaryPath
                    PartnerReviewZipPath = $partnerSourceReviewZipPath
                    AvailablePaths = @($availableReviewInputPaths)
                    HasAny = [bool]($availableReviewInputPaths.Count -gt 0)
                }
                OutputFiles = [pscustomobject]@{
                    SummaryPath = $sourceSummaryPath
                    ReviewZipPath = $sourceReviewZipPath
                    PublishReadyPath = $publishReadyPath
                }
                AgentInstructionPathBlock = $agentInstructionPathBlock
                SummaryPath = $summaryPath
                ReviewFolderPath = $reviewFolderPath
                WorkFolderPath = $workFolderPath
                SourceOutboxPath = $sourceOutboxPath
                SourceSummaryPath = $sourceSummaryPath
                SourceReviewZipPath = $sourceReviewZipPath
                PublishReadyPath = $publishReadyPath
                PublishedArchivePath = $publishedArchivePath
                CheckScriptPath = $checkScriptPath
                SubmitScriptPath = $submitScriptPath
                CheckCmdPath = $checkCmdPath
                SubmitCmdPath = $submitCmdPath
                ReviewZipPreviewPath = $reviewZipPreviewPath
                InitialInstructionPath = (Join-Path $targetFolder 'instructions.txt')
                InitialMessagePath = $initialMessagePath
                HandoffMessagePattern = $handoffMessagePattern
                RequestPath = $requestPath
                DonePath = $donePath
                ErrorPath = $errorPath
                ResultPath = $resultPath
                PromptPath = $promptPath
                PathState = [pscustomobject]@{
                    InboxFolder = (Get-PathState -Path $inboxFolder -ExpectedType 'directory')
                    PairTargetFolder = (Get-PathState -Path $targetFolder -ExpectedType 'directory')
                    PartnerFolder = (Get-PathState -Path $partnerFolder -ExpectedType 'directory')
                    Summary = (Get-PathState -Path $summaryPath -ExpectedType 'file')
                    ReviewFolder = (Get-PathState -Path $reviewFolderPath -ExpectedType 'directory')
                    WorkFolder = (Get-PathState -Path $workFolderPath -ExpectedType 'directory')
                    SourceOutbox = (Get-PathState -Path $sourceOutboxPath -ExpectedType 'directory')
                    SourceSummary = (Get-PathState -Path $sourceSummaryPath -ExpectedType 'file')
                    SourceReviewZip = (Get-PathState -Path $sourceReviewZipPath -ExpectedType 'file')
                    PublishReady = (Get-PathState -Path $publishReadyPath -ExpectedType 'file')
                    PublishedArchive = (Get-PathState -Path $publishedArchivePath -ExpectedType 'directory')
                    InitialInstruction = (Get-PathState -Path (Join-Path $targetFolder 'instructions.txt') -ExpectedType 'file')
                    InitialMessage = (Get-PathState -Path $initialMessagePath -ExpectedType 'file')
                    Request = (Get-PathState -Path $requestPath -ExpectedType 'file')
                    Prompt = (Get-PathState -Path $promptPath -ExpectedType 'file')
                    Done = (Get-PathState -Path $donePath -ExpectedType 'file')
                    Error = (Get-PathState -Path $errorPath -ExpectedType 'file')
                    Result = (Get-PathState -Path $resultPath -ExpectedType 'file')
                    CheckScript = (Get-PathState -Path $checkScriptPath -ExpectedType 'file')
                    SubmitScript = (Get-PathState -Path $submitScriptPath -ExpectedType 'file')
                    CheckCmd = (Get-PathState -Path $checkCmdPath -ExpectedType 'file')
                    SubmitCmd = (Get-PathState -Path $submitCmdPath -ExpectedType 'file')
                }
                Initial = [pscustomobject]@{
                    AppliedSources = @($initialPreview.TemplateBlocks.Sources.Applied)
                    PairExtraBlocks = @($initialPreview.TemplateBlocks.Sources.Pair)
                    RoleExtraBlocks = @($initialPreview.TemplateBlocks.Sources.Role)
                    TargetExtraBlocks = @($initialPreview.TemplateBlocks.Sources.Target)
                    PendingOneTimeItems = @($initialPreview.PendingOneTimeItems)
                    SlotOrder = @($initialPreview.TemplateBlocks.SlotOrder)
                    PrefixBlocks = @($initialPreview.TemplateBlocks.PrefixBlocks)
                    SuffixBlocks = @($initialPreview.TemplateBlocks.SuffixBlocks)
                    MessagePlan = $initialPreview.MessagePlan
                    Preview = [string]$initialPreview.Preview
                }
                Handoff = [pscustomobject]@{
                    AppliedSources = @($handoffPreview.TemplateBlocks.Sources.Applied)
                    PairExtraBlocks = @($handoffPreview.TemplateBlocks.Sources.Pair)
                    RoleExtraBlocks = @($handoffPreview.TemplateBlocks.Sources.Role)
                    TargetExtraBlocks = @($handoffPreview.TemplateBlocks.Sources.Target)
                    PendingOneTimeItems = @($handoffPreview.PendingOneTimeItems)
                    SlotOrder = @($handoffPreview.TemplateBlocks.SlotOrder)
                    PrefixBlocks = @($handoffPreview.TemplateBlocks.PrefixBlocks)
                    SuffixBlocks = @($handoffPreview.TemplateBlocks.SuffixBlocks)
                    MessagePlan = $handoffPreview.MessagePlan
                    Preview = [string]$handoffPreview.Preview
                }
                OneTimeQueue = if ($null -ne $queueState) {
                    [pscustomobject]@{
                        QueuePath = [string]$queueState.QueuePath
                        QueueSummary = (Get-OneTimeQueueSummary -QueueDocument $queueState.Document -QueuePath $queueState.QueuePath)
                    }
                }
                else {
                    $null
                }
            }
        }
    }

    return $rows
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
$configPairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$runContext = Resolve-DisplayRunContext -Root $root -PairTest $configPairTest -RequestedRunRoot $RunRoot
$effectivePairTest = if ($runContext.ManifestExists) {
    Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath -ManifestPairTest (Get-ConfigValue -Object $runContext.Manifest -Name 'PairTest' -DefaultValue $null)
}
else {
    $configPairTest
}

$pairDefinition = Resolve-PairDefinitions -PairTest $effectivePairTest -Manifest $runContext.Manifest -RequestedPairIds $PairId -RequestedTargetId $TargetId
$pairs = @($pairDefinition.Pairs)
if (@($pairs).Count -eq 0) {
    throw 'no matching pair definitions found for the requested filters.'
}

$oneTimeQueueStateByPair = @{}
foreach ($pair in @($pairs)) {
    $oneTimeQueueStateByPair[[string]$pair.PairId] = Get-OneTimeQueueDocument -Root $root -Config $config -PairId ([string]$pair.PairId)
}

$pairRows = Get-PairTargetRows -Config $config -PairTest $effectivePairTest -SelectedRunRoot ([string]$runContext.SelectedRunRoot) -Pairs $pairs -OneTimeQueueStateByPair $oneTimeQueueStateByPair -RequestedTargetId $TargetId
if (@($pairRows).Count -eq 0) {
    throw 'no matching target rows found for the requested filters.'
}

$selectedPreviewRows = if (@($PairId | Where-Object { Test-NonEmptyString $_ }).Count -gt 0 -or (Test-NonEmptyString $TargetId)) {
    @($pairRows)
}
else {
    @($pairRows | Where-Object { [string]$_.PairId -eq 'pair01' })
}

$overviewPairs = @(
    $pairs | ForEach-Object {
        $pairPolicy = Get-PairPolicyForPair -PairTest $effectivePairTest -PairId ([string]$_.PairId)
        [pscustomobject]@{
            PairId = [string]$_.PairId
            TopTargetId = [string]$_.TopTargetId
            BottomTargetId = [string]$_.BottomTargetId
            SeedTargetId = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedTargetId' -DefaultValue ([string]$_.TopTargetId))
            Policy = $pairPolicy
        }
    }
)
$pairActivationSummary = @(Get-PairActivationSummary -Root $root -Config $config -PairIds (@($overviewPairs | ForEach-Object { [string]$_.PairId })))
$pairActivationMap = @{}
foreach ($item in @($pairActivationSummary)) {
    $pairActivationMap[[string]$item.PairId] = $item
}

$warningPolicy = Get-WarningPolicy
$warningRecords = @()
if (-not [bool]$runContext.SelectedRunRootExists -and [string]$runContext.SelectedRunRootSource -ne 'next-preview') {
    $warningRecords += (New-PolicyWarningRecord -PolicyMap $warningPolicy -Code 'runroot-missing' -Message 'Selected run root does not exist on disk. Paths may be preview-only or stale references.')
}
if ([string]$runContext.SelectedRunRootSource -eq 'latest-existing') {
    $warningRecords += (New-PolicyWarningRecord -PolicyMap $warningPolicy -Code 'runroot-latest-existing' -Message 'RunRoot was not explicitly requested. Showing latest-existing run root.')
}
if ([string]$runContext.SelectedRunRootSource -eq 'next-preview') {
    $warningRecords += (New-PolicyWarningRecord -PolicyMap $warningPolicy -Code 'runroot-next-preview' -Message 'No existing run root was found. Showing next-preview paths only.')
}
if (-not [bool]$runContext.ManifestExists) {
    $warningRecords += (New-PolicyWarningRecord -PolicyMap $warningPolicy -Code 'manifest-missing' -Message 'Selected run root does not contain manifest.json. Pair contract preview may be fallback-based.')
}
if ([string]$pairDefinition.Source -eq 'fallback') {
    $warningRecords += (New-PolicyWarningRecord -PolicyMap $warningPolicy -Code 'pair-definition-fallback' -Message 'Pair definitions are using built-in fallback mapping (pair01~04 / target01~08).')
}
if ($null -ne $runContext.SelectedRunRootAgeSeconds -and $runContext.SelectedRunRootAgeSeconds -ge $StaleRunThresholdSec) {
    $warningRecords += (New-PolicyWarningRecord -PolicyMap $warningPolicy -Code 'runroot-stale' -Message ("Selected run root is older than stale threshold: age={0}s threshold={1}s" -f $runContext.SelectedRunRootAgeSeconds, $StaleRunThresholdSec))
}

$warningRecords = @($warningRecords | Sort-Object Priority, Code)
$warningSummary = Get-WarningSummary -WarningRecords $warningRecords
$temporarySnapshotRoot = Join-Path $root '_tmp'
$evidenceSnapshotRoot = Join-Path $root 'evidence\effective-config'
$evidenceReasonCodes = @($warningRecords | Where-Object { [bool]$_.BlocksEvidence } | ForEach-Object { [string]$_.Code } | Sort-Object -Unique)
$evidenceRecommended = ($evidenceReasonCodes.Count -eq 0)
$operationalPolicy = [pscustomobject]@{
    WarningsAreBlocking = $false
    EvidenceRecommendedRequires = @(
        'RunContext.SelectedRunRootExists = true'
        'RunContext.ManifestExists = true'
        'PairDefinitionSource = manifest'
        'RunContext.SelectedRunRootIsStale = false'
    )
    BlockingGateCommands = @(
        'check-target-window-visibility.ps1'
        'check-headless-exec-readiness.ps1'
    )
    EvidenceSaveCommand = 'save-effective-config-evidence.ps1'
}

$effectiveConfig = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = (Get-Date).ToString('o')
    PairDefinitionSource = [string]$pairDefinition.Source
    Warnings = @($warningRecords | ForEach-Object { [string]$_.Message })
    WarningDetails = @($warningRecords)
    WarningSummary = $warningSummary
    RequestedFilters = [pscustomobject]@{
        PairIds = @($PairId | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique)
        TargetId = [string]$TargetId
        Mode = [string]$Mode
        StaleRunThresholdSec = [int]$StaleRunThresholdSec
    }
    Config = [pscustomobject]@{
        ConfigPath = $resolvedConfigPath
        ConfigHash = (Get-FileHashHex -Path $resolvedConfigPath)
        LaneName = [string](Get-ConfigValue -Object $config -Name 'LaneName' -DefaultValue '')
        WindowTitlePrefix = [string](Get-ConfigValue -Object $config -Name 'WindowTitlePrefix' -DefaultValue '')
        BindingProfilePath = [string](Get-ConfigValue -Object $config -Name 'BindingProfilePath' -DefaultValue '')
        LauncherWrapperPath = [string](Get-ConfigValue -Object $config -Name 'LauncherWrapperPath' -DefaultValue '')
        RuntimeMapPath = [string](Get-ConfigValue -Object $config -Name 'RuntimeMapPath' -DefaultValue '')
        RouterStatePath = [string](Get-ConfigValue -Object $config -Name 'RouterStatePath' -DefaultValue '')
    }
    RunContext = [pscustomobject]@{
        SelectedRunRoot = [string]$runContext.SelectedRunRoot
        SelectedRunRootSource = [string]$runContext.SelectedRunRootSource
        SelectedRunRootExists = [bool]$runContext.SelectedRunRootExists
        SelectedRunRootLastWriteAt = [string]$runContext.SelectedRunRootLastWriteAt
        SelectedRunRootAgeSeconds = $runContext.SelectedRunRootAgeSeconds
        SelectedRunRootIsStale = [bool]($null -ne $runContext.SelectedRunRootAgeSeconds -and $runContext.SelectedRunRootAgeSeconds -ge $StaleRunThresholdSec)
        StaleRunThresholdSec = [int]$StaleRunThresholdSec
        RequestedRunRoot = [string]$runContext.RequestedRunRoot
        RequestedRunRootExists = [bool]$runContext.RequestedRunRootExists
        LatestExistingRunRoot = [string]$runContext.LatestExistingRunRoot
        LatestExistingRunRootLastWriteAt = [string]$runContext.LatestExistingRunRootLastWriteAt
        NextRunRootPreview = [string]$runContext.NextRunRootPreview
        ManifestPath = [string]$runContext.ManifestPath
        ManifestExists = [bool]$runContext.ManifestExists
    }
    EvidencePolicy = [pscustomobject]@{
        TemporarySnapshotRoot = $temporarySnapshotRoot
        TemporarySnapshotPurpose = 'adhoc-preview'
        EvidenceSnapshotRoot = $evidenceSnapshotRoot
        EvidenceSnapshotPurpose = 'operations-evidence'
        Recommended = [bool]$evidenceRecommended
        ReasonCodes = @($evidenceReasonCodes)
    }
    OperationalPolicy = $operationalPolicy
    PairTest = [pscustomobject]@{
        RunRootBase = [string]$effectivePairTest.RunRootBase
        RunRootPattern = [string]$effectivePairTest.RunRootPattern
        SummaryFileName = [string]$effectivePairTest.SummaryFileName
        ReviewFolderName = [string]$effectivePairTest.ReviewFolderName
        MessageFolderName = [string]$effectivePairTest.MessageFolderName
        ReviewZipPattern = [string]$effectivePairTest.ReviewZipPattern
        SummaryZipMaxSkewSeconds = [double]$effectivePairTest.SummaryZipMaxSkewSeconds
        HeadlessExec = [pscustomobject]@{
            Enabled = [bool]$effectivePairTest.HeadlessExec.Enabled
            CodexExecutable = [string]$effectivePairTest.HeadlessExec.CodexExecutable
            Arguments = @($effectivePairTest.HeadlessExec.Arguments)
            RequestFileName = [string]$effectivePairTest.HeadlessExec.RequestFileName
            DoneFileName = [string]$effectivePairTest.HeadlessExec.DoneFileName
            ErrorFileName = [string]$effectivePairTest.HeadlessExec.ErrorFileName
            ResultFileName = [string]$effectivePairTest.HeadlessExec.ResultFileName
            OutputLastMessageFileName = [string]$effectivePairTest.HeadlessExec.OutputLastMessageFileName
            PromptFileName = [string]$effectivePairTest.HeadlessExec.PromptFileName
            MaxRunSeconds = [int]$effectivePairTest.HeadlessExec.MaxRunSeconds
            MutexScope = [string]$effectivePairTest.HeadlessExec.MutexScope
        }
    }
    OneTimeQueueSummary = @(
        $pairs | ForEach-Object {
            $queueState = $oneTimeQueueStateByPair[[string]$_.PairId]
            [pscustomobject]@{
                PairId = [string]$_.PairId
                QueuePath = [string]$queueState.QueuePath
                QueueSummary = (Get-OneTimeQueueSummary -QueueDocument $queueState.Document -QueuePath $queueState.QueuePath)
            }
        }
    )
    PairActivationSummary = @($pairActivationSummary)
    OverviewPairs = @($overviewPairs)
    PreviewMode = $Mode
    PreviewRows = @(
        $selectedPreviewRows | ForEach-Object {
            if ($Mode -eq 'initial') {
                [pscustomobject]@{
                    PairId = [string]$_.PairId
                    RoleName = [string]$_.RoleName
                    TargetId = [string]$_.TargetId
                    PartnerTargetId = [string]$_.PartnerTargetId
                    WindowTitle = [string]$_.WindowTitle
                    InboxFolder = [string]$_.InboxFolder
                    PairTargetFolder = [string]$_.PairTargetFolder
                    PartnerFolder = [string]$_.PartnerFolder
                    SummaryPath = [string]$_.SummaryPath
                    ReviewFolderPath = [string]$_.ReviewFolderPath
                    WorkFolderPath = [string]$_.WorkFolderPath
                    SourceOutboxPath = [string]$_.SourceOutboxPath
                    SourceSummaryPath = [string]$_.SourceSummaryPath
                    SourceReviewZipPath = [string]$_.SourceReviewZipPath
                    PublishReadyPath = [string]$_.PublishReadyPath
                    PublishedArchivePath = [string]$_.PublishedArchivePath
                    CheckScriptPath = [string]$_.CheckScriptPath
                    SubmitScriptPath = [string]$_.SubmitScriptPath
                    CheckCmdPath = [string]$_.CheckCmdPath
                    SubmitCmdPath = [string]$_.SubmitCmdPath
                    ReviewZipPreviewPath = [string]$_.ReviewZipPreviewPath
                    InitialInstructionPath = [string]$_.InitialInstructionPath
                    InitialMessagePath = [string]$_.InitialMessagePath
                    RequestPath = [string]$_.RequestPath
                    PromptPath = [string]$_.PromptPath
                    PairActivation = $pairActivationMap[[string]$_.PairId]
                    PathState = $_.PathState
                    Initial = $_.Initial
                }
            }
            elseif ($Mode -eq 'handoff') {
                [pscustomobject]@{
                    PairId = [string]$_.PairId
                    RoleName = [string]$_.RoleName
                    TargetId = [string]$_.TargetId
                    PartnerTargetId = [string]$_.PartnerTargetId
                    WindowTitle = [string]$_.WindowTitle
                    PairTargetFolder = [string]$_.PairTargetFolder
                    PartnerFolder = [string]$_.PartnerFolder
                    SummaryPath = [string]$_.SummaryPath
                    ReviewFolderPath = [string]$_.ReviewFolderPath
                    WorkFolderPath = [string]$_.WorkFolderPath
                    SourceOutboxPath = [string]$_.SourceOutboxPath
                    SourceSummaryPath = [string]$_.SourceSummaryPath
                    SourceReviewZipPath = [string]$_.SourceReviewZipPath
                    PublishReadyPath = [string]$_.PublishReadyPath
                    PublishedArchivePath = [string]$_.PublishedArchivePath
                    CheckScriptPath = [string]$_.CheckScriptPath
                    SubmitScriptPath = [string]$_.SubmitScriptPath
                    CheckCmdPath = [string]$_.CheckCmdPath
                    SubmitCmdPath = [string]$_.SubmitCmdPath
                    ReviewZipPreviewPath = [string]$_.ReviewZipPreviewPath
                    HandoffMessagePattern = [string]$_.HandoffMessagePattern
                    DonePath = [string]$_.DonePath
                    ErrorPath = [string]$_.ErrorPath
                    ResultPath = [string]$_.ResultPath
                    PairActivation = $pairActivationMap[[string]$_.PairId]
                    PathState = $_.PathState
                    Handoff = $_.Handoff
                }
            }
            else {
                [pscustomobject]@{
                    PairId = [string]$_.PairId
                    RoleName = [string]$_.RoleName
                    TargetId = [string]$_.TargetId
                    PartnerTargetId = [string]$_.PartnerTargetId
                    WindowTitle = [string]$_.WindowTitle
                    InboxFolder = [string]$_.InboxFolder
                    PairTargetFolder = [string]$_.PairTargetFolder
                    PartnerFolder = [string]$_.PartnerFolder
                    SummaryPath = [string]$_.SummaryPath
                    ReviewFolderPath = [string]$_.ReviewFolderPath
                    WorkFolderPath = [string]$_.WorkFolderPath
                    SourceOutboxPath = [string]$_.SourceOutboxPath
                    SourceSummaryPath = [string]$_.SourceSummaryPath
                    SourceReviewZipPath = [string]$_.SourceReviewZipPath
                    PublishReadyPath = [string]$_.PublishReadyPath
                    PublishedArchivePath = [string]$_.PublishedArchivePath
                    CheckScriptPath = [string]$_.CheckScriptPath
                    SubmitScriptPath = [string]$_.SubmitScriptPath
                    CheckCmdPath = [string]$_.CheckCmdPath
                    SubmitCmdPath = [string]$_.SubmitCmdPath
                    ReviewZipPreviewPath = [string]$_.ReviewZipPreviewPath
                    InitialInstructionPath = [string]$_.InitialInstructionPath
                    InitialMessagePath = [string]$_.InitialMessagePath
                    HandoffMessagePattern = [string]$_.HandoffMessagePattern
                    RequestPath = [string]$_.RequestPath
                    PromptPath = [string]$_.PromptPath
                    DonePath = [string]$_.DonePath
                    ErrorPath = [string]$_.ErrorPath
                    ResultPath = [string]$_.ResultPath
                    PairActivation = $pairActivationMap[[string]$_.PairId]
                    PathState = $_.PathState
                    Initial = $_.Initial
                    Handoff = $_.Handoff
                    OneTimeQueue = $_.OneTimeQueue
                }
            }
        }
    )
}

if ($AsJson) {
    $effectiveConfig | ConvertTo-Json -Depth 8
    return
}

Write-Host 'Effective Config'
Write-Host ("Schema Version: {0}" -f [string]$effectiveConfig.SchemaVersion)
Write-Host ("Generated At: {0}" -f [string]$effectiveConfig.GeneratedAt)
Write-Host ("Lane: {0}" -f [string]$effectiveConfig.Config.LaneName)
Write-Host ("Config: {0}" -f [string]$effectiveConfig.Config.ConfigPath)
Write-Host ("Config Hash: {0}" -f [string]$effectiveConfig.Config.ConfigHash)
Write-Host ("Window Prefix: {0}" -f [string]$effectiveConfig.Config.WindowTitlePrefix)
Write-Host ("Binding Profile: {0}" -f [string]$effectiveConfig.Config.BindingProfilePath)
Write-Host ("Launcher Wrapper: {0}" -f [string]$effectiveConfig.Config.LauncherWrapperPath)
Write-Host ("Selected Run Root: {0} ({1})" -f [string]$effectiveConfig.RunContext.SelectedRunRoot, [string]$effectiveConfig.RunContext.SelectedRunRootSource)
Write-Host ("Selected Run Root Last Write: {0}" -f [string]$effectiveConfig.RunContext.SelectedRunRootLastWriteAt)
Write-Host ("Selected Run Root Age Seconds: {0}" -f [string]$effectiveConfig.RunContext.SelectedRunRootAgeSeconds)
Write-Host ("Selected Run Root Is Stale: {0}" -f [bool]$effectiveConfig.RunContext.SelectedRunRootIsStale)
Write-Host ("Stale Run Threshold Seconds: {0}" -f [int]$effectiveConfig.RunContext.StaleRunThresholdSec)
Write-Host ("Latest Existing Run: {0}" -f [string]$effectiveConfig.RunContext.LatestExistingRunRoot)
Write-Host ("Next Run Root Preview: {0}" -f [string]$effectiveConfig.RunContext.NextRunRootPreview)
Write-Host ("Manifest: {0}" -f [string]$effectiveConfig.RunContext.ManifestPath)
Write-Host ("Pair Definition Source: {0}" -f [string]$effectiveConfig.PairDefinitionSource)
Write-Host ("Headless Enabled: {0}" -f [bool]$effectiveConfig.PairTest.HeadlessExec.Enabled)
Write-Host ("Summary File: {0}" -f [string]$effectiveConfig.PairTest.SummaryFileName)
Write-Host ("Review Folder: {0}" -f [string]$effectiveConfig.PairTest.ReviewFolderName)
Write-Host ("Message Folder: {0}" -f [string]$effectiveConfig.PairTest.MessageFolderName)
Write-Host ("Review Zip Pattern: {0}" -f [string]$effectiveConfig.PairTest.ReviewZipPattern)
Write-Host ("One-Time Queue Pairs: {0}" -f ((@($effectiveConfig.OneTimeQueueSummary | ForEach-Object { [string]$_.PairId }) -join ', ')))
Write-Host ("Pair Activation Pairs: {0}" -f ((@($effectiveConfig.PairActivationSummary | ForEach-Object { [string]$_.PairId }) -join ', ')))
Write-Host ("Warnings: {0}" -f $(if (@($effectiveConfig.Warnings).Count -gt 0) { (@($effectiveConfig.Warnings) -join ' | ') } else { '(none)' }))
Write-Host ("Highest Warning Severity: {0}" -f [string]$effectiveConfig.WarningSummary.HighestSeverity)
Write-Host ("Highest Warning Decision: {0}" -f [string]$effectiveConfig.WarningSummary.HighestDecision)
Write-Host ("Highest Warning Code: {0}" -f [string]$effectiveConfig.WarningSummary.HighestCode)
Write-Host ("Evidence Snapshot Recommended: {0}" -f [bool]$effectiveConfig.EvidencePolicy.Recommended)
Write-Host ("Evidence Snapshot Root: {0}" -f [string]$effectiveConfig.EvidencePolicy.EvidenceSnapshotRoot)
Write-Host ("Requested Pair Filter: {0}" -f $(if (@($effectiveConfig.RequestedFilters.PairIds).Count -gt 0) { (@($effectiveConfig.RequestedFilters.PairIds) -join ', ') } else { '(none)' }))
Write-Host ("Requested Target Filter: {0}" -f $(if (Test-NonEmptyString ([string]$effectiveConfig.RequestedFilters.TargetId)) { [string]$effectiveConfig.RequestedFilters.TargetId } else { '(none)' }))
Write-Host ("Requested Mode: {0}" -f [string]$effectiveConfig.RequestedFilters.Mode)
Write-Host ''
Write-Host 'Pair Overview'
foreach ($pair in @($effectiveConfig.OverviewPairs)) {
    $activation = @($effectiveConfig.PairActivationSummary | Where-Object { [string]$_.PairId -eq [string]$pair.PairId } | Select-Object -First 1)
    if ($activation.Count -gt 0) {
        Write-Host ("- {0}: {1} (top) <-> {2} (bottom) / state={3} / enabled={4}" -f [string]$pair.PairId, [string]$pair.TopTargetId, [string]$pair.BottomTargetId, [string]$activation[0].State, [bool]$activation[0].EffectiveEnabled)
    }
    else {
        Write-Host ("- {0}: {1} (top) <-> {2} (bottom)" -f [string]$pair.PairId, [string]$pair.TopTargetId, [string]$pair.BottomTargetId)
    }
}

Write-Host ''
Write-Host ("Preview Mode: {0}" -f $Mode)
foreach ($row in @($effectiveConfig.PreviewRows)) {
    Write-Host ''
    Write-Host ("[{0} / {1} / {2} -> {3}]" -f [string]$row.PairId, [string]$row.RoleName, [string]$row.TargetId, [string]$row.PartnerTargetId)
    if (Test-NonEmptyString ([string]$row.WindowTitle)) {
        Write-Host ("Window Title: {0}" -f [string]$row.WindowTitle)
    }
    if ($row.PSObject.Properties.Name -contains 'InboxFolder' -and (Test-NonEmptyString ([string]$row.InboxFolder))) {
        Write-Host ("Inbox Folder: {0}" -f [string]$row.InboxFolder)
    }
    Write-Host ("Pair Target Folder: {0}" -f [string]$row.PairTargetFolder)
    Write-Host ("Partner Folder: {0}" -f [string]$row.PartnerFolder)
    if ($row.PSObject.Properties.Name -contains 'PairActivation' -and $null -ne $row.PairActivation) {
        Write-Host ("Pair Activation: state={0} enabled={1} reason={2}" -f [string]$row.PairActivation.State, [bool]$row.PairActivation.EffectiveEnabled, [string]$row.PairActivation.DisableReason)
    }
    Write-Host ("Summary Path: {0}" -f [string]$row.SummaryPath)
    Write-Host ("Review Folder: {0}" -f [string]$row.ReviewFolderPath)
    if ($row.PSObject.Properties.Name -contains 'WorkFolderPath') {
        Write-Host ("Work Folder: {0}" -f [string]$row.WorkFolderPath)
    }
    if ($row.PSObject.Properties.Name -contains 'SourceOutboxPath') {
        Write-Host ("Source Outbox Path: {0}" -f [string]$row.SourceOutboxPath)
        Write-Host ("Source Summary Path: {0}" -f [string]$row.SourceSummaryPath)
        Write-Host ("Source Review Zip Path: {0}" -f [string]$row.SourceReviewZipPath)
        Write-Host ("Publish Ready Path: {0}" -f [string]$row.PublishReadyPath)
        Write-Host ("Published Archive Path: {0}" -f [string]$row.PublishedArchivePath)
    }
    if ($row.PSObject.Properties.Name -contains 'CheckScriptPath') {
        Write-Host ("Check Script Path: {0}" -f [string]$row.CheckScriptPath)
        Write-Host ("Submit Script Path: {0}" -f [string]$row.SubmitScriptPath)
        Write-Host ("Check Cmd Path: {0}" -f [string]$row.CheckCmdPath)
        Write-Host ("Submit Cmd Path: {0}" -f [string]$row.SubmitCmdPath)
    }
    if ($row.PSObject.Properties.Name -contains 'ReviewZipPreviewPath') {
        Write-Host ("Review Zip Preview: {0}" -f [string]$row.ReviewZipPreviewPath)
    }
    if ($row.PSObject.Properties.Name -contains 'InitialInstructionPath') {
        Write-Host ("Initial Instruction Path: {0}" -f [string]$row.InitialInstructionPath)
        Write-Host ("Initial Message Path: {0}" -f [string]$row.InitialMessagePath)
        Write-Host ("Request Path: {0}" -f [string]$row.RequestPath)
        Write-Host ("Prompt Path: {0}" -f [string]$row.PromptPath)
    }
    if ($row.PSObject.Properties.Name -contains 'HandoffMessagePattern') {
        Write-Host ("Handoff Message Pattern: {0}" -f [string]$row.HandoffMessagePattern)
        Write-Host ("Done Path: {0}" -f [string]$row.DonePath)
        Write-Host ("Error Path: {0}" -f [string]$row.ErrorPath)
        Write-Host ("Result Path: {0}" -f [string]$row.ResultPath)
    }

    if ($Mode -eq 'both' -or $Mode -eq 'initial') {
        Write-Host ("Initial Override Sources: {0}" -f ((@($row.Initial.AppliedSources) -join ', ')))
        Write-Host ("Initial Message Plan: {0}" -f ((@($row.Initial.MessagePlan.Order) -join ' -> ')))
        Write-Host ("Initial One-Time Items: {0}" -f $(if (@($row.Initial.PendingOneTimeItems).Count -gt 0) { (@($row.Initial.PendingOneTimeItems | ForEach-Object { [string]$_.Id }) -join ', ') } else { '(none)' }))
        Write-Host 'Initial Preview:'
        Write-Host ([string]$row.Initial.Preview)
    }

    if ($Mode -eq 'both' -or $Mode -eq 'handoff') {
        Write-Host ("Handoff Override Sources: {0}" -f ((@($row.Handoff.AppliedSources) -join ', ')))
        Write-Host ("Handoff Message Plan: {0}" -f ((@($row.Handoff.MessagePlan.Order) -join ' -> ')))
        Write-Host ("Handoff One-Time Items: {0}" -f $(if (@($row.Handoff.PendingOneTimeItems).Count -gt 0) { (@($row.Handoff.PendingOneTimeItems | ForEach-Object { [string]$_.Id }) -join ', ') } else { '(none)' }))
        Write-Host 'Handoff Preview:'
        Write-Host ([string]$row.Handoff.Preview)
    }
}
