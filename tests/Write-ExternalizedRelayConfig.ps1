[CmdletBinding()]
param(
    [string]$BaseConfigPath,
    [Parameter(Mandatory)][string]$WorkRepoRoot,
    [string]$OutputConfigPath,
    [string]$ReviewInputPath,
    [switch]$BootstrapBindingProfile,
    [switch]$BootstrapRuntimeMap,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-ExternalizedRouterMutexName {
    param(
        [Parameter(Mandatory)][string]$BaseMutexName,
        [Parameter(Mandatory)][string]$WorkRepoRoot
    )

    $normalizedBase = if ([string]::IsNullOrWhiteSpace($BaseMutexName)) {
        'Global\RelayRouter_externalized'
    }
    else {
        $BaseMutexName.Trim()
    }

    $suffix = Get-DeterministicShortHash -Text ([System.IO.Path]::GetFullPath($WorkRepoRoot).ToLowerInvariant())
    return ($normalizedBase + '_ext_' + $suffix)
}

function Replace-QuotedAssignment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $escapedValue = $Value.Replace("'", "''")
    $pattern = ("(?m)(\b{0}\s*=\s*)'.*?'" -f [regex]::Escape($Name))
    $evaluator = {
        param($match)
        return ($match.Groups[1].Value + "'" + $escapedValue + "'")
    }
    return [regex]::Replace($Text, $pattern, $evaluator)
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

$config = Import-PowerShellDataFile -Path $resolvedBaseConfigPath
$externalizedRouterMutexName = Get-ExternalizedRouterMutexName -BaseMutexName ([string]$config.RouterMutexName) -WorkRepoRoot $resolvedWorkRepoRoot
$defaultReviewInputPath = if ([string]::IsNullOrWhiteSpace($ReviewInputPath)) {
    [string]$config.PairTest.DefaultSeedReviewInputPath
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
    $OutputConfigPath = Join-Path $resolvedWorkRepoRoot '.relay-config\bottest-live-visible\settings.externalized.psd1'
}
$resolvedOutputConfigPath = [System.IO.Path]::GetFullPath($OutputConfigPath)
Ensure-Directory -Path (Split-Path -Parent $resolvedOutputConfigPath)

$bookkeepingRoot = Join-Path $resolvedWorkRepoRoot '.relay-bookkeeping\bottest-live-visible'
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
$pairRunRootBase = Join-Path $resolvedWorkRepoRoot '.relay-runs\bottest-live-visible'

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
    $visibleWorkerLogRoot
)) {
    Ensure-Directory -Path $path
}

$configText = Get-Content -LiteralPath $resolvedBaseConfigPath -Raw -Encoding UTF8
$configText = Replace-QuotedAssignment -Text $configText -Name 'DefaultSeedWorkRepoRoot' -Value $resolvedWorkRepoRoot
if (-not [string]::IsNullOrWhiteSpace($resolvedReviewInputPath)) {
    $configText = Replace-QuotedAssignment -Text $configText -Name 'DefaultSeedReviewInputPath' -Value $resolvedReviewInputPath
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
$configText = Replace-QuotedAssignment -Text $configText -Name 'StatePath' -Value $pairActivationStatePath
$configText = Replace-QuotedAssignment -Text $configText -Name 'QueueRoot' -Value $visibleWorkerQueueRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'StatusRoot' -Value $visibleWorkerStatusRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'LogRoot' -Value $visibleWorkerLogRoot
$configText = Replace-QuotedAssignment -Text $configText -Name 'RunRootBase' -Value $pairRunRootBase

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

$sourceBindingProfilePath = [string]$config.BindingProfilePath
$sourceRuntimeMapPath = [string]$config.RuntimeMapPath
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
    OutputConfigPath = $resolvedOutputConfigPath
    ReviewInputPath = $resolvedReviewInputPath
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
    BootstrapBindingProfile = [bool]$BootstrapBindingProfile
    BootstrapRuntimeMap = [bool]$BootstrapRuntimeMap
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
    return
}

$result
