[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [string[]]$TargetId,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Import-ConfigDataFile {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $importCommand = Get-Command -Name Import-PowerShellDataFile -ErrorAction SilentlyContinue
    if ($null -ne $importCommand) {
        return Import-PowerShellDataFile -Path $resolvedPath
    }

    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
    return [scriptblock]::Create($raw).InvokeReturnAsIs()
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "json file is empty: $Path"
    }
    return ($raw | ConvertFrom-Json)
}

function Convert-ProducerOutputToRawText {
    param([Parameter(Mandatory)][object[]]$ProducerOutput)

    $lines = @(
        $ProducerOutput |
            ForEach-Object { [string]$_ }
    )
    return (($lines -join [Environment]::NewLine).Trim())
}

function Invoke-ProducerReadyFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$TextFilePath
    )

    $producerScriptPath = Join-Path $Root 'producer-example.ps1'
    $producerOutput = & {
        & $producerScriptPath `
            -ConfigPath $ConfigPath `
            -TargetId $TargetKey `
            -TextFilePath $TextFilePath
    } 6>&1

    $producerRaw = Convert-ProducerOutputToRawText -ProducerOutput @($producerOutput)
    if ([string]::IsNullOrWhiteSpace($producerRaw)) {
        throw "producer returned no output for target: $TargetKey"
    }

    $readyPath = ''
    $match = [regex]::Match($producerRaw, 'created ready file:\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        $readyPath = [string]$match.Groups[1].Value.Trim()
    }

    return [pscustomobject]@{
        ReadyPath      = $readyPath
        ProducerOutput = $producerRaw
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$resolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "manifest not found: $manifestPath"
}

$config = Import-ConfigDataFile -Path $resolvedConfigPath
$manifest = Read-JsonObject -Path $manifestPath
$manifestTargets = @($manifest.Targets)
if ($manifestTargets.Count -eq 0) {
    throw "manifest contains no targets: $manifestPath"
}

$requestedTargetIds = @($TargetId | Where-Object { Test-NonEmptyString $_ } | ForEach-Object { [string]$_ })
if ($requestedTargetIds.Count -eq 0) {
    $requestedTargetIds = @($manifest.SeedTargetIds | Where-Object { Test-NonEmptyString $_ } | ForEach-Object { [string]$_ })
}
if ($requestedTargetIds.Count -eq 0) {
    $requestedTargetIds = @(
        $manifestTargets |
            Where-Object { ($_.SeedEnabled -eq $true) -or ([string]$_.InitialRoleMode -eq 'seed') } |
            ForEach-Object { [string]$_.TargetId }
    )
}
if ($requestedTargetIds.Count -eq 0) {
    throw "no seed targets could be resolved from manifest: $manifestPath"
}

$selectedTargets = @()
foreach ($id in $requestedTargetIds) {
    $row = @($manifestTargets | Where-Object { [string]$_.TargetId -eq $id } | Select-Object -First 1)
    if ($row.Count -eq 0) {
        throw "target not found in manifest: $id"
    }
    $selectedTargets += $row[0]
}

$results = @()
foreach ($row in $selectedTargets) {
    $targetKey = [string]$row.TargetId
    $messagePath = [string]$row.MessagePath
    if (-not (Test-NonEmptyString $messagePath) -and (Test-NonEmptyString ([string]$row.RequestPath)) -and (Test-Path -LiteralPath ([string]$row.RequestPath) -PathType Leaf)) {
        $request = Read-JsonObject -Path ([string]$row.RequestPath)
        $messagePath = [string]$request.MessagePath
    }
    if (-not (Test-NonEmptyString $messagePath)) {
        throw "message path missing for target: $targetKey"
    }
    $resolvedMessagePath = (Resolve-Path -LiteralPath $messagePath).Path

    $targetConfig = @($config.Targets | Where-Object { [string]$_.Id -eq $targetKey } | Select-Object -First 1)
    if ($targetConfig.Count -eq 0) {
        throw "target relay config not found: $targetKey"
    }

    $producerResult = Invoke-ProducerReadyFile `
        -Root $root `
        -ConfigPath $resolvedConfigPath `
        -TargetKey $targetKey `
        -TextFilePath $resolvedMessagePath

    $results += [pscustomobject]@{
        TargetId      = $targetKey
        MessagePath   = $resolvedMessagePath
        ReadyPath     = [string]$producerResult.ReadyPath
        ProducerOutput = [string]$producerResult.ProducerOutput
    }
}

$result = [pscustomobject]@{
    RunRoot        = $resolvedRunRoot
    ConfigPath     = $resolvedConfigPath
    RequestedTargets = @($requestedTargetIds)
    Results          = @($results)
}

if ($AsJson) {
    Write-Output ($result | ConvertTo-Json -Depth 6)
}
else {
    Write-Output $result
}
