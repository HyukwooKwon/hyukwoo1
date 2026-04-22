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

function Resolve-PairRunRootPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$RunRoot,
        [Parameter(Mandatory)]$PairTest
    )

    if (Test-NonEmptyString $RunRoot) {
        return (Resolve-FullPathFromBase -PathValue $RunRoot -BasePath $Root)
    }

    $baseRoot = Resolve-FullPathFromBase `
        -PathValue ([string](Get-ConfigValue -Object $PairTest -Name 'RunRootBase' -DefaultValue (Join-Path $Root 'pair-test'))) `
        -BasePath $Root
    $pattern = [string](Get-ConfigValue -Object $PairTest -Name 'RunRootPattern' -DefaultValue 'run_{yyyyMMdd_HHmmss}')
    return [System.IO.Path]::GetFullPath((Join-Path $baseRoot (Expand-RunRootPattern -Pattern $pattern)))
}

function Resolve-PairTestConfig {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ConfigPath,
        $ManifestPairTest = $null
    )

    $configPairTest = @{}
    if ($null -eq $ManifestPairTest -and (Test-NonEmptyString $ConfigPath)) {
        $config = Import-PowerShellDataFile -Path $ConfigPath
        $configPairTest = Get-ConfigValue -Object $config -Name 'PairTest' -DefaultValue @{}
    }

    $source = if ($null -ne $ManifestPairTest) { $ManifestPairTest } else { $configPairTest }
    $messageTemplates = Get-ConfigValue -Object $source -Name 'MessageTemplates' -DefaultValue @{}
    $headlessExec = Get-ConfigValue -Object $source -Name 'HeadlessExec' -DefaultValue @{}
    $initialTemplate = Get-ConfigValue -Object $messageTemplates -Name 'Initial' -DefaultValue @{}
    $handoffTemplate = Get-ConfigValue -Object $messageTemplates -Name 'Handoff' -DefaultValue @{}
    $runRootBase = Resolve-FullPathFromBase `
        -PathValue ([string](Get-ConfigValue -Object $source -Name 'RunRootBase' -DefaultValue (Join-Path $Root 'pair-test'))) `
        -BasePath $Root

    return [pscustomobject]@{
        RunRootBase       = $runRootBase
        RunRootPattern    = [string](Get-ConfigValue -Object $source -Name 'RunRootPattern' -DefaultValue 'run_{yyyyMMdd_HHmmss}')
        SummaryFileName   = [string](Get-ConfigValue -Object $source -Name 'SummaryFileName' -DefaultValue 'summary.txt')
        ReviewFolderName  = [string](Get-ConfigValue -Object $source -Name 'ReviewFolderName' -DefaultValue 'reviewfile')
        WorkFolderName    = [string](Get-ConfigValue -Object $source -Name 'WorkFolderName' -DefaultValue 'work')
        MessageFolderName = [string](Get-ConfigValue -Object $source -Name 'MessageFolderName' -DefaultValue 'messages')
        ReviewZipPattern  = [string](Get-ConfigValue -Object $source -Name 'ReviewZipPattern' -DefaultValue 'review_{TargetId}_{yyyyMMdd_HHmmss}_{Guid}.zip')
        CheckScriptFileName = [string](Get-ConfigValue -Object $source -Name 'CheckScriptFileName' -DefaultValue 'check-artifact.ps1')
        SubmitScriptFileName = [string](Get-ConfigValue -Object $source -Name 'SubmitScriptFileName' -DefaultValue 'submit-artifact.ps1')
        CheckCmdFileName  = [string](Get-ConfigValue -Object $source -Name 'CheckCmdFileName' -DefaultValue 'check-artifact.cmd')
        SubmitCmdFileName = [string](Get-ConfigValue -Object $source -Name 'SubmitCmdFileName' -DefaultValue 'submit-artifact.cmd')
        SourceOutboxFolderName = [string](Get-ConfigValue -Object $source -Name 'SourceOutboxFolderName' -DefaultValue 'source-outbox')
        SourceSummaryFileName = [string](Get-ConfigValue -Object $source -Name 'SourceSummaryFileName' -DefaultValue 'summary.txt')
        SourceReviewZipFileName = [string](Get-ConfigValue -Object $source -Name 'SourceReviewZipFileName' -DefaultValue 'review.zip')
        PublishReadyFileName = [string](Get-ConfigValue -Object $source -Name 'PublishReadyFileName' -DefaultValue 'publish.ready.json')
        PublishedArchiveFolderName = [string](Get-ConfigValue -Object $source -Name 'PublishedArchiveFolderName' -DefaultValue '.published')
        DefaultSeedWorkRepoRoot = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')
        DefaultSeedReviewInputPath = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputPath' -DefaultValue '')
        DefaultSeedReviewInputSearchRelativePath = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputSearchRelativePath' -DefaultValue 'reviewfile')
        DefaultSeedReviewInputFilter = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputFilter' -DefaultValue '*.zip')
        DefaultSeedReviewInputNameRegex = [string](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputNameRegex' -DefaultValue '')
        DefaultSeedReviewInputMaxAgeHours = [double](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputMaxAgeHours' -DefaultValue 72)
        DefaultSeedReviewInputRequireSingleCandidate = [bool](Get-ConfigValue -Object $source -Name 'DefaultSeedReviewInputRequireSingleCandidate' -DefaultValue $false)
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
    foreach ($overrideSource in $overrideSources) {
        foreach ($block in @(Get-StringArray (Get-ConfigValue -Object $overrideSource -Name $extraPropertyName -DefaultValue @()))) {
            $extraBlocks.Add([string]$block)
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
