[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [Parameter(Mandatory)][ValidateSet('pause', 'resume', 'stop')][string]$Action,
    [string]$RequestedBy = 'relay_operator_panel',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
$resolvedRunRoot = Resolve-TargetAutoloopRunRoot -Config $config -RequestedRunRoot $RunRoot
$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
$controlDocument = if (Test-Path -LiteralPath $statePaths.ControlPath -PathType Leaf) {
    Read-JsonObject -Path $statePaths.ControlPath
}
else {
    New-TargetAutoloopControlDocument -Config $config -RunRoot $resolvedRunRoot
}

$result = Request-TargetAutoloopControlAction -ControlDocument $controlDocument -Action $Action -RequestedBy $RequestedBy
$controlDocument.LastUpdatedAt = (Get-Date).ToString('o')
Write-JsonFileAtomically -Path $statePaths.ControlPath -Payload $controlDocument
$stateDocument = if (Test-Path -LiteralPath $statePaths.StatePath -PathType Leaf) {
    Read-JsonObject -Path $statePaths.StatePath
}
else {
    $null
}
$statusDocument = if (Test-Path -LiteralPath $statePaths.StatusPath -PathType Leaf) {
    Read-JsonObject -Path $statePaths.StatusPath
}
else {
    $null
}
if ($null -ne $stateDocument) {
    Sync-TargetAutoloopTargetSidecarDocuments `
        -Config $config `
        -RunRoot $resolvedRunRoot `
        -StateDocument $stateDocument `
        -ControlDocument $controlDocument `
        -StatusDocument $statusDocument `
        -WriteState:$false `
        -WriteControl:$true `
        -WriteStatus:$false
}

$payload = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    Ok = [bool]$result.Ok
    RunMode = [string]$config.RunMode
    RunRoot = $resolvedRunRoot
    Action = $Action
    State = [string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue '')
    Result = [string](Get-ConfigValue -Object $result -Name 'Result' -DefaultValue '')
    Message = [string](Get-ConfigValue -Object $result -Name 'Message' -DefaultValue '')
    RequestId = [string](Get-ConfigValue -Object $result -Name 'RequestId' -DefaultValue '')
    ReasonCodes = @(Get-ConfigValue -Object $result -Name 'ReasonCodes' -DefaultValue @())
    ControlPath = [string]$statePaths.ControlPath
    ControlPendingAction = [string](Get-ConfigValue -Object $controlDocument -Name 'Action' -DefaultValue '')
    ControlPendingRequestId = [string](Get-ConfigValue -Object $controlDocument -Name 'RequestId' -DefaultValue '')
    ControlRequestedAt = [string](Get-ConfigValue -Object $controlDocument -Name 'RequestedAt' -DefaultValue '')
    LastHandledRequestId = [string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledRequestId' -DefaultValue '')
    LastHandledAction = [string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledAction' -DefaultValue '')
    LastHandledResult = [string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledResult' -DefaultValue '')
    LastHandledAt = [string](Get-ConfigValue -Object $controlDocument -Name 'LastHandledAt' -DefaultValue '')
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 10
    return
}

$payload
