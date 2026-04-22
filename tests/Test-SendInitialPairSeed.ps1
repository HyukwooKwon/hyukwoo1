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
$testRoot = Join-Path $root '_tmp\test-send-initial-pair-seed'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot | Out-Null

$runRoot = Join-Path $testRoot 'run'
$inboxTarget01 = Join-Path $testRoot 'inbox\target01'
$inboxTarget05 = Join-Path $testRoot 'inbox\target05'
New-Item -ItemType Directory -Path $inboxTarget01 -Force | Out-Null
New-Item -ItemType Directory -Path $inboxTarget05 -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    MaxPayloadChars = 4000
    MaxPayloadBytes = 12000
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($inboxTarget01.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestWindow01'
            FixedSuffix = `$null
        }
        @{
            Id = 'target05'
            Folder = '$($inboxTarget05.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestWindow05'
            FixedSuffix = `$null
        }
    )
    PairTest = @{
        RunRootBase = '$($testRoot.Replace("'", "''"))'
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$reviewInputPath = Join-Path $root 'README.md'
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 `
    -SeedWorkRepoRoot $root `
    -SeedReviewInputPath $reviewInputPath `
    -SeedTaskText 'seed resend test' | Out-Null

$seedResultRaw = & (Join-Path $root 'tests\Send-InitialPairSeed.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$seedResult = $seedResultRaw | ConvertFrom-Json

Assert-True ($seedResult.Results.Count -eq 1) 'seed resend should queue exactly one target by default.'
$row = $seedResult.Results[0]
Assert-True ([string]$row.TargetId -eq 'target01') 'seed resend should default to manifest seed target target01.'
Assert-True (Test-Path -LiteralPath ([string]$row.MessagePath) -PathType Leaf) 'message path should exist.'
Assert-True (Test-Path -LiteralPath ([string]$row.ReadyPath) -PathType Leaf) 'ready file should be created in target01 inbox.'

$readyBody = [System.IO.File]::ReadAllText([string]$row.ReadyPath, [System.Text.UTF8Encoding]::new($false, $true))
$messageBody = [System.IO.File]::ReadAllText([string]$row.MessagePath, [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($readyBody -eq $messageBody) 'ready file body should match the prepared message file exactly.'

$messageMetadataPath = ([string]$row.MessagePath + '.relay.json')
$readyMetadataPath = ([string]$row.ReadyPath + '.delivery.json')
Assert-True (Test-Path -LiteralPath $messageMetadataPath -PathType Leaf) 'message metadata sidecar should exist.'
Assert-True (Test-Path -LiteralPath $readyMetadataPath -PathType Leaf) 'ready metadata sidecar should exist.'

$messageMetadata = Get-Content -LiteralPath $messageMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
$readyMetadata = Get-Content -LiteralPath $readyMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$messageMetadata.PairId -eq 'pair01') 'message metadata should record pair01.'
Assert-True ([string]$messageMetadata.TargetId -eq 'target01') 'message metadata should record target01.'
Assert-True ([string]$messageMetadata.MessageType -eq 'pair-seed') 'message metadata should classify the initial seed.'
Assert-True ([string]$messageMetadata.RunId -eq 'run') 'message metadata should derive the run id from the run root.'
Assert-True ([string]$readyMetadata.TargetId -eq 'target01') 'ready metadata should record the delivery target.'
Assert-True ([string]$readyMetadata.MessageType -eq 'pair-seed') 'ready metadata should preserve the pair message type.'
Assert-True ([string]$readyMetadata.RunId -eq 'run') 'ready metadata should preserve the run id for pair transport.'
Assert-True ([string]$readyMetadata.PairId -eq 'pair01') 'ready metadata should preserve the pair id for pair transport.'
Assert-True ([string]$readyMetadata.PartnerTargetId -eq 'target05') 'ready metadata should preserve the partner target id for pair transport.'

$target05ReadyFiles = @(Get-ChildItem -LiteralPath $inboxTarget05 -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue)
Assert-True ($target05ReadyFiles.Count -eq 0) 'partner target should not be queued when no explicit TargetId is requested.'

Write-Host ('send-initial-pair-seed ok: runRoot=' + $runRoot)
