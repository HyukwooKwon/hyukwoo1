[CmdletBinding()]
param(
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

function Normalize-MultilineText {
    param([Parameter(Mandatory)][string]$Value)

    return (($Value -replace "`r?`n", "`r`n").TrimEnd([char[]]"`r`n"))
}

function Compose-RelayPayloadPreview {
    param(
        [Parameter(Mandatory)][string]$Body,
        [AllowEmptyString()][string]$FixedSuffix = ''
    )

    $normalizedBody = Normalize-MultilineText -Value $Body
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
    if ($null -ne $Target.FixedSuffix) {
        $targetFixedSuffix = [string]$Target.FixedSuffix
        if ($targetFixedSuffix.Trim() -eq $placeholderFixedSuffix) {
            return ''
        }

        return $targetFixedSuffix
    }

    $defaultFixedSuffix = [string]$Config.DefaultFixedSuffix
    if ($defaultFixedSuffix.Trim() -eq $placeholderFixedSuffix) {
        return ''
    }

    return $defaultFixedSuffix
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$baseConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$tempWorkRepoRoot = Join-Path 'C:\dev\python\_relay-test-fixtures' ('paired-exchange-target-instructions-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempWorkRepoRoot -Force | Out-Null
$seedReviewInputPath = Join-Path $tempWorkRepoRoot 'reviewfile\seed-review-input.txt'
New-Item -ItemType Directory -Path (Split-Path -Parent $seedReviewInputPath) -Force | Out-Null
'fixture seed review input' | Set-Content -LiteralPath $seedReviewInputPath -Encoding UTF8
$externalizedConfigPath = Join-Path $tempWorkRepoRoot '.relay-config\bottest-live-visible\settings.externalized.psd1'
& (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath $baseConfigPath `
    -WorkRepoRoot $tempWorkRepoRoot `
    -OutputConfigPath $externalizedConfigPath `
    -ReviewInputPath $seedReviewInputPath | Out-Null

$resolvedConfigPath = (Resolve-Path -LiteralPath $externalizedConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_target_instructions_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$seedWorkRepoRoot = $tempWorkRepoRoot
$seedTaskText = '검토파일내용을 확인 후 프로젝트에 맞는 부분만 선별 적용하세요.'

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 `
    -SeedWorkRepoRoot $seedWorkRepoRoot `
    -SeedReviewInputPath $seedReviewInputPath `
    -SeedTaskText $seedTaskText | Out-Null

$targetRoot = Join-Path $contractRunRoot 'pair01\target01'
$partnerRoot = Join-Path $contractRunRoot 'pair01\target05'
$requestPath = Join-Path $targetRoot 'request.json'
$partnerRequestPath = Join-Path $partnerRoot 'request.json'
$instructionPath = Join-Path $targetRoot 'instructions.txt'
$partnerInstructionPath = Join-Path $partnerRoot 'instructions.txt'
$manifestPath = Join-Path $contractRunRoot 'manifest.json'

$request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$partnerRequest = Get-Content -LiteralPath $partnerRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$instructions = Get-Content -LiteralPath $instructionPath -Raw -Encoding UTF8
$partnerInstructions = Get-Content -LiteralPath $partnerInstructionPath -Raw -Encoding UTF8
$messageText = Get-Content -LiteralPath ([string]$request.MessagePath) -Raw -Encoding UTF8
$partnerMessageText = Get-Content -LiteralPath ([string]$partnerRequest.MessagePath) -Raw -Encoding UTF8
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifestTarget = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)
$partnerManifestTarget = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target05' } | Select-Object -First 1)

Assert-True ($manifestTarget.Count -eq 1) 'manifest target01 row should exist.'
Assert-True ($partnerManifestTarget.Count -eq 1) 'manifest target05 row should exist.'
$manifestTarget = $manifestTarget[0]
$partnerManifestTarget = $partnerManifestTarget[0]

$expectedSummaryPath = Join-Path $targetRoot 'summary.txt'
$expectedReviewFolderPath = Join-Path $targetRoot 'reviewfile'
$expectedWorkFolderPath = Join-Path $targetRoot 'work'
$expectedContractRoot = Join-Path $tempWorkRepoRoot (Join-Path '.relay-contract\bottest-live-visible' ((Split-Path -Leaf $contractRunRoot) + '\pair01\target01'))
$expectedPartnerContractRoot = Join-Path $tempWorkRepoRoot (Join-Path '.relay-contract\bottest-live-visible' ((Split-Path -Leaf $contractRunRoot) + '\pair01\target05'))
$expectedSourceOutboxPath = Join-Path $expectedContractRoot 'source-outbox'
$expectedSourceSummaryPath = Join-Path $expectedSourceOutboxPath 'summary.txt'
$expectedSourceReviewZipPath = Join-Path $expectedSourceOutboxPath 'review.zip'
$expectedPublishReadyPath = Join-Path $expectedSourceOutboxPath 'publish.ready.json'
$expectedPublishedArchivePath = Join-Path $expectedSourceOutboxPath '.published'
$expectedDonePath = Join-Path $targetRoot 'done.json'
$expectedResultPath = Join-Path $targetRoot 'result.json'
$expectedCheckScriptPath = Join-Path $targetRoot 'check-artifact.ps1'
$expectedSubmitScriptPath = Join-Path $targetRoot 'submit-artifact.ps1'
$expectedCheckCmdPath = Join-Path $targetRoot 'check-artifact.cmd'
$expectedSubmitCmdPath = Join-Path $targetRoot 'submit-artifact.cmd'

Assert-True ([string]$request.SummaryPath -eq $expectedSummaryPath) 'request should contain absolute SummaryPath.'
Assert-True ([string]$request.ReviewFolderPath -eq $expectedReviewFolderPath) 'request should contain absolute ReviewFolderPath.'
Assert-True ([string]$request.WorkFolderPath -eq $expectedWorkFolderPath) 'request should contain WorkFolderPath.'
Assert-True ([string]$request.SourceOutboxPath -eq $expectedSourceOutboxPath) 'request should contain SourceOutboxPath.'
Assert-True ([string]$request.SourceSummaryPath -eq $expectedSourceSummaryPath) 'request should contain SourceSummaryPath.'
Assert-True ([string]$request.SourceReviewZipPath -eq $expectedSourceReviewZipPath) 'request should contain SourceReviewZipPath.'
Assert-True ([string]$request.PublishReadyPath -eq $expectedPublishReadyPath) 'request should contain PublishReadyPath.'
Assert-True ([string]$request.PublishedArchivePath -eq $expectedPublishedArchivePath) 'request should contain PublishedArchivePath.'
Assert-True ([bool]$request.SeedEnabled) 'seed target request should enable seed mode.'
Assert-True ([string]$request.SeedTargetId -eq 'target01') 'seed target request should record SeedTargetId.'
Assert-True ([string]$request.InitialRoleMode -eq 'seed') 'seed target request should use seed mode.'
Assert-True ([string]$request.WorkRepoRoot -eq $seedWorkRepoRoot) 'seed target request should contain WorkRepoRoot.'
Assert-True ([string]$request.ReviewInputPath -eq $seedReviewInputPath) 'seed target request should contain ReviewInputPath.'
Assert-True ([string]$request.SeedTaskText -eq $seedTaskText) 'seed target request should contain SeedTaskText.'
Assert-True ([string]$request.WorkFolderName -eq 'work') 'request should contain WorkFolderName.'
Assert-True ([string]$request.DoneFilePath -eq $expectedDonePath) 'request should contain DoneFilePath.'
Assert-True ([string]$request.ResultFilePath -eq $expectedResultPath) 'request should contain ResultFilePath.'
Assert-True ([string]$request.CheckScriptPath -eq $expectedCheckScriptPath) 'request should contain CheckScriptPath.'
Assert-True ([string]$request.SubmitScriptPath -eq $expectedSubmitScriptPath) 'request should contain SubmitScriptPath.'
Assert-True ([string]$request.CheckCmdPath -eq $expectedCheckCmdPath) 'request should contain CheckCmdPath.'
Assert-True ([string]$request.SubmitCmdPath -eq $expectedSubmitCmdPath) 'request should contain SubmitCmdPath.'
Assert-True ((Test-Path -LiteralPath ([string]$request.MessagePath) -PathType Leaf)) 'message file should be created for the target.'
Assert-True ((Test-Path -LiteralPath $expectedWorkFolderPath -PathType Container)) 'work folder should be created for the target.'
Assert-True ((Test-Path -LiteralPath $expectedSourceOutboxPath -PathType Container)) 'source-outbox folder should be created for the target.'
Assert-True ((Test-Path -LiteralPath $expectedPublishedArchivePath -PathType Container)) 'published archive folder should be created for the target.'
Assert-True ((Test-Path -LiteralPath $expectedCheckScriptPath -PathType Leaf)) 'check script should be created for the target.'
Assert-True ((Test-Path -LiteralPath $expectedSubmitScriptPath -PathType Leaf)) 'submit script should be created for the target.'
Assert-True ((Test-Path -LiteralPath $expectedCheckCmdPath -PathType Leaf)) 'check cmd launcher should be created for the target.'
Assert-True ((Test-Path -LiteralPath $expectedSubmitCmdPath -PathType Leaf)) 'submit cmd launcher should be created for the target.'

Assert-True ([string]$manifestTarget.SummaryPath -eq $expectedSummaryPath) 'manifest target row should echo SummaryPath.'
Assert-True ([string]$manifestTarget.ReviewFolderPath -eq $expectedReviewFolderPath) 'manifest target row should echo ReviewFolderPath.'
Assert-True ([string]$manifestTarget.WorkFolderPath -eq $expectedWorkFolderPath) 'manifest target row should echo WorkFolderPath.'
Assert-True ([string]$manifestTarget.SourceOutboxPath -eq $expectedSourceOutboxPath) 'manifest target row should echo SourceOutboxPath.'
Assert-True ([string]$manifestTarget.SourceSummaryPath -eq $expectedSourceSummaryPath) 'manifest target row should echo SourceSummaryPath.'
Assert-True ([string]$manifestTarget.SourceReviewZipPath -eq $expectedSourceReviewZipPath) 'manifest target row should echo SourceReviewZipPath.'
Assert-True ([string]$manifestTarget.PublishReadyPath -eq $expectedPublishReadyPath) 'manifest target row should echo PublishReadyPath.'
Assert-True ([string]$manifestTarget.PublishedArchivePath -eq $expectedPublishedArchivePath) 'manifest target row should echo PublishedArchivePath.'
Assert-True ([string]$manifestTarget.ContractPathMode -eq 'external-workrepo') 'manifest target row should mark external contract mode.'
Assert-True ([string]$manifestTarget.ContractRootPath -eq $expectedContractRoot) 'manifest target row should echo external contract root.'
Assert-True ([bool]$manifestTarget.SeedEnabled) 'manifest target row should mark seed-enabled target.'
Assert-True ([string]$manifestTarget.SeedTargetId -eq 'target01') 'manifest target row should echo SeedTargetId.'
Assert-True ([string]$manifestTarget.InitialRoleMode -eq 'seed') 'manifest target row should echo seed role mode.'
Assert-True ([string]$manifestTarget.WorkRepoRoot -eq $seedWorkRepoRoot) 'manifest target row should echo WorkRepoRoot.'
Assert-True ([string]$manifestTarget.ReviewInputPath -eq $seedReviewInputPath) 'manifest target row should echo ReviewInputPath.'
Assert-True ([string]$manifestTarget.CheckScriptPath -eq $expectedCheckScriptPath) 'manifest target row should echo CheckScriptPath.'
Assert-True ([string]$manifestTarget.SubmitScriptPath -eq $expectedSubmitScriptPath) 'manifest target row should echo SubmitScriptPath.'
Assert-True ([string]$manifestTarget.CheckCmdPath -eq $expectedCheckCmdPath) 'manifest target row should echo CheckCmdPath.'
Assert-True ([string]$manifestTarget.SubmitCmdPath -eq $expectedSubmitCmdPath) 'manifest target row should echo SubmitCmdPath.'

Assert-True ($instructions.Contains("SummaryPath: $expectedSummaryPath")) 'instructions should contain absolute SummaryPath.'
Assert-True ($instructions.Contains("ReviewFolderPath: $expectedReviewFolderPath")) 'instructions should contain absolute ReviewFolderPath.'
Assert-True ($instructions.Contains("DoneFilePath: $expectedDonePath")) 'instructions should contain absolute DoneFilePath.'
Assert-True ($instructions.Contains("ResultFilePath: $expectedResultPath")) 'instructions should contain absolute ResultFilePath.'
Assert-True ($instructions.Contains("WorkFolderPath: $expectedWorkFolderPath")) 'instructions should contain WorkFolderPath.'
Assert-True ($instructions.Contains("SourceOutboxPath: $expectedSourceOutboxPath")) 'instructions should contain SourceOutboxPath.'
Assert-True ($instructions.Contains("SourceSummaryPath: $expectedSourceSummaryPath")) 'instructions should contain SourceSummaryPath.'
Assert-True ($instructions.Contains("SourceReviewZipPath: $expectedSourceReviewZipPath")) 'instructions should contain SourceReviewZipPath.'
Assert-True ($instructions.Contains("PublishReadyPath: $expectedPublishReadyPath")) 'instructions should contain PublishReadyPath.'
Assert-True ($instructions.Contains("PublishedArchivePath: $expectedPublishedArchivePath")) 'instructions should contain PublishedArchivePath.'
Assert-True ($instructions.Contains('[initial-role]')) 'instructions should contain the primary role block.'
Assert-True ($instructions.Contains('mode: seed')) 'seed target instructions should use seed mode.'
Assert-True ($instructions.Contains("WorkRepoRoot: $seedWorkRepoRoot")) 'seed target instructions should contain WorkRepoRoot.'
Assert-True ($instructions.Contains("ReviewInputPath: $seedReviewInputPath")) 'seed target instructions should contain ReviewInputPath.'
Assert-True ($instructions.Contains($seedTaskText)) 'seed target instructions should contain SeedTaskText.'
Assert-True ($instructions.Contains("CheckScriptPath: $expectedCheckScriptPath")) 'instructions should contain CheckScriptPath.'
Assert-True ($instructions.Contains("SubmitScriptPath: $expectedSubmitScriptPath")) 'instructions should contain SubmitScriptPath.'
Assert-True ($instructions.Contains("CheckCmdPath: $expectedCheckCmdPath")) 'instructions should contain CheckCmdPath.'
Assert-True ($instructions.Contains("SubmitCmdPath: $expectedSubmitCmdPath")) 'instructions should contain SubmitCmdPath.'
Assert-True ($instructions.Contains('일반 프로젝트 폴더나 다른 target 폴더에만 파일을 만들고 끝내면 watcher가 인식하지 않습니다.')) 'instructions should warn that general project folders are not watched.'
Assert-True ($instructions.Contains('publish 완료 신호는')) 'instructions should guide the source-outbox publish flow.'
Assert-True ($instructions.Contains('자동 publish가 실패하거나 legacy RunRoot 복구가 필요할 때만')) 'instructions should keep wrappers as recovery only.'

$relayTarget = @($config.Targets | Where-Object { [string]$_.Id -eq 'target01' } | Select-Object -First 1)
Assert-True ($relayTarget.Count -eq 1) 'relay config target01 row should exist.'
$fixedSuffix = Get-EffectiveRelayPayloadPreviewFixedSuffix -Config $config -Target $relayTarget[0]
$payloadPreview = Compose-RelayPayloadPreview -Body $messageText -FixedSuffix $fixedSuffix
$payloadBytes = [System.Text.UTF8Encoding]::new($false).GetByteCount($payloadPreview)
$partnerPayloadPreview = Compose-RelayPayloadPreview -Body $partnerMessageText -FixedSuffix $fixedSuffix
$partnerPayloadBytes = [System.Text.UTF8Encoding]::new($false).GetByteCount($partnerPayloadPreview)

Assert-True ($messageText.Contains('[paired-exchange-seed]')) 'message should use the short seed format.'
Assert-True ($messageText.Contains("WorkRepoRoot: $seedWorkRepoRoot")) 'seed message should contain WorkRepoRoot.'
Assert-True ($messageText.Contains("ReviewInputPath: $seedReviewInputPath")) 'seed message should contain ReviewInputPath.'
Assert-True ($messageText.Contains($seedTaskText)) 'seed message should contain SeedTaskText.'
Assert-True ($messageText.Contains("SourceOutboxPath: $expectedSourceOutboxPath")) 'message should contain SourceOutboxPath.'
Assert-True ($messageText.Contains("publish.ready.json: $expectedPublishReadyPath")) 'message should contain PublishReadyPath.'
Assert-True ($messageText.Contains("instructions.txt 를 확인하세요: $instructionPath")) 'message should point to instructions.txt for the full contract.'
Assert-True (-not $messageText.Contains("SummaryPath: $expectedSummaryPath")) 'message should not inline the full contract SummaryPath.'
Assert-True (-not $messageText.Contains("ReviewFolderPath: $expectedReviewFolderPath")) 'message should not inline the full contract ReviewFolderPath.'
Assert-True ($payloadPreview.Length -lt [int]$config.MaxPayloadChars) 'message payload should stay under router char limit.'
Assert-True ($payloadBytes -lt [int]$config.MaxPayloadBytes) 'message payload should stay under router byte limit.'

Assert-True (-not [bool]$partnerRequest.SeedEnabled) 'partner request should not be seed-enabled.'
Assert-True ([string]$partnerRequest.SeedTargetId -eq 'target01') 'partner request should still record the shared SeedTargetId.'
Assert-True ([string]$partnerRequest.InitialRoleMode -eq 'handoff_wait') 'partner request should use handoff-wait mode.'
Assert-True ([string]$partnerRequest.WorkRepoRoot -eq $seedWorkRepoRoot) 'partner request should carry the external WorkRepoRoot for explicit contract paths.'
Assert-True ([string]$partnerRequest.ReviewInputPath -eq '') 'partner request should not carry ReviewInputPath.'
Assert-True ([string]$partnerRequest.SeedTaskText -eq '') 'partner request should not carry SeedTaskText.'
Assert-True (-not [bool]$partnerManifestTarget.SeedEnabled) 'partner manifest row should not be seed-enabled.'
Assert-True ([string]$partnerManifestTarget.InitialRoleMode -eq 'handoff_wait') 'partner manifest row should use handoff-wait mode.'
Assert-True ($partnerInstructions.Contains('mode: handoff-wait')) 'partner instructions should use handoff-wait mode.'
Assert-True ($partnerInstructions.Contains('partner handoff message가 오기 전까지 작업을 시작하지 마세요.')) 'partner instructions should explicitly wait for handoff.'
Assert-True (-not $partnerInstructions.Contains("ReviewInputPath: $seedReviewInputPath")) 'partner instructions should not include seed ReviewInputPath.'
Assert-True ($partnerInstructions.Contains("SourceOutboxPath: $(Join-Path $expectedPartnerContractRoot 'source-outbox')")) 'partner instructions should point to external contract outbox.'
Assert-True ($partnerMessageText.Contains('[handoff-wait]')) 'partner initial message should be a handoff-wait notice.'
Assert-True ($partnerMessageText.Contains('partner handoff message가 오기 전까지 작업을 시작하지 마세요.')) 'partner initial message should tell the target to wait.'
Assert-True (-not $partnerMessageText.Contains($seedTaskText)) 'partner initial message should not include the seed task text.'
Assert-True ($partnerPayloadPreview.Length -lt [int]$config.MaxPayloadChars) 'partner message payload should stay under router char limit.'
Assert-True ($partnerPayloadBytes -lt [int]$config.MaxPayloadBytes) 'partner message payload should stay under router byte limit.'

$effectiveConfig = & (Join-Path $root 'show-effective-config.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -TargetId target01 `
    -AsJson | ConvertFrom-Json
$previewRows = @($effectiveConfig.PreviewRows)
Assert-True ($previewRows.Count -eq 1) 'effective config should return exactly one preview row for target01.'
$previewRow = $previewRows[0]
Assert-True ([string]$previewRow.WorkFolderPath -eq $expectedWorkFolderPath) 'effective config preview row should contain WorkFolderPath.'
Assert-True ([string]$previewRow.SourceOutboxPath -eq $expectedSourceOutboxPath) 'effective config preview row should contain SourceOutboxPath.'
Assert-True ([string]$previewRow.SourceSummaryPath -eq $expectedSourceSummaryPath) 'effective config preview row should contain SourceSummaryPath.'
Assert-True ([string]$previewRow.SourceReviewZipPath -eq $expectedSourceReviewZipPath) 'effective config preview row should contain SourceReviewZipPath.'
Assert-True ([string]$previewRow.PublishReadyPath -eq $expectedPublishReadyPath) 'effective config preview row should contain PublishReadyPath.'
Assert-True ([string]$previewRow.PublishedArchivePath -eq $expectedPublishedArchivePath) 'effective config preview row should contain PublishedArchivePath.'
Assert-True ([string]$previewRow.CheckScriptPath -eq $expectedCheckScriptPath) 'effective config preview row should contain CheckScriptPath.'
Assert-True ([string]$previewRow.SubmitScriptPath -eq $expectedSubmitScriptPath) 'effective config preview row should contain SubmitScriptPath.'
Assert-True ([string]$previewRow.CheckCmdPath -eq $expectedCheckCmdPath) 'effective config preview row should contain CheckCmdPath.'
Assert-True ([string]$previewRow.SubmitCmdPath -eq $expectedSubmitCmdPath) 'effective config preview row should contain SubmitCmdPath.'
Assert-True ([bool]$previewRow.PathState.WorkFolder.Exists) 'effective config path state should report WorkFolder exists.'
Assert-True ([bool]$previewRow.PathState.SourceOutbox.Exists) 'effective config path state should report SourceOutbox exists.'
Assert-True (-not [bool]$previewRow.PathState.SourceSummary.Exists) 'effective config path state should report SourceSummary missing before publish.'
Assert-True (-not [bool]$previewRow.PathState.SourceReviewZip.Exists) 'effective config path state should report SourceReviewZip missing before publish.'
Assert-True (-not [bool]$previewRow.PathState.PublishReady.Exists) 'effective config path state should report PublishReady missing before publish.'
Assert-True ([bool]$previewRow.PathState.PublishedArchive.Exists) 'effective config path state should report PublishedArchive exists.'
Assert-True ([bool]$previewRow.PathState.CheckScript.Exists) 'effective config path state should report CheckScript exists.'
Assert-True ([bool]$previewRow.PathState.SubmitScript.Exists) 'effective config path state should report SubmitScript exists.'
Assert-True ([bool]$previewRow.PathState.CheckCmd.Exists) 'effective config path state should report CheckCmd exists.'
Assert-True ([bool]$previewRow.PathState.SubmitCmd.Exists) 'effective config path state should report SubmitCmd exists.'

Write-Host ('paired-exchange target instructions contract ok: runRoot=' + $contractRunRoot)
