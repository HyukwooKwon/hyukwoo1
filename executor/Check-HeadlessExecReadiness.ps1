[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$TargetId,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$issues = New-Object System.Collections.Generic.List[string]
$targetRows = @()

$commandInfo = Get-Command -Name ([string]$pairTest.HeadlessExec.CodexExecutable) -ErrorAction SilentlyContinue
if ($null -eq $commandInfo) {
    $issues.Add('codex-executable-missing')
}

$execHelpOk = $false
$execHelpExitCode = -1
$execHelpError = ''
if ($null -ne $commandInfo) {
    try {
        & $commandInfo.Source 'exec' '--help' *> $null
        $execHelpExitCode = if ($LASTEXITCODE -is [int]) { [int]$LASTEXITCODE } else { 0 }
        $execHelpOk = ($execHelpExitCode -eq 0)
    }
    catch {
        $execHelpError = $_.Exception.Message
        $execHelpExitCode = if ($LASTEXITCODE -is [int]) { [int]$LASTEXITCODE } else { -1 }
    }
}

if (-not [bool]$pairTest.HeadlessExec.Enabled) {
    $issues.Add('headless-disabled')
}

if (-not $execHelpOk) {
    $issues.Add('codex-exec-help-failed')
}

$manifestPath = ''
$resolvedRunRoot = ''
$manifest = $null
if (Test-NonEmptyString $RunRoot) {
    $resolvedRunRoot = Resolve-PairRunRootPath -Root $root -RunRoot $RunRoot -PairTest $pairTest
    $manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $issues.Add('manifest-missing')
    }
    else {
        try {
            $manifest = Read-JsonObject -Path $manifestPath
        }
        catch {
            $issues.Add('manifest-parse-failed')
        }
    }
}

if ($null -ne $manifest) {
    $targets = @($manifest.Targets)
    if (Test-NonEmptyString $TargetId) {
        $targets = @($targets | Where-Object { [string]$_.TargetId -eq [string]$TargetId })
        if ($targets.Count -eq 0) {
            $issues.Add('target-not-found')
        }
    }

    foreach ($item in $targets | Sort-Object TargetId) {
        $targetFolder = [string]$item.TargetFolder
        $requestPath = if (Test-NonEmptyString ([string]$item.RequestPath)) {
            [string]$item.RequestPath
        }
        else {
            Join-Path $targetFolder ([string]$pairTest.HeadlessExec.RequestFileName)
        }
        $messagePath = [string]$item.MessagePath
        $instructionPath = Join-Path $targetFolder 'instructions.txt'
        $reviewPath = Join-Path $targetFolder ([string]$pairTest.ReviewFolderName)

        $row = [pscustomobject]@{
            TargetId             = [string]$item.TargetId
            PairId               = [string]$item.PairId
            TargetFolderExists   = [bool](Test-Path -LiteralPath $targetFolder)
            MessagePathExists    = [bool](Test-Path -LiteralPath $messagePath)
            InstructionPathExists = [bool](Test-Path -LiteralPath $instructionPath)
            ReviewFolderExists   = [bool](Test-Path -LiteralPath $reviewPath)
            RequestPathExists    = [bool](Test-Path -LiteralPath $requestPath)
            RequestPath          = $requestPath
        }

        if (-not $row.TargetFolderExists) { $issues.Add(('target-folder-missing:{0}' -f [string]$item.TargetId)) }
        if (-not $row.RequestPathExists) { $issues.Add(('request-missing:{0}' -f [string]$item.TargetId)) }
        if (-not $row.MessagePathExists -and -not $row.InstructionPathExists) { $issues.Add(('prompt-source-missing:{0}' -f [string]$item.TargetId)) }
        $targetRows += $row
    }
}

$status = [pscustomobject]@{
    ConfigPath          = $resolvedConfigPath
    RunRoot             = $resolvedRunRoot
    ManifestPath        = $manifestPath
    HeadlessEnabled     = [bool]$pairTest.HeadlessExec.Enabled
    CodexExecutable     = [string]$pairTest.HeadlessExec.CodexExecutable
    CodexResolvedPath   = if ($null -ne $commandInfo) { [string]$commandInfo.Source } else { '' }
    CodexExecHelpOk     = $execHelpOk
    CodexExecHelpExitCode = $execHelpExitCode
    CodexExecHelpError  = $execHelpError
    RequestFileName     = [string]$pairTest.HeadlessExec.RequestFileName
    DoneFileName        = [string]$pairTest.HeadlessExec.DoneFileName
    ErrorFileName       = [string]$pairTest.HeadlessExec.ErrorFileName
    PromptFileName      = [string]$pairTest.HeadlessExec.PromptFileName
    Issues              = @($issues)
    Targets             = @($targetRows)
}

if ($AsJson) {
    $status | ConvertTo-Json -Depth 8
}
else {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Headless Exec Readiness')
    $lines.Add(('Config: {0}' -f $status.ConfigPath))
    if (Test-NonEmptyString $status.RunRoot) {
        $lines.Add(('RunRoot: {0}' -f $status.RunRoot))
    }
    $lines.Add(('Headless: enabled={0} codex={1} resolved={2}' -f $status.HeadlessEnabled, $status.CodexExecutable, $status.CodexResolvedPath))
    $lines.Add(('Codex exec help: ok={0} exitCode={1}' -f $status.CodexExecHelpOk, $status.CodexExecHelpExitCode))
    if (Test-NonEmptyString $status.CodexExecHelpError) {
        $lines.Add(('Codex exec help error: {0}' -f $status.CodexExecHelpError))
    }
    $lines.Add(('Contract: request={0} done={1} error={2} prompt={3}' -f $status.RequestFileName, $status.DoneFileName, $status.ErrorFileName, $status.PromptFileName))
    $lines.Add(('Issues: {0}' -f $(if ($status.Issues.Count -gt 0) { $status.Issues -join ', ' } else { '(none)' })))
    if ($status.Targets.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Targets')
        $lines.Add((($status.Targets | Format-Table TargetId, PairId, TargetFolderExists, RequestPathExists, MessagePathExists, InstructionPathExists, ReviewFolderExists -AutoSize | Out-String).TrimEnd()))
    }
    $lines
}

if ($status.Issues.Count -gt 0) {
    $host.SetShouldExit(1)
    return
}

$host.SetShouldExit(0)
return
