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
$testRoot = Join-Path $root '_tmp\test-send-initial-pair-seed-missing-relay-folder'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot | Out-Null

$runRoot = Join-Path $testRoot 'run'
$inboxRoot = Join-Path $testRoot 'inbox'
$inboxTarget01 = Join-Path $inboxRoot 'target01'
$inboxTarget05 = Join-Path $inboxRoot 'target05'
New-Item -ItemType Directory -Path $inboxTarget01 -Force | Out-Null
New-Item -ItemType Directory -Path $inboxTarget05 -Force | Out-Null

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
            Folder = '$($inboxTarget05.Replace("'", "''"))'
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
    -SeedTaskText 'missing relay folder test' | Out-Null

Remove-Item -LiteralPath $inboxTarget05 -Recurse -Force

$errorMessage = ''
try {
    & (Join-Path $root 'tests\Send-InitialPairSeed.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -TargetId target05 `
        -AsJson | Out-Null
    throw 'Send-InitialPairSeed should fail when the configured relay folder is missing.'
}
catch {
    $errorMessage = [string]$_.Exception.Message
}

Assert-True ($errorMessage -match 'target relay folder missing:') 'missing relay folder should fail before producer invocation.'
Assert-True ($errorMessage -match 'target=target05') 'missing relay folder error should identify the target.'
Assert-True ($errorMessage.Contains($inboxTarget05)) 'missing relay folder error should include the configured folder path.'
Assert-True ($errorMessage.Contains(('expectedFolder=' + $inboxTarget05))) 'missing relay folder error should include the expected inbox-root folder path.'
Assert-True (-not ($errorMessage -match 'Target folder not found:')) 'missing relay folder should fail in preflight instead of producer-example.'

Write-Host ('send-initial-pair-seed missing-relay-folder ok: runRoot=' + $runRoot)
