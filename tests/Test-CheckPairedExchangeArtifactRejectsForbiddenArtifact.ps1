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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }
        if ($command.Source) {
            return [string]$command.Source
        }
        if ($command.Path) {
            return [string]$command.Path
        }
        return [string]$name
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Invoke-PowerShellJson {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $ScriptPath @Arguments
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Raw      = ($result | Out-String).Trim()
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$baseConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$tempWorkRepoRoot = Join-Path 'C:\dev\python\_relay-test-fixtures' ('check-forbidden-artifact-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempWorkRepoRoot -Force | Out-Null
$seedReviewInputPath = Join-Path $tempWorkRepoRoot 'reviewfile\seed-review-input.txt'
New-Item -ItemType Directory -Path (Split-Path -Parent $seedReviewInputPath) -Force | Out-Null
'fixture seed review input' | Set-Content -LiteralPath $seedReviewInputPath -Encoding UTF8
$externalizedConfigPath = Join-Path $tempWorkRepoRoot '.relay-config\bottest-live-visible\settings.externalized.psd1'

try {
    & (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
        -BaseConfigPath $baseConfigPath `
        -WorkRepoRoot $tempWorkRepoRoot `
        -OutputConfigPath $externalizedConfigPath `
        -ReviewInputPath $seedReviewInputPath | Out-Null

    $resolvedConfigPath = (Resolve-Path -LiteralPath $externalizedConfigPath).Path
    $config = Import-PowerShellDataFile -Path $resolvedConfigPath
    $pairRunRootBase = [string]$config.PairTest.RunRootBase
    $runRoot = Join-Path $pairRunRootBase ('run_check_forbidden_artifact_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

    & (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $resolvedConfigPath `
        -RunRoot $runRoot `
        -IncludePairId pair01 `
        -SeedTargetId target01 `
        -SeedWorkRepoRoot $tempWorkRepoRoot `
        -SeedReviewInputPath $seedReviewInputPath `
        -SeedTaskText 'forbidden artifact validation test' | Out-Null

    $sourceRoot = Join-Path $tempWorkRepoRoot '_forbidden_source'
    New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
    $summarySourcePath = Join-Path $sourceRoot 'summary.txt'
    $zipNotePath = Join-Path $sourceRoot 'note.txt'
    $reviewZipSourcePath = Join-Path $sourceRoot 'review.zip'
    [System.IO.File]::WriteAllText($summarySourcePath, "정상 요약이 아닙니다.`r`n여기에 고정문구 입력", (New-Utf8NoBomEncoding))
    [System.IO.File]::WriteAllText($zipNotePath, 'normal zip content', (New-Utf8NoBomEncoding))
    Compress-Archive -LiteralPath $zipNotePath -DestinationPath $reviewZipSourcePath -Force
    Remove-Item -LiteralPath $zipNotePath -Force

    $result = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'check-paired-exchange-artifact.ps1') -Arguments @(
        '-ConfigPath', $resolvedConfigPath,
        '-RunRoot', $runRoot,
        '-TargetId', 'target01',
        '-SummarySourcePath', $summarySourcePath,
        '-ReviewZipSourcePath', $reviewZipSourcePath,
        '-AsJson'
    )

    Assert-True ($result.ExitCode -eq 1) 'check-paired-exchange-artifact should fail when forbidden artifact text is present.'
    $json = $result.Raw | ConvertFrom-Json
    Assert-True ($json.Validation.Issues -contains 'summary-source-forbidden-artifact') 'validation should report forbidden summary artifact issue.'
    Assert-True ([bool]$json.Validation.ForbiddenArtifactChecks.Summary.Found) 'summary forbidden artifact check should surface a match.'
    Assert-True (-not [bool]$json.Validation.ForbiddenArtifactChecks.ReviewZip.Found) 'review zip forbidden artifact check should remain false for clean zip content.'

    Write-Host 'check-paired-exchange-artifact forbidden artifact validation ok'
}
finally {
    if (Test-Path -LiteralPath $tempWorkRepoRoot) {
        Remove-Item -LiteralPath $tempWorkRepoRoot -Recurse -Force
    }
}
