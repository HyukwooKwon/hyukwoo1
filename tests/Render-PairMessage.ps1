[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [Parameter(Mandatory)][string]$PairId,
    [Parameter(Mandatory)][string]$TargetId,
    [ValidateSet('both', 'initial', 'handoff')][string]$Mode = 'both',
    [string]$OutputRoot,
    [switch]$WriteOutputs,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (Test-NonEmptyString $directory) {
        Ensure-Directory -Path $directory
    }

    $encoding = New-Utf8NoBomEncoding
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Invoke-ShowEffectiveConfigJson {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [string]$RequestedRunRoot,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$Mode
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'show-effective-config.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-PairId', $PairId,
        '-TargetId', $TargetId,
        '-Mode', $Mode,
        '-AsJson'
    )
    if (Test-NonEmptyString $RequestedRunRoot) {
        $arguments += @('-RunRoot', $RequestedRunRoot)
    }

    $powershellPath = (Get-Command -Name 'powershell.exe' -ErrorAction Stop | Select-Object -First 1).Source
    $jsonText = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        $detail = (($jsonText | Out-String).Trim())
        throw ("show-effective-config failed: " + $detail)
    }

    return ($jsonText | ConvertFrom-Json)
}

function Resolve-OutputRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$EffectiveConfig,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [string]$RequestedOutputRoot
    )

    if (Test-NonEmptyString $RequestedOutputRoot) {
        if ([System.IO.Path]::IsPathRooted($RequestedOutputRoot)) {
            return [System.IO.Path]::GetFullPath($RequestedOutputRoot)
        }

        return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $RequestedOutputRoot))
    }

    $laneName = [string](Get-ConfigValue -Object $EffectiveConfig.Config -Name 'LaneName' -DefaultValue 'default')
    if (-not (Test-NonEmptyString $laneName)) {
        $laneName = 'default'
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    return (Join-Path $Root ('_tmp\rendered-messages\{0}\{1}\{2}\{3}' -f $laneName, $PairId, $TargetId, $stamp))
}

function New-RenderedEnvelope {
    param(
        [Parameter(Mandatory)]$EffectiveConfig,
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][ValidateSet('initial', 'handoff')][string]$MessageType
    )

    $messageNode = if ($MessageType -eq 'initial') { $Row.Initial } else { $Row.Handoff }
    if ($null -eq $messageNode) {
        throw ("selected preview row does not contain " + $MessageType + " message data.")
    }

    $configuredMessagePath = if ($MessageType -eq 'initial') {
        [string](Get-ConfigValue -Object $Row -Name 'InitialMessagePath' -DefaultValue '')
    }
    else {
        [string](Get-ConfigValue -Object $Row -Name 'HandoffMessagePattern' -DefaultValue '')
    }

    return [pscustomobject]@{
        SchemaVersion = '1.0.0'
        GeneratedAt = (Get-Date).ToString('o')
        LaneName = [string]$EffectiveConfig.Config.LaneName
        Config = [pscustomobject]@{
            ConfigPath = [string]$EffectiveConfig.Config.ConfigPath
            ConfigHash = [string]$EffectiveConfig.Config.ConfigHash
            LaneName = [string]$EffectiveConfig.Config.LaneName
            WindowTitlePrefix = [string]$EffectiveConfig.Config.WindowTitlePrefix
        }
        RunContext = [pscustomobject]@{
            SelectedRunRoot = [string]$EffectiveConfig.RunContext.SelectedRunRoot
            SelectedRunRootSource = [string]$EffectiveConfig.RunContext.SelectedRunRootSource
            SelectedRunRootIsStale = [bool]$EffectiveConfig.RunContext.SelectedRunRootIsStale
        }
        PairId = [string]$Row.PairId
        RoleName = [string]$Row.RoleName
        TargetId = [string]$Row.TargetId
        PartnerTargetId = [string]$Row.PartnerTargetId
        MessageType = $MessageType
        ConfiguredPaths = [pscustomobject]@{
            PairTargetFolder = [string](Get-ConfigValue -Object $Row -Name 'PairTargetFolder' -DefaultValue '')
            PartnerFolder = [string](Get-ConfigValue -Object $Row -Name 'PartnerFolder' -DefaultValue '')
            SummaryPath = [string](Get-ConfigValue -Object $Row -Name 'SummaryPath' -DefaultValue '')
            ReviewFolderPath = [string](Get-ConfigValue -Object $Row -Name 'ReviewFolderPath' -DefaultValue '')
            ReviewZipPreviewPath = [string](Get-ConfigValue -Object $Row -Name 'ReviewZipPreviewPath' -DefaultValue '')
            ConfiguredMessagePath = $configuredMessagePath
            RequestPath = [string](Get-ConfigValue -Object $Row -Name 'RequestPath' -DefaultValue '')
            PromptPath = [string](Get-ConfigValue -Object $Row -Name 'PromptPath' -DefaultValue '')
            DonePath = [string](Get-ConfigValue -Object $Row -Name 'DonePath' -DefaultValue '')
            ErrorPath = [string](Get-ConfigValue -Object $Row -Name 'ErrorPath' -DefaultValue '')
            ResultPath = [string](Get-ConfigValue -Object $Row -Name 'ResultPath' -DefaultValue '')
        }
        PathState = $Row.PathState
        AppliedSources = @($messageNode.AppliedSources)
        MessagePlan = $messageNode.MessagePlan
        OneTimeItems = @($(Get-ConfigValue -Object $messageNode -Name 'PendingOneTimeItems' -DefaultValue @()))
        RenderedText = [string]$messageNode.Preview
        WarningSummary = $EffectiveConfig.WarningSummary
        EvidencePolicy = $EffectiveConfig.EvidencePolicy
        PreviewOnly = $true
    }
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$effectiveConfig = Invoke-ShowEffectiveConfigJson `
    -Root $root `
    -ResolvedConfigPath $resolvedConfigPath `
    -RequestedRunRoot $RunRoot `
    -PairId $PairId `
    -TargetId $TargetId `
    -Mode $Mode

$rows = @($effectiveConfig.PreviewRows)
if ($rows.Count -ne 1) {
    throw ("expected exactly 1 preview row but got " + $rows.Count)
}

$row = $rows[0]
$messageTypes = if ($Mode -eq 'both') { @('initial', 'handoff') } else { @($Mode) }
$resolvedOutputRoot = Resolve-OutputRoot `
    -Root $root `
    -EffectiveConfig $effectiveConfig `
    -PairId $PairId `
    -TargetId $TargetId `
    -RequestedOutputRoot $OutputRoot

$outputs = New-Object System.Collections.ArrayList
foreach ($messageType in $messageTypes) {
    $envelope = New-RenderedEnvelope -EffectiveConfig $effectiveConfig -Row $row -MessageType $messageType
    $jsonPath = Join-Path $resolvedOutputRoot ($messageType + '.envelope.json')
    $textPath = Join-Path $resolvedOutputRoot ($messageType + '.rendered.txt')

    if ($WriteOutputs -or (Test-NonEmptyString $OutputRoot)) {
        Ensure-Directory -Path $resolvedOutputRoot
        Write-Utf8NoBomFile -Path $jsonPath -Content ($envelope | ConvertTo-Json -Depth 10)
        Write-Utf8NoBomFile -Path $textPath -Content ([string]$envelope.RenderedText)
    }

    [void]$outputs.Add([pscustomobject]@{
        MessageType = $messageType
        Envelope = $envelope
        OutputPaths = [pscustomobject]@{
            OutputRoot = $resolvedOutputRoot
            EnvelopeJson = $jsonPath
            RenderedText = $textPath
            WroteFiles = [bool]($WriteOutputs -or (Test-NonEmptyString $OutputRoot))
        }
    })
}

$result = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = (Get-Date).ToString('o')
    ConfigPath = $resolvedConfigPath
    RunRoot = [string]$effectiveConfig.RunContext.SelectedRunRoot
    PairId = $PairId
    TargetId = $TargetId
    Mode = $Mode
    OutputRoot = $resolvedOutputRoot
    Messages = @($outputs)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Host ("Rendered message bundle ready: {0}" -f $resolvedOutputRoot)
foreach ($item in @($result.Messages)) {
    Write-Host ("- {0}" -f [string]$item.MessageType)
    Write-Host ("  envelope: {0}" -f [string]$item.OutputPaths.EnvelopeJson)
    Write-Host ("  rendered: {0}" -f [string]$item.OutputPaths.RenderedText)
    Write-Host ("  wrote files: {0}" -f [bool]$item.OutputPaths.WroteFiles)
}
