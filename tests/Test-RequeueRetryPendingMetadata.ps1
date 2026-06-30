[CmdletBinding()]
param()

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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-requeue-retry-pending-metadata'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$retryPendingRoot = Join-Path $testRoot 'retry-pending'
$targetInbox = Join-Path $testRoot 'inbox\target01'
New-Item -ItemType Directory -Path $retryPendingRoot -Force | Out-Null
New-Item -ItemType Directory -Path $targetInbox -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    RetryPendingRoot = '$($retryPendingRoot.Replace("'", "''"))'
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($targetInbox.Replace("'", "''"))'
        }
    )
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$retryFile = Join-Path $retryPendingRoot 'target01__20260414_000000_000__message_sample.ready.txt'
$retryMeta = ($retryFile + '.meta.json')
$retryDeliveryMeta = ($retryFile + '.delivery.json')
[System.IO.File]::WriteAllText($retryFile, 'sample', (New-Utf8NoBomEncoding))
([ordered]@{
    SchemaVersion = '1.0.0'
    FailureCategory = 'user_active_hold'
    FailureMessage = 'AHK exit code: 43'
} | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $retryMeta -Encoding UTF8
([ordered]@{
    SchemaVersion = '1.0.0'
    Kind = 'relay-ready'
    TargetId = 'target01'
    LauncherSessionId = 'test-session'
} | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $retryDeliveryMeta -Encoding UTF8

$output = & (Join-Path $root 'router\Requeue-RetryPending.ps1') -ConfigPath $configPath -TargetId target01 2>&1

$requeuedFiles = @(Get-ChildItem -LiteralPath $targetInbox -Filter 'requeued_*.ready.txt' -File -ErrorAction SilentlyContinue)
Assert-True ($requeuedFiles.Count -eq 1) 'requeue should move the retry file into target inbox.'

$requeuedMeta = ($requeuedFiles[0].FullName + '.meta.json')
Assert-True (Test-Path -LiteralPath $requeuedMeta -PathType Leaf) 'requeue should move metadata sidecar with the retry file.'
$requeuedDeliveryMeta = ($requeuedFiles[0].FullName + '.delivery.json')
Assert-True (Test-Path -LiteralPath $requeuedDeliveryMeta -PathType Leaf) 'requeue should move delivery metadata sidecar with the retry file.'

$metadata = Get-Content -LiteralPath $requeuedMeta -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$metadata.FailureCategory -eq 'user_active_hold') 'requeued metadata should preserve failure category.'
Assert-True ([int]$metadata.RequeueCount -eq 1) 'requeued metadata should record the first requeue count.'
Assert-True ([string]$metadata.LastRequeuedFromRetryPath -eq $retryFile) 'requeued metadata should record the source retry path.'
Assert-True ([string]$metadata.LastRequeuedToReadyPath -eq $requeuedFiles[0].FullName) 'requeued metadata should record the destination ready path.'
Assert-True (@($metadata.RequeueHistory).Count -eq 1) 'requeued metadata should record requeue history.'
$deliveryMetadata = Get-Content -LiteralPath $requeuedDeliveryMeta -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$deliveryMetadata.LauncherSessionId -eq 'test-session') 'requeued delivery metadata should preserve launcher session.'
Assert-True (-not (Test-Path -LiteralPath $retryMeta -PathType Leaf)) 'original retry metadata should be removed from retry-pending root.'
Assert-True (-not (Test-Path -LiteralPath $retryDeliveryMeta -PathType Leaf)) 'original retry delivery metadata should be removed from retry-pending root.'

$currentRetryFile = Join-Path $retryPendingRoot 'target01__20260414_000001_000__current_message.ready.txt'
$staleRetryFile = Join-Path $retryPendingRoot 'target01__20260414_000002_000__stale_message.ready.txt'
[System.IO.File]::WriteAllText($currentRetryFile, 'current', (New-Utf8NoBomEncoding))
[System.IO.File]::WriteAllText($staleRetryFile, 'stale', (New-Utf8NoBomEncoding))
([ordered]@{
    SchemaVersion = '1.0.0'
    FailureCategory = 'user_active_hold'
    FailureMessage = 'current retry'
} | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath ($currentRetryFile + '.meta.json') -Encoding UTF8
([ordered]@{
    SchemaVersion = '1.0.0'
    FailureCategory = 'user_active_hold'
    FailureMessage = 'stale retry'
} | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath ($staleRetryFile + '.meta.json') -Encoding UTF8

$pathScopedOutput = & (Join-Path $root 'router\Requeue-RetryPending.ps1') -ConfigPath $configPath -RetryPath $currentRetryFile 2>&1
$requeuedFilesAfterPathScope = @(Get-ChildItem -LiteralPath $targetInbox -Filter 'requeued_*.ready.txt' -File -ErrorAction SilentlyContinue)
Assert-True ($requeuedFilesAfterPathScope.Count -eq 2) 'path-scoped requeue should move only the selected retry file into target inbox.'
Assert-True (-not (Test-Path -LiteralPath $currentRetryFile -PathType Leaf)) 'path-scoped requeue should remove the selected retry file.'
Assert-True (Test-Path -LiteralPath $staleRetryFile -PathType Leaf) 'path-scoped requeue should leave unselected stale retry files in retry-pending root.'

Write-Host ('requeue-retry-pending-metadata ok: inbox=' + $targetInbox)
