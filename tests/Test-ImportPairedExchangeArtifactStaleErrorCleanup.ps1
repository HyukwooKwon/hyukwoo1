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
    $exitCode = $LASTEXITCODE
    $raw = ($result | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "script returned no output: $ScriptPath"
    }

    try {
        $json = $raw | ConvertFrom-Json
    }
    catch {
        throw "json parse failed: $ScriptPath raw=$raw"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Raw      = $raw
        Json     = $json
    }
}

function New-ExternalArtifactSource {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $summaryPath = Join-Path $Root ($Label + '-summary.txt')
    $notePath = Join-Path $Root ($Label + '-note.txt')
    $zipPath = Join-Path $Root ($Label + '-review.zip')
    [System.IO.File]::WriteAllText($summaryPath, ($Label + ' summary'), (New-Utf8NoBomEncoding))
    [System.IO.File]::WriteAllText($notePath, ($Label + ' zip content'), (New-Utf8NoBomEncoding))
    Compress-Archive -LiteralPath $notePath -DestinationPath $zipPath -Force

    return [pscustomobject]@{
        SummaryPath = $summaryPath
        ZipPath     = $zipPath
    }
}

function New-ContractRunRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$PairRunRootBase,
        [Parameter(Mandatory)][string]$Label
    )

    $runRoot = Join-Path $PairRunRootBase ('run_contract_import_stale_error_' + $Label + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    & (Join-Path $Root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $ResolvedConfigPath `
        -RunRoot $runRoot `
        -IncludePairId pair01 | Out-Null
    return $runRoot
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase

$cases = @(
    [pscustomobject]@{
        Label                 = 'matching'
        ErrorContentKind      = 'json'
        ShouldRemoveErrorFile = $true
    },
    [pscustomobject]@{
        Label                 = 'matching-timeout'
        ErrorContentKind      = 'json-timeout'
        ShouldRemoveErrorFile = $true
    },
    [pscustomobject]@{
        Label                 = 'unrelated'
        ErrorContentKind      = 'json-other-path'
        ShouldRemoveErrorFile = $false
    },
    [pscustomobject]@{
        Label                 = 'summary-path-only-match'
        ErrorContentKind      = 'json-summary-only-match'
        ShouldRemoveErrorFile = $false
    },
    [pscustomobject]@{
        Label                 = 'malformed'
        ErrorContentKind      = 'malformed-json'
        ShouldRemoveErrorFile = $false
    }
)

foreach ($case in $cases) {
    $runRoot = New-ContractRunRoot -Root $root -ResolvedConfigPath $resolvedConfigPath -PairRunRootBase $pairRunRootBase -Label ([string]$case.Label)
    $sourceRoot = Join-Path $runRoot '_external_artifact_source'
    $source = New-ExternalArtifactSource -Root $sourceRoot -Label ([string]$case.Label)

    $targetRoot = Join-Path $runRoot 'pair01\target01'
    $requestPath = Join-Path $targetRoot 'request.json'
    $summaryPath = Join-Path $targetRoot 'summary.txt'
    $errorPath = Join-Path $targetRoot 'error.json'
    $publishReadyPath = Join-Path $targetRoot 'source-outbox\publish.ready.json'

    switch ([string]$case.ErrorContentKind) {
        'json' {
            ([ordered]@{
                    FailedAt         = (Get-Date).AddMinutes(-10).ToString('o')
                    Reason           = 'summary-missing-after-exec'
                    RequestPath      = $requestPath
                    SummaryPath      = $summaryPath
                    SourceSummaryPath = [string]$source.SummaryPath
                    SourceReviewZipPath = [string]$source.ZipPath
                    PublishReadyPath = $publishReadyPath
                } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $errorPath -Encoding UTF8
        }
        'json-timeout' {
            ([ordered]@{
                    FailedAt         = (Get-Date).AddMinutes(-10).ToString('o')
                    Reason           = 'codex-exec-timeout'
                    RequestPath      = $requestPath
                    SummaryPath      = $summaryPath
                    SourceSummaryPath = [string]$source.SummaryPath
                    SourceReviewZipPath = [string]$source.ZipPath
                    PublishReadyPath = $publishReadyPath
                } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $errorPath -Encoding UTF8
        }
        'json-other-path' {
            ([ordered]@{
                    FailedAt         = (Get-Date).AddMinutes(-10).ToString('o')
                    Reason           = 'summary-missing-after-exec'
                    RequestPath      = (Join-Path $targetRoot 'request-other.json')
                    SummaryPath      = (Join-Path $targetRoot 'summary-other.txt')
                    SourceSummaryPath = (Join-Path $sourceRoot 'other-summary.txt')
                    SourceReviewZipPath = (Join-Path $sourceRoot 'other-review.zip')
                    PublishReadyPath = (Join-Path $sourceRoot 'other-publish.ready.json')
                } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $errorPath -Encoding UTF8
        }
        'json-summary-only-match' {
            ([ordered]@{
                    FailedAt         = (Get-Date).AddMinutes(-10).ToString('o')
                    Reason           = 'summary-missing-after-exec'
                    RequestPath      = (Join-Path $targetRoot 'request-other.json')
                    SummaryPath      = $summaryPath
                    SourceSummaryPath = (Join-Path $sourceRoot 'other-summary.txt')
                    SourceReviewZipPath = (Join-Path $sourceRoot 'other-review.zip')
                    PublishReadyPath = (Join-Path $sourceRoot 'other-publish.ready.json')
                } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $errorPath -Encoding UTF8
        }
        'malformed-json' {
            Set-Content -LiteralPath $errorPath -Value '{"Reason": "summary-missing-after-exec",' -Encoding UTF8
        }
    }

    $import = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'import-paired-exchange-artifact.ps1') -Arguments @(
        '-ConfigPath', $resolvedConfigPath,
        '-RunRoot', $runRoot,
        '-TargetId', 'target01',
        '-SummarySourcePath', ([string]$source.SummaryPath),
        '-ReviewZipSourcePath', ([string]$source.ZipPath),
        '-AsJson'
    )

    Assert-True ($import.ExitCode -eq 0) ('import should succeed for stale error cleanup case: ' + [string]$case.Label)
    if ([bool]$case.ShouldRemoveErrorFile) {
        Assert-True (-not (Test-Path -LiteralPath $errorPath)) ('matching stale error file should be removed: ' + [string]$case.Label)
    }
    else {
        Assert-True (Test-Path -LiteralPath $errorPath) ('non-matching or malformed error file should remain: ' + [string]$case.Label)
    }
}

Write-Host 'import-paired-exchange-artifact stale error cleanup contract ok'
