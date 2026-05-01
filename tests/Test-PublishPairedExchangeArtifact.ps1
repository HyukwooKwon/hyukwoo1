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
        Raw = $raw
        Json = $json
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
$contractRunRoot = Join-Path $pairRunRootBase ('run_publish_helper_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$target01Request = Get-Content -LiteralPath (Join-Path $contractRunRoot 'pair01\target01\request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$target05Request = Get-Content -LiteralPath (Join-Path $contractRunRoot 'pair01\target05\request.json') -Raw -Encoding UTF8 | ConvertFrom-Json

New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName([string]$target01Request.SourceSummaryPath)) -Force | Out-Null
[System.IO.File]::WriteAllText([string]$target01Request.SourceSummaryPath, 'publish helper summary ok', (New-Utf8NoBomEncoding))
$target01NotePath = Join-Path ([System.IO.Path]::GetDirectoryName([string]$target01Request.SourceReviewZipPath)) 'publish-helper-note.txt'
[System.IO.File]::WriteAllText($target01NotePath, 'publish helper zip ok', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $target01NotePath -DestinationPath ([string]$target01Request.SourceReviewZipPath) -Force

$publishOk = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'publish-paired-exchange-artifact.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-TargetId', 'target01',
    '-AsJson'
)
Assert-True ($publishOk.ExitCode -eq 0) 'publish helper should succeed for clean source artifacts.'
Assert-True ([bool]$publishOk.Json.PublishReadyCreated) 'publish helper should create marker for clean artifacts.'
Assert-True ([bool]$publishOk.Json.Marker.ValidationPassed) 'publish helper should stamp ValidationPassed=true.'
Assert-True ([string]$publishOk.Json.Marker.PublishedBy -eq 'publish-paired-exchange-artifact.ps1') 'publish helper should stamp PublishedBy.'
Assert-True ([int]$publishOk.Json.Marker.PublishSequence -eq 1) 'publish helper should stamp first publish sequence.'
Assert-True ([string]$publishOk.Json.Marker.PublishCycleId -match 'target01') 'publish helper should stamp target id into first publish cycle id.'
Assert-True ([string]$publishOk.Json.Marker.PublishCycleId -match '__publish_0001$') 'publish helper should stamp first publish cycle suffix.'
Assert-True ((Test-Path -LiteralPath ([string]$target01Request.PublishReadyPath) -PathType Leaf)) 'publish helper should write publish.ready.json.'

$publishOverwrite = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'publish-paired-exchange-artifact.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-TargetId', 'target01',
    '-Overwrite',
    '-AsJson'
)
Assert-True ($publishOverwrite.ExitCode -eq 0) 'publish helper overwrite should succeed for clean source artifacts.'
Assert-True ([int]$publishOverwrite.Json.Marker.PublishSequence -eq 2) 'publish helper overwrite should increment publish sequence.'
Assert-True ([string]$publishOverwrite.Json.Marker.PublishCycleId -match 'target01') 'publish helper overwrite should stamp target id into incremented cycle id.'
Assert-True ([string]$publishOverwrite.Json.Marker.PublishCycleId -match '__publish_0002$') 'publish helper overwrite should increment publish cycle suffix.'

New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName([string]$target05Request.SourceSummaryPath)) -Force | Out-Null
[System.IO.File]::WriteAllText([string]$target05Request.SourceSummaryPath, '여기에 고정문구 입력', (New-Utf8NoBomEncoding))
$target05NotePath = Join-Path ([System.IO.Path]::GetDirectoryName([string]$target05Request.SourceReviewZipPath)) 'publish-helper-bad-note.txt'
[System.IO.File]::WriteAllText($target05NotePath, 'publish helper bad zip', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $target05NotePath -DestinationPath ([string]$target05Request.SourceReviewZipPath) -Force

$publishBad = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'publish-paired-exchange-artifact.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-TargetId', 'target05',
    '-AsJson'
)
Assert-True ($publishBad.ExitCode -ne 0) 'publish helper should fail for forbidden source artifacts.'
Assert-True (-not [bool]$publishBad.Json.PublishReadyCreated) 'publish helper should not create marker for forbidden source artifacts.'
Assert-True (@($publishBad.Json.Validation.Issues | ForEach-Object { [string]$_ }) -contains 'summary-source-forbidden-artifact') 'publish helper should report forbidden summary artifact.'
Assert-True (-not (Test-Path -LiteralPath ([string]$target05Request.PublishReadyPath) -PathType Leaf)) 'publish helper should not write publish.ready.json for forbidden source artifacts.'

Write-Host ('publish paired exchange artifact helper ok: runRoot=' + $contractRunRoot)
