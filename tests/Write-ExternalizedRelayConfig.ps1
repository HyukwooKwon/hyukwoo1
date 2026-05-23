[CmdletBinding()]
param(
    [string]$BaseConfigPath,
    [Parameter(Mandatory)][string]$WorkRepoRoot,
    [string]$OutputConfigPath,
    [string]$ReviewInputPath,
    [string]$ExternalWorkRepoContractRelativeRoot,
    [bool]$DefaultSeedReviewInputRequireSingleCandidate,
    [string]$PairId,
    [string]$BookkeepingRoot,
    [string]$PairRunRootBase,
    [switch]$BootstrapBindingProfile,
    [switch]$BootstrapRuntimeMap,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-FullPath {
    param(
        [Parameter(Mandatory)][string]$PathValue,
        [Parameter(Mandatory)][string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Get-DeterministicShortHash {
    param([Parameter(Mandatory)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha.ComputeHash($bytes)
        $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
        return $hex.Substring(0, 12)
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertTo-SafePathSegment {
    param(
        [Parameter(Mandatory)][string]$Value,
        [string]$Fallback = 'default'
    )

    $normalized = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $Fallback
    }

    $safe = [regex]::Replace($normalized, '[^A-Za-z0-9._-]+', '-')
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return $Fallback
    }

    return $safe
}

function Get-ExternalizedRouterMutexName {
    param(
        [Parameter(Mandatory)][string]$BaseMutexName,
        [Parameter(Mandatory)][string]$WorkRepoRoot,
        [string]$ScopeKey = ''
    )

    $normalizedBase = if ([string]::IsNullOrWhiteSpace($BaseMutexName)) {
        'Global\RelayRouter_externalized'
    }
    else {
        $BaseMutexName.Trim()
    }

    $hashInput = [System.IO.Path]::GetFullPath($WorkRepoRoot).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($ScopeKey)) {
        $hashInput = ($hashInput + '|' + $ScopeKey.Trim().ToLowerInvariant())
    }
    $suffix = Get-DeterministicShortHash -Text $hashInput
    return ($normalizedBase + '_ext_' + $suffix)
}

function Replace-QuotedAssignment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $escapedValue = $Value.Replace("'", "''")
    $pattern = ("(?m)(\b{0}\s*=\s*)'.*?'" -f [regex]::Escape($Name))
    $evaluator = {
        param($match)
        return ($match.Groups[1].Value + "'" + $escapedValue + "'")
    }
    return [regex]::Replace($Text, $pattern, $evaluator)
}

function Replace-QuotedAssignmentAfterAnchor {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$AnchorPattern,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $escapedValue = $Value.Replace("'", "''")
    $pattern = ("(?s)({0}.*?\b{1}\s*=\s*)'.*?'" -f $AnchorPattern, [regex]::Escape($Name))
    $evaluator = {
        param($match)
        return ($match.Groups[1].Value + "'" + $escapedValue + "'")
    }
    return [regex]::Replace($Text, $pattern, $evaluator, 1)
}

function Replace-QuotedAssignmentAfterAnchorIfPresent {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$AnchorPattern,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $escapedValue = $Value.Replace("'", "''")
    $pattern = ("(?s)({0}.*?\b{1}\s*=\s*)'.*?'" -f $AnchorPattern, [regex]::Escape($Name))
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        return $Text
    }

    $evaluator = {
        param($capture)
        return ($capture.Groups[1].Value + "'" + $escapedValue + "'")
    }
    return [regex]::Replace($Text, $pattern, $evaluator, 1)
}

function Replace-BooleanAssignmentAfterAnchor {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$AnchorPattern,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Value
    )

    $boolLiteral = if ($Value) { '$true' } else { '$false' }
    $pattern = ('(?s)({0}.*?\b{1}\s*=\s*)\$(?:true|false)' -f $AnchorPattern, [regex]::Escape($Name))
    $evaluator = {
        param($match)
        return ($match.Groups[1].Value + $boolLiteral)
    }
    return [regex]::Replace($Text, $pattern, $evaluator, 1)
}

function Replace-BooleanAssignmentAfterAnchorIfPresent {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$AnchorPattern,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Value
    )

    $boolLiteral = if ($Value) { '$true' } else { '$false' }
    $pattern = ('(?s)({0}.*?\b{1}\s*=\s*)\$(?:true|false)' -f $AnchorPattern, [regex]::Escape($Name))
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        return $Text
    }

    $evaluator = {
        param($capture)
        return ($capture.Groups[1].Value + $boolLiteral)
    }
    return [regex]::Replace($Text, $pattern, $evaluator, 1)
}

$root = Split-Path -Parent $PSScriptRoot
if (-not $PSBoundParameters.ContainsKey('BaseConfigPath') -or [string]::IsNullOrWhiteSpace($BaseConfigPath)) {
    $BaseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedBaseConfigPath = (Resolve-Path -LiteralPath $BaseConfigPath).Path
$resolvedWorkRepoRoot = [System.IO.Path]::GetFullPath($WorkRepoRoot)
if (-not (Test-Path -LiteralPath $resolvedWorkRepoRoot -PathType Container)) {
    throw "WorkRepoRoot not found: $resolvedWorkRepoRoot"
}
$pairScopeSegment = if ([string]::IsNullOrWhiteSpace($PairId)) { '' } else { ConvertTo-SafePathSegment -Value $PairId -Fallback 'pair' }
$pairTestAnchorPattern = 'PairTest\s*=\s*@\{'
$pairPolicyAnchorPattern = if ([string]::IsNullOrWhiteSpace($PairId)) {
    ''
}
else {
    ('\b{0}\s*=\s*@\{{' -f [regex]::Escape([string]$PairId))
}

$config = Import-PowerShellDataFile -Path $resolvedBaseConfigPath
$externalizedRouterMutexName = Get-ExternalizedRouterMutexName -BaseMutexName ([string]$config.RouterMutexName) -WorkRepoRoot $resolvedWorkRepoRoot -ScopeKey $pairScopeSegment
$pairTestConfig = Get-ConfigValue -Object $config -Name 'PairTest' -DefaultValue @{}
$reviewInputPathSpecified = $PSBoundParameters.ContainsKey('ReviewInputPath')
$externalContractRelativeRootSpecified = $PSBoundParameters.ContainsKey('ExternalWorkRepoContractRelativeRoot')
$requireSingleReviewCandidateSpecified = $PSBoundParameters.ContainsKey('DefaultSeedReviewInputRequireSingleCandidate')
$defaultReviewInputPath = if ($reviewInputPathSpecified) {
    [string]$ReviewInputPath
}
elseif ([string]::IsNullOrWhiteSpace($ReviewInputPath)) {
    [string](Get-ConfigValue -Object $pairTestConfig -Name 'DefaultSeedReviewInputPath' -DefaultValue '')
}
else {
    $ReviewInputPath
}
$resolvedReviewInputPath = if ([string]::IsNullOrWhiteSpace($defaultReviewInputPath)) {
    ''
}
else {
    Resolve-FullPath -PathValue $defaultReviewInputPath -BasePath $root
}

if (-not $PSBoundParameters.ContainsKey('OutputConfigPath') -or [string]::IsNullOrWhiteSpace($OutputConfigPath)) {
    if ([string]::IsNullOrWhiteSpace($pairScopeSegment)) {
        $OutputConfigPath = Join-Path $resolvedWorkRepoRoot '.relay-config\bottest-live-visible\settings.externalized.psd1'
    }
    else {
        $OutputConfigPath = Join-Path $resolvedWorkRepoRoot ('.relay-config\bottest-live-visible\pairs\{0}\settings.externalized.psd1' -f $pairScopeSegment)
    }
}
$resolvedOutputConfigPath = [System.IO.Path]::GetFullPath($OutputConfigPath)
Ensure-Directory -Path (Split-Path -Parent $resolvedOutputConfigPath)

if (-not [string]::IsNullOrWhiteSpace($BookkeepingRoot)) {
    $bookkeepingRoot = [System.IO.Path]::GetFullPath($BookkeepingRoot)
}
elseif ([string]::IsNullOrWhiteSpace($pairScopeSegment)) {
    $bookkeepingRoot = Join-Path $resolvedWorkRepoRoot '.relay-bookkeeping\bottest-live-visible'
}
else {
    $bookkeepingRoot = Join-Path $resolvedWorkRepoRoot ('.relay-bookkeeping\bottest-live-visible\pairs\{0}' -f $pairScopeSegment)
}
$inboxRoot = Join-Path $bookkeepingRoot 'inbox'
$processedRoot = Join-Path $bookkeepingRoot 'processed'
$failedRoot = Join-Path $bookkeepingRoot 'failed'
$ignoredRoot = Join-Path $bookkeepingRoot 'ignored'
$retryPendingRoot = Join-Path $bookkeepingRoot 'retry-pending'
$runtimeRoot = Join-Path $bookkeepingRoot 'runtime'
$logsRoot = Join-Path $bookkeepingRoot 'logs'
$pairActivationStatePath = Join-Path $bookkeepingRoot 'pair-activation\bottest-live-visible.json'
$bindingProfilePath = Join-Path $runtimeRoot 'window-bindings\bottest-live-visible.json'
$runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
$routerStatePath = Join-Path $runtimeRoot 'router-state.json'
$routerLogPath = Join-Path $logsRoot 'router.log'
$visibleWorkerQueueRoot = Join-Path $runtimeRoot 'visible-worker\queue'
$visibleWorkerStatusRoot = Join-Path $runtimeRoot 'visible-worker\status'
$visibleWorkerLogRoot = Join-Path $runtimeRoot 'visible-worker\logs'
$targetAutoloopBookkeepingRoot = if ([string]::IsNullOrWhiteSpace($pairScopeSegment)) {
    Join-Path $bookkeepingRoot 'target-autoloop'
}
else {
    Join-Path $bookkeepingRoot 'target-autoloop'
}
$targetAutoloopStatusRoot = Join-Path $targetAutoloopBookkeepingRoot 'status'
$targetAutoloopQueueRoot = Join-Path $targetAutoloopBookkeepingRoot 'queue'
if (-not [string]::IsNullOrWhiteSpace($PairRunRootBase)) {
    $pairRunRootBase = [System.IO.Path]::GetFullPath($PairRunRootBase)
}
elseif ([string]::IsNullOrWhiteSpace($pairScopeSegment)) {
    $pairRunRootBase = Join-Path $resolvedWorkRepoRoot '.relay-runs\bottest-live-visible'
}
else {
    $pairRunRootBase = Join-Path $resolvedWorkRepoRoot ('.relay-runs\bottest-live-visible\pairs\{0}' -f $pairScopeSegment)
}
$targetAutoloopRunRootBase = if ([string]::IsNullOrWhiteSpace($pairScopeSegment)) {
    Join-Path $resolvedWorkRepoRoot '.relay-runs\bottest-live-visible\target-autoloop'
}
else {
    Join-Path $resolvedWorkRepoRoot ('.relay-runs\bottest-live-visible\pairs\{0}\target-autoloop' -f $pairScopeSegment)
}

foreach ($path in @(
    $inboxRoot,
    $processedRoot,
    $failedRoot,
    $ignoredRoot,
    $retryPendingRoot,
    $runtimeRoot,
    $logsRoot,
    (Split-Path -Parent $pairActivationStatePath),
    (Split-Path -Parent $bindingProfilePath),
    $visibleWorkerQueueRoot,
    $visibleWorkerStatusRoot,
    $visibleWorkerLogRoot,
    $pairRunRootBase,
    $targetAutoloopStatusRoot,
    $targetAutoloopQueueRoot,
    $targetAutoloopRunRootBase
)) {
    Ensure-Directory -Path $path
}

$configText = Get-Content -LiteralPath $resolvedBaseConfigPath -Raw -Encoding UTF8
$configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern $pairTestAnchorPattern -Name 'DefaultSeedWorkRepoRoot' -Value $resolvedWorkRepoRoot
if (-not [string]::IsNullOrWhiteSpace($pairPolicyAnchorPattern)) {
    $configText = Replace-QuotedAssignmentAfterAnchorIfPresent -Text $configText -AnchorPattern $pairPolicyAnchorPattern -Name 'DefaultSeedWorkRepoRoot' -Value $resolvedWorkRepoRoot
}
if ($reviewInputPathSpecified) {
    $configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern $pairTestAnchorPattern -Name 'DefaultSeedReviewInputPath' -Value $resolvedReviewInputPath
    if (-not [string]::IsNullOrWhiteSpace($pairPolicyAnchorPattern)) {
        $configText = Replace-QuotedAssignmentAfterAnchorIfPresent -Text $configText -AnchorPattern $pairPolicyAnchorPattern -Name 'DefaultSeedReviewInputPath' -Value $resolvedReviewInputPath
    }
}
if ($externalContractRelativeRootSpecified) {
    $configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern $pairTestAnchorPattern -Name 'ExternalWorkRepoContractRelativeRoot' -Value ([string]$ExternalWorkRepoContractRelativeRoot)
    if (-not [string]::IsNullOrWhiteSpace($pairPolicyAnchorPattern)) {
        $configText = Replace-QuotedAssignmentAfterAnchorIfPresent -Text $configText -AnchorPattern $pairPolicyAnchorPattern -Name 'ExternalWorkRepoContractRelativeRoot' -Value ([string]$ExternalWorkRepoContractRelativeRoot)
    }
}
if ($requireSingleReviewCandidateSpecified) {
    $configText = Replace-BooleanAssignmentAfterAnchor -Text $configText -AnchorPattern $pairTestAnchorPattern -Name 'DefaultSeedReviewInputRequireSingleCandidate' -Value ([bool]$DefaultSeedReviewInputRequireSingleCandidate)
    if (-not [string]::IsNullOrWhiteSpace($pairPolicyAnchorPattern)) {
        $configText = Replace-BooleanAssignmentAfterAnchorIfPresent -Text $configText -AnchorPattern $pairPolicyAnchorPattern -Name 'DefaultSeedReviewInputRequireSingleCandidate' -Value ([bool]$DefaultSeedReviewInputRequireSingleCandidate)
    }
}
$pairScopedExternalRunRootRelativeRoot = if ([string]::IsNullOrWhiteSpace($pairScopeSegment)) {
    ''
}
else {
    ('.relay-runs\bottest-live-visible\pairs\{0}' -f $pairScopeSegment)
}
if (-not [string]::IsNullOrWhiteSpace($pairScopedExternalRunRootRelativeRoot)) {
    $configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern $pairTestAnchorPattern -Name 'ExternalWorkRepoRunRootRelativeRoot' -Value $pairScopedExternalRunRootRelativeRoot
}
$configText = Replace-QuotedAssignment -Text $configText -Name 'RuntimeRoot' -Value $runtimeRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'RuntimeMapPath' -Value $runtimeMapPath
$configText = Replace-QuotedAssignment -Text $configText -Name 'LogsRoot' -Value $logsRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'InboxRoot' -Value $inboxRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'ProcessedRoot' -Value $processedRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'FailedRoot' -Value $failedRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'IgnoredRoot' -Value $ignoredRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'RetryPendingRoot' -Value $retryPendingRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'BindingProfilePath' -Value $bindingProfilePath
$configText = Replace-QuotedAssignment -Text $configText -Name 'RouterStatePath' -Value $routerStatePath
$configText = Replace-QuotedAssignment -Text $configText -Name 'RouterLogPath' -Value $routerLogPath
$configText = Replace-QuotedAssignment -Text $configText -Name 'RouterMutexName' -Value $externalizedRouterMutexName
$configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern 'PairActivation\s*=\s*@\{' -Name 'StatePath' -Value $pairActivationStatePath
$configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern 'VisibleWorker\s*=\s*@\{' -Name 'QueueRoot' -Value $visibleWorkerQueueRoot
$configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern 'VisibleWorker\s*=\s*@\{' -Name 'StatusRoot' -Value $visibleWorkerStatusRoot
$configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern 'VisibleWorker\s*=\s*@\{' -Name 'LogRoot' -Value $visibleWorkerLogRoot
$configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern 'PairTest\s*=\s*@\{' -Name 'RunRootBase' -Value $pairRunRootBase
$configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern 'TargetAutoloop\s*=\s*@\{' -Name 'RunRootBase' -Value $targetAutoloopRunRootBase
$configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern 'TargetAutoloop\s*=\s*@\{' -Name 'StatusRoot' -Value $targetAutoloopStatusRoot
$configText = Replace-QuotedAssignmentAfterAnchor -Text $configText -AnchorPattern 'TargetAutoloop\s*=\s*@\{' -Name 'QueueRoot' -Value $targetAutoloopQueueRoot

foreach ($targetId in @('target01','target02','target03','target04','target05','target06','target07','target08')) {
    $targetFolder = Join-Path $inboxRoot $targetId
    Ensure-Directory -Path $targetFolder
    $escapedTargetFolder = $targetFolder.Replace("'", "''")
    $pattern = ("(?m)(Folder\s*=\s*)'.*?\\{0}'" -f [regex]::Escape($targetId))
    $configText = [regex]::Replace($configText, $pattern, {
            param($match)
            return ($match.Groups[1].Value + "'" + $escapedTargetFolder + "'")
        })
}

Set-Content -LiteralPath $resolvedOutputConfigPath -Value $configText -Encoding UTF8

$sourceBindingProfilePath = [string](Get-ConfigValue -Object $config -Name 'BindingProfilePath' -DefaultValue '')
$sourceRuntimeMapPath = [string](Get-ConfigValue -Object $config -Name 'RuntimeMapPath' -DefaultValue '')
if ($BootstrapBindingProfile -and (Test-Path -LiteralPath $sourceBindingProfilePath -PathType Leaf)) {
    Ensure-Directory -Path (Split-Path -Parent $bindingProfilePath)
    Copy-Item -LiteralPath $sourceBindingProfilePath -Destination $bindingProfilePath -Force
}
if ($BootstrapRuntimeMap -and (Test-Path -LiteralPath $sourceRuntimeMapPath -PathType Leaf)) {
    Ensure-Directory -Path (Split-Path -Parent $runtimeMapPath)
    Copy-Item -LiteralPath $sourceRuntimeMapPath -Destination $runtimeMapPath -Force
}

$result = [pscustomobject]@{
    BaseConfigPath = $resolvedBaseConfigPath
    WorkRepoRoot = $resolvedWorkRepoRoot
    PairId = [string]$PairId
    PairScopeSegment = $pairScopeSegment
    OutputConfigPath = $resolvedOutputConfigPath
    ReviewInputPath = $resolvedReviewInputPath
    ReviewInputPathSpecified = [bool]$reviewInputPathSpecified
    ExternalWorkRepoContractRelativeRoot = if ($externalContractRelativeRootSpecified) { [string]$ExternalWorkRepoContractRelativeRoot } else { [string](Get-ConfigValue -Object $pairTestConfig -Name 'ExternalWorkRepoContractRelativeRoot' -DefaultValue '') }
    DefaultSeedReviewInputRequireSingleCandidate = if ($requireSingleReviewCandidateSpecified) { [bool]$DefaultSeedReviewInputRequireSingleCandidate } else { [bool](Get-ConfigValue -Object $pairTestConfig -Name 'DefaultSeedReviewInputRequireSingleCandidate' -DefaultValue $false) }
    BookkeepingRoot = $bookkeepingRoot
    InboxRoot = $inboxRoot
    ProcessedRoot = $processedRoot
    FailedRoot = $failedRoot
    IgnoredRoot = $ignoredRoot
    RetryPendingRoot = $retryPendingRoot
    RuntimeRoot = $runtimeRoot
    RuntimeMapPath = $runtimeMapPath
    LogsRoot = $logsRoot
    RouterMutexName = $externalizedRouterMutexName
    RouterStatePath = $routerStatePath
    RouterLogPath = $routerLogPath
    BindingProfilePath = $bindingProfilePath
    PairActivationStatePath = $pairActivationStatePath
    VisibleWorkerQueueRoot = $visibleWorkerQueueRoot
    VisibleWorkerStatusRoot = $visibleWorkerStatusRoot
    VisibleWorkerLogRoot = $visibleWorkerLogRoot
    PairRunRootBase = $pairRunRootBase
    TargetAutoloopRunRootBase = $targetAutoloopRunRootBase
    TargetAutoloopStatusRoot = $targetAutoloopStatusRoot
    TargetAutoloopQueueRoot = $targetAutoloopQueueRoot
    BootstrapBindingProfile = [bool]$BootstrapBindingProfile
    BootstrapRuntimeMap = [bool]$BootstrapRuntimeMap
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
    return
}

$result
