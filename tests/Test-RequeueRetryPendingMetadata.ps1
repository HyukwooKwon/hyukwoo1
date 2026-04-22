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
[System.IO.File]::WriteAllText($retryFile, 'sample', (New-Utf8NoBomEncoding))
([ordered]@{
    SchemaVersion = '1.0.0'
    FailureCategory = 'user_active_hold'
    FailureMessage = 'AHK exit code: 43'
} | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $retryMeta -Encoding UTF8

$output = & (Join-Path $root 'router\Requeue-RetryPending.ps1') -ConfigPath $configPath -TargetId target01 2>&1

$requeuedFiles = @(Get-ChildItem -LiteralPath $targetInbox -Filter 'requeued_*.ready.txt' -File -ErrorAction SilentlyContinue)
Assert-True ($requeuedFiles.Count -eq 1) 'requeue should move the retry file into target inbox.'

$requeuedMeta = ($requeuedFiles[0].FullName + '.meta.json')
Assert-True (Test-Path -LiteralPath $requeuedMeta -PathType Leaf) 'requeue should move metadata sidecar with the retry file.'

$metadata = Get-Content -LiteralPath $requeuedMeta -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$metadata.FailureCategory -eq 'user_active_hold') 'requeued metadata should preserve failure category.'
Assert-True (-not (Test-Path -LiteralPath $retryMeta -PathType Leaf)) 'original retry metadata should be removed from retry-pending root.'

Write-Host ('requeue-retry-pending-metadata ok: inbox=' + $targetInbox)
