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

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $preferredExternalizedConfigPath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-config\bottest-live-visible\settings.externalized.psd1'
    if (Test-Path -LiteralPath $preferredExternalizedConfigPath -PathType Leaf) {
        $ConfigPath = $preferredExternalizedConfigPath
    }
    else {
        $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
    }
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$runRoot = Join-Path $pairRunRootBase ('run_instruction_helper_wording_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 | Out-Null

$targetRoot = Join-Path $runRoot 'pair01\target01'
$instructionPath = Join-Path $targetRoot 'instructions.txt'
$messagePath = Join-Path (Join-Path $runRoot 'messages') 'target01.txt'
$instructionText = Get-Content -LiteralPath $instructionPath -Raw -Encoding UTF8
$messageText = Get-Content -LiteralPath $messagePath -Raw -Encoding UTF8

Assert-True ($instructionText.Contains('내가 직접 생성할 파일:')) 'instructions should distinguish directly created files.'
Assert-True ($instructionText.Contains('마지막 실행:')) 'instructions should include a dedicated final helper step.'
Assert-True ($instructionText.Contains('helper output marker:')) 'instructions should describe publish.ready.json as helper output.'
Assert-True ($instructionText.Contains('publish helper')) 'instructions should mention publish helper.'
Assert-True (-not $instructionText.Contains('summary.txt, review.zip, publish.ready.json 세 파일로만 publish')) 'instructions should not describe publish.ready.json as a direct output trio.'
Assert-True (-not $messageText.Contains('publish.ready.json 을 생성합니다.')) 'initial message should not instruct direct publish.ready.json creation.'
Assert-True ($messageText.Contains('publish.ready.json 은 helper가 자동 생성/overwrite합니다.')) 'initial message should say the helper creates publish.ready.json.'

Write-Host ('start-paired-exchange publish helper wording ok: runRoot=' + $runRoot)
