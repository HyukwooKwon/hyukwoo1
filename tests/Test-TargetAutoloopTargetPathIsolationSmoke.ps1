[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} expected={1} actual={2}" -f $Message, $Expected, $Actual)
    }
}

function Assert-UnderRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Message
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not ($resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $resolvedPath.StartsWith($resolvedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
        throw ("{0} path={1} root={2}" -f $Message, $resolvedPath, $resolvedRoot)
    }
}

function New-SmokeConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunRootBase,
        [Parameter(Mandatory)][string]$RouterInbox04,
        [Parameter(Mandatory)][string]$RouterInbox08,
        [Parameter(Mandatory)][string]$WorkRepo04,
        [Parameter(Mandatory)][string]$WorkRepo08
    )

    $runtimeRoot = Join-Path (Split-Path -Parent $Path) (([System.IO.Path]::GetFileNameWithoutExtension($Path)) + '.runtime')
    $runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
    $routerStatePath = Join-Path $runtimeRoot 'router-state.json'
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    @(
        [ordered]@{ TargetId = 'target04'; LauncherSessionId = 'test-session-path-isolation' }
        [ordered]@{ TargetId = 'target08'; LauncherSessionId = 'test-session-path-isolation' }
    ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runtimeMapPath -Encoding UTF8
    [ordered]@{
        UpdatedAt = (Get-Date).ToString('o')
        Status = 'running'
        LauncherSessionId = 'test-session-path-isolation'
        RouterPid = $PID
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $routerStatePath -Encoding UTF8

    [System.IO.File]::WriteAllText($Path, @"
@{
    LaneName = 'bottest-live-visible'
    RuntimeMapPath = '$($runtimeMapPath.Replace("'", "''"))'
    RouterStatePath = '$($routerStatePath.Replace("'", "''"))'
    Targets = @(
        @{ Id = 'target04'; Folder = '$($RouterInbox04.Replace("'", "''"))'; WindowTitle = 'Target04'; FixedSuffix = 'suffix-04' }
        @{ Id = 'target08'; Folder = '$($RouterInbox08.Replace("'", "''"))'; WindowTitle = 'Target08'; FixedSuffix = 'suffix-08' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        MaxConcurrentTargets = 8
        MaxConcurrentSubmits = 1
        PollIntervalMs = 100
        RunRootBase = '$($RunRootBase.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target04'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); MaxCycleCount = 2; WorkRepoRoot = '$($WorkRepo04.Replace("'", "''"))' }
            @{ TargetId = 'target08'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); MaxCycleCount = 2; WorkRepoRoot = '$($WorkRepo08.Replace("'", "''"))' }
        )
    }
}
"@, (New-Utf8NoBomEncoding))
}

function Publish-TargetOutput {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$ManifestTarget,
        [Parameter(Mandatory)][int]$CycleId
    )

    Set-Content -LiteralPath ([string]$ManifestTarget.SourceSummaryPath) -Encoding UTF8 -Value ("summary for {0} cycle {1}" -f [string]$ManifestTarget.TargetId, $CycleId)
    $zipNotePath = Join-Path ([string]$ManifestTarget.SourceOutboxPath) ('note-{0}.txt' -f $CycleId)
    Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value ("zip payload for {0} cycle {1}" -f [string]$ManifestTarget.TargetId, $CycleId)
    if (Test-Path -LiteralPath ([string]$ManifestTarget.SourceReviewZipPath)) {
        Remove-Item -LiteralPath ([string]$ManifestTarget.SourceReviewZipPath) -Force
    }
    Compress-Archive -LiteralPath $zipNotePath -DestinationPath ([string]$ManifestTarget.SourceReviewZipPath) -Force
    $fingerprint = 'output-{0}-{1}' -f [string]$ManifestTarget.TargetId, $CycleId
    $publishJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\Publish-TargetAutoloopArtifact.ps1') `
        -ConfigPath $ConfigPath `
        -RunRoot $RunRoot `
        -TargetId ([string]$ManifestTarget.TargetId) `
        -CycleId $CycleId `
        -ParentCycleId ([math]::Max(0, $CycleId - 1)) `
        -OutputFingerprint $fingerprint `
        -AsJson
    $publish = $publishJson | ConvertFrom-Json
    Assert-True ([bool]$publish.Marker.ValidationPassed) ('publish helper should validate {0}.' -f [string]$ManifestTarget.TargetId)
}

function Invoke-SmokeRun {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ScenarioName,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$ExpectedWorkRepo04,
        [Parameter(Mandatory)][string]$ExpectedWorkRepo08,
        [Parameter(Mandatory)][bool]$SameWorkRepo
    )

    $startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\Start-TargetAutoloopRun.ps1') `
        -ConfigPath $ConfigPath `
        -RunRoot $RunRoot `
        -RunMode target-autoloop `
        -AsJson
    $start = $startJson | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath ([string]$start.ManifestPath) -Raw -Encoding UTF8 | ConvertFrom-Json
    $target04 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target04' } | Select-Object -First 1)[0]
    $target08 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target08' } | Select-Object -First 1)[0]

    Assert-Equal $ExpectedWorkRepo04 ([string]$target04.WorkRepoRoot) "$ScenarioName target04 work repo"
    Assert-Equal $ExpectedWorkRepo08 ([string]$target08.WorkRepoRoot) "$ScenarioName target08 work repo"
    if ($SameWorkRepo) {
        Assert-Equal ([string]$target04.WorkRepoRoot) ([string]$target08.WorkRepoRoot) "$ScenarioName same WorkRepoRoot should be preserved"
    }
    else {
        Assert-True ([string]$target04.WorkRepoRoot -ne [string]$target08.WorkRepoRoot) "$ScenarioName different WorkRepoRoot should be preserved."
    }

    Assert-True ([string]$target04.SourceOutboxPath -ne [string]$target08.SourceOutboxPath) "$ScenarioName source outbox paths should be distinct."
    Assert-True ([string]$target04.PublishReadyPath -ne [string]$target08.PublishReadyPath) "$ScenarioName publish ready paths should be distinct."
    Assert-True ([string]$target04.QueueRoot -ne [string]$target08.QueueRoot) "$ScenarioName queue roots should be distinct."
    Assert-UnderRoot -Path ([string]$target04.SourceOutboxPath) -Root ([string]$target04.WorkRepoRoot) -Message "$ScenarioName target04 source outbox should stay under WorkRepoRoot"
    Assert-UnderRoot -Path ([string]$target08.SourceOutboxPath) -Root ([string]$target08.WorkRepoRoot) -Message "$ScenarioName target08 source outbox should stay under WorkRepoRoot"

    Publish-TargetOutput -Root $Root -ConfigPath $ConfigPath -RunRoot $RunRoot -ManifestTarget $target04 -CycleId 1
    $watch04Json = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\Watch-TargetAutoloop.ps1') `
        -ConfigPath $ConfigPath `
        -RunRoot $RunRoot `
        -DispatchQueuedCommandsInline `
        -ProcessOnce `
        -AsJson
    $watch04 = $watch04Json | ConvertFrom-Json
    Assert-Equal 1 ([int]$watch04.QueuedCount) "$ScenarioName target04 publish-ready should queue"
    Assert-Equal 1 ([int]$watch04.DispatchedCount) "$ScenarioName target04 publish-ready should dispatch"

    Publish-TargetOutput -Root $Root -ConfigPath $ConfigPath -RunRoot $RunRoot -ManifestTarget $target08 -CycleId 1
    $watch08Json = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\Watch-TargetAutoloop.ps1') `
        -ConfigPath $ConfigPath `
        -RunRoot $RunRoot `
        -DispatchQueuedCommandsInline `
        -ProcessOnce `
        -AsJson
    $watch08 = $watch08Json | ConvertFrom-Json
    Assert-Equal 1 ([int]$watch08.QueuedCount) "$ScenarioName target08 publish-ready should queue"
    Assert-Equal 1 ([int]$watch08.DispatchedCount) "$ScenarioName target08 publish-ready should dispatch"

    $state = Get-Content -LiteralPath ([string]$start.StatePath) -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'router-ready-file-created' ([string]$state.Targets.target04.LastDispatchState) "$ScenarioName target04 should create router ready"
    Assert-Equal 'router-ready-file-created' ([string]$state.Targets.target08.LastDispatchState) "$ScenarioName target08 should create router ready"
    Assert-True ((Test-Path -LiteralPath ([string]$state.Targets.target04.LastRouterReadyPath) -PathType Leaf)) "$ScenarioName target04 ready file should exist."
    Assert-True ((Test-Path -LiteralPath ([string]$state.Targets.target08.LastRouterReadyPath) -PathType Leaf)) "$ScenarioName target08 ready file should exist."

    $queued04 = @(Get-ChildItem -LiteralPath ([string]$target04.QueueQueuedRoot) -File -Filter '*.json' -ErrorAction SilentlyContinue)
    $queued08 = @(Get-ChildItem -LiteralPath ([string]$target08.QueueQueuedRoot) -File -Filter '*.json' -ErrorAction SilentlyContinue)
    $completed04 = @(Get-ChildItem -LiteralPath ([string]$target04.QueueCompletedRoot) -File -Filter '*.json' -ErrorAction SilentlyContinue)
    $completed08 = @(Get-ChildItem -LiteralPath ([string]$target08.QueueCompletedRoot) -File -Filter '*.json' -ErrorAction SilentlyContinue)
    Assert-Equal 0 (@($queued04).Count) "$ScenarioName target04 queue should be drained"
    Assert-Equal 0 (@($queued08).Count) "$ScenarioName target08 queue should be drained"
    Assert-Equal 1 (@($completed04).Count) "$ScenarioName target04 completed queue archive"
    Assert-Equal 1 (@($completed08).Count) "$ScenarioName target08 completed queue archive"

    return [pscustomobject]@{
        Scenario = $ScenarioName
        RunRoot = [string]$start.RunRoot
        Target04WorkRepoRoot = [string]$target04.WorkRepoRoot
        Target08WorkRepoRoot = [string]$target08.WorkRepoRoot
        Target04SourceOutboxPath = [string]$target04.SourceOutboxPath
        Target08SourceOutboxPath = [string]$target08.SourceOutboxPath
        Target04QueueRoot = [string]$target04.QueueRoot
        Target08QueueRoot = [string]$target08.QueueRoot
        Target04ReadyPath = [string]$state.Targets.target04.LastRouterReadyPath
        Target08ReadyPath = [string]$state.Targets.target08.LastRouterReadyPath
    }
}

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopTargetPathIsolationSmoke'
$externalRoot = 'C:\dev\python\relay-autoloop-path-isolation-smoke'
$resolvedExternalRoot = [System.IO.Path]::GetFullPath($externalRoot).TrimEnd('\')
Assert-True ($resolvedExternalRoot -eq 'C:\dev\python\relay-autoloop-path-isolation-smoke') 'external smoke root guard should match the expected path.'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
if (Test-Path -LiteralPath $resolvedExternalRoot) {
    Remove-Item -LiteralPath $resolvedExternalRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
New-Item -ItemType Directory -Path $resolvedExternalRoot -Force | Out-Null

$differentRoot = Join-Path $resolvedExternalRoot 'different-workrepos'
$differentRunBase = Join-Path $differentRoot 'coordinator\.relay-runs\bottest-live-visible\target-autoloop'
$differentConfigPath = Join-Path $tmpRoot 'settings.different-workrepos.psd1'
$differentRunRoot = Join-Path $differentRunBase 'run_target04_target08_different'
$differentRepo04 = Join-Path $differentRoot 'repo-target04'
$differentRepo08 = Join-Path $differentRoot 'repo-target08'
$differentRouterInbox04 = Join-Path $differentRoot 'router-inbox\target04'
$differentRouterInbox08 = Join-Path $differentRoot 'router-inbox\target08'
New-Item -ItemType Directory -Path $differentRouterInbox04 -Force | Out-Null
New-Item -ItemType Directory -Path $differentRouterInbox08 -Force | Out-Null
New-Item -ItemType Directory -Path $differentRepo04 -Force | Out-Null
New-Item -ItemType Directory -Path $differentRepo08 -Force | Out-Null
New-Item -ItemType Directory -Path $differentRunBase -Force | Out-Null
New-SmokeConfig -Path $differentConfigPath -RunRootBase $differentRunBase -RouterInbox04 $differentRouterInbox04 -RouterInbox08 $differentRouterInbox08 -WorkRepo04 $differentRepo04 -WorkRepo08 $differentRepo08

$sharedRoot = Join-Path $resolvedExternalRoot 'same-workrepo'
$sharedRunBase = Join-Path $sharedRoot 'coordinator\.relay-runs\bottest-live-visible\target-autoloop'
$sharedConfigPath = Join-Path $tmpRoot 'settings.same-workrepo.psd1'
$sharedRunRoot = Join-Path $sharedRunBase 'run_target04_target08_same'
$sharedRepo = Join-Path $sharedRoot 'repo-shared'
$sharedRouterInbox04 = Join-Path $sharedRoot 'router-inbox\target04'
$sharedRouterInbox08 = Join-Path $sharedRoot 'router-inbox\target08'
New-Item -ItemType Directory -Path $sharedRouterInbox04 -Force | Out-Null
New-Item -ItemType Directory -Path $sharedRouterInbox08 -Force | Out-Null
New-Item -ItemType Directory -Path $sharedRepo -Force | Out-Null
New-Item -ItemType Directory -Path $sharedRunBase -Force | Out-Null
New-SmokeConfig -Path $sharedConfigPath -RunRootBase $sharedRunBase -RouterInbox04 $sharedRouterInbox04 -RouterInbox08 $sharedRouterInbox08 -WorkRepo04 $sharedRepo -WorkRepo08 $sharedRepo

$results = @(
    Invoke-SmokeRun -Root $root -ScenarioName 'different-workrepos' -ConfigPath $differentConfigPath -RunRoot $differentRunRoot -ExpectedWorkRepo04 $differentRepo04 -ExpectedWorkRepo08 $differentRepo08 -SameWorkRepo:$false
    Invoke-SmokeRun -Root $root -ScenarioName 'same-workrepo' -ConfigPath $sharedConfigPath -RunRoot $sharedRunRoot -ExpectedWorkRepo04 $sharedRepo -ExpectedWorkRepo08 $sharedRepo -SameWorkRepo:$true
)

$results | ConvertTo-Json -Depth 8
Write-Host 'target autoloop target path isolation smoke ok'
