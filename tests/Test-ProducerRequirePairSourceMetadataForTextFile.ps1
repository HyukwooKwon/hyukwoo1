[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\router\RelayMessageMetadata.ps1')

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-producer-require-pair-source-metadata'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot | Out-Null

$inboxRoot = Join-Path $testRoot 'inbox'
$runtimeRoot = Join-Path $testRoot 'runtime'
$target01Root = Join-Path $inboxRoot 'target01'
$logsRoot = Join-Path $testRoot 'logs'
$messageRoot = Join-Path $testRoot 'messages'

foreach ($path in @($inboxRoot, $runtimeRoot, $target01Root, $logsRoot, $messageRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$configPath = Join-Path $testRoot 'settings.require-pair-source-metadata.psd1'
$configText = @"
@{
    RuntimeMapPath = '$($(Join-Path $runtimeRoot 'target-runtime.json').Replace("'", "''"))'
    RequirePairTransportMetadata = `$true
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($target01Root.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'ProducerRequirePairSourceMetadata-01'
            FixedSuffix = `$null
        }
    )
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$runtimeSeed = @(
    [pscustomobject]@{
        TargetId          = 'target01'
        ShellPid          = 0
        WindowPid         = 0
        Hwnd              = ''
        Title             = 'ProducerRequirePairSourceMetadata-01'
        StartedAt         = (Get-Date).ToString('o')
        ShellPath         = 'pwsh.exe'
        Available         = $false
        ResolvedBy        = ''
        LookupSucceededAt = ''
        LauncherSessionId = 'session-producer'
        LaunchedAt        = (Get-Date).ToString('o')
        LauncherPid       = $PID
        ProcessName       = 'pwsh'
        WindowClass       = 'ConsoleWindowClass'
        HostKind          = 'test'
    }
)
[System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'target-runtime.json'), ($runtimeSeed | ConvertTo-Json -Depth 6), (New-Utf8NoBomEncoding))

$messagePath = Join-Path $messageRoot 'target01.txt'
[System.IO.File]::WriteAllText($messagePath, 'producer pair metadata contract smoke', (New-Utf8NoBomEncoding))

$missingMetadataFailure = $false
$missingMetadataMessage = ''
try {
    & (Join-Path $root 'producer-example.ps1') -ConfigPath $configPath -TargetId 'target01' -TextFilePath $messagePath | Out-Null
}
catch {
    $missingMetadataFailure = $true
    $missingMetadataMessage = $_.Exception.Message
}

Assert-True $missingMetadataFailure 'producer should fail when pair transport metadata is enforced and source relay metadata is missing.'
Assert-True ($missingMetadataMessage -like '*Relay metadata required for TextFilePath when pair transport metadata is enforced*') 'producer should explain that source relay metadata is required for TextFilePath.'
Assert-True (@(Get-ChildItem -LiteralPath $target01Root -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue).Count -eq 0) 'producer must not create a ready file when source relay metadata is missing.'

$invalidMessageMetadata = New-PairedRelayMessageMetadata `
    -RunRoot (Join-Path $testRoot 'run_20260423_000000') `
    -PairId 'pair01' `
    -TargetId 'target01' `
    -PartnerTargetId 'target05' `
    -RoleName 'top' `
    -InitialRoleMode 'seed' `
    -MessageType 'pair-seed' `
    -MessagePath $messagePath `
    -LauncherSessionId 'session-producer'
$invalidMessageMetadata.PairId = ''
Write-RelayMessageMetadata -MessagePath $messagePath -Metadata $invalidMessageMetadata | Out-Null

$invalidMetadataFailure = $false
$invalidMetadataMessage = ''
try {
    & (Join-Path $root 'producer-example.ps1') -ConfigPath $configPath -TargetId 'target01' -TextFilePath $messagePath | Out-Null
}
catch {
    $invalidMetadataFailure = $true
    $invalidMetadataMessage = $_.Exception.Message
}

Assert-True $invalidMetadataFailure 'producer should fail when pair source relay metadata is present but missing required fields.'
Assert-True ($invalidMetadataMessage -like '*Pair relay metadata missing fields for TextFilePath*') 'producer should explain which pair relay metadata fields are missing.'
Assert-True ($invalidMetadataMessage -like '*PairId*') 'producer should mention the missing PairId field.'
Assert-True (@(Get-ChildItem -LiteralPath $target01Root -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue).Count -eq 0) 'producer must not create a ready file when pair source relay metadata is invalid.'

Write-Host ('producer require-pair-source-metadata ok: root=' + $testRoot)
