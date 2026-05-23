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
$testRoot = Join-Path $root '_tmp\test-send-initial-pair-seed-relay-folder-mismatch'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot | Out-Null

$runRoot = Join-Path $testRoot 'run'
$inboxRoot = Join-Path $testRoot 'inbox'
$inboxTarget01 = Join-Path $inboxRoot 'target01'
$expectedTarget05Inbox = Join-Path $inboxRoot 'target05'
$mismatchTarget05Inbox = Join-Path $testRoot 'different-inbox\target05'
foreach ($path in @($inboxTarget01, $expectedTarget05Inbox, $mismatchTarget05Inbox)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    MaxPayloadChars = 4000
    MaxPayloadBytes = 12000
    InboxRoot = '$($inboxRoot.Replace("'", "''"))'
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
            Folder = '$($mismatchTarget05Inbox.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestWindow05'
            FixedSuffix = `$null
        }
    )
    PairTest = @{
        RunRootBase = '$($testRoot.Replace("'", "''"))'
        ExecutionPathMode = 'typed-window'
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
    -SeedTaskText 'relay folder mismatch test' | Out-Null

$errorMessage = ''
try {
    & (Join-Path $root 'tests\Send-InitialPairSeed.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -TargetId target05 `
        -AsJson | Out-Null
    throw 'Send-InitialPairSeed should fail when the configured relay folder mismatches InboxRoot.'
}
catch {
    $errorMessage = [string]$_.Exception.Message
}

Assert-True ($errorMessage -match 'target relay folder mismatch:') 'relay folder mismatch should fail in preflight.'
Assert-True ($errorMessage -match 'target=target05') 'relay folder mismatch should identify the target.'
Assert-True ($errorMessage.Contains(('configFolder=' + $mismatchTarget05Inbox))) 'relay folder mismatch should include the configured folder.'
Assert-True ($errorMessage.Contains(('expectedFolder=' + $expectedTarget05Inbox))) 'relay folder mismatch should include the expected inbox-root folder.'
Assert-True (-not ($errorMessage -match 'Target folder not found:')) 'relay folder mismatch should fail before producer invocation.'

Write-Host ('send-initial-pair-seed relay-folder-mismatch ok: runRoot=' + $runRoot)
