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
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Allow native stderr to pass through without converting expected timeout
        # diagnostics into terminating NativeCommandError records in this test.
        $ErrorActionPreference = 'Continue'
        $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $ScriptPath @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
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

function Invoke-PowerShellCommand {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $powershellPath = Resolve-PowerShellExecutable
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Timeout-path stderr is part of the contract under test, not a harness failure.
        $ErrorActionPreference = 'Continue'
        $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $ScriptPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Raw      = (($result | Out-String).Trim())
    }
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return $Value.Replace("'", "''")
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase

$successRunRoot = Join-Path $pairRunRootBase ('run_contract_exec_process_result_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $successRunRoot `
    -IncludePairId pair01 | Out-Null

$successWorkRepoRoot = Join-Path $successRunRoot 'pair-workrepo-target01'
New-Item -ItemType Directory -Path $successWorkRepoRoot -Force | Out-Null
$successScriptPath = Join-Path $successRunRoot 'fake-codex-process-success.ps1'
$successScript = @'
param()

[void][Console]::In.ReadToEnd()
Write-Output 'stdout from fake codex'
Write-Error 'stderr from fake codex'

$codexWorkingDirectory = ''
$outputPath = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-C' -and ($i + 1) -lt $args.Count) {
        $codexWorkingDirectory = [string]$args[$i + 1]
        $i++
        continue
    }

    if ($args[$i] -eq '-o' -and ($i + 1) -lt $args.Count) {
        $outputPath = [string]$args[$i + 1]
        $i++
        continue
    }
}

$requestPath = if (-not [string]::IsNullOrWhiteSpace($outputPath)) {
    Join-Path (Split-Path -Parent $outputPath) 'request.json'
}
else {
    Join-Path (Get-Location) 'request.json'
}

$request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$summaryPath = if ([string]::IsNullOrWhiteSpace([string]$request.SummaryPath)) { Join-Path (Get-Location) 'summary.txt' } else { [string]$request.SummaryPath }
$reviewFolderPath = if ([string]::IsNullOrWhiteSpace([string]$request.ReviewFolderPath)) { Join-Path (Get-Location) 'reviewfile' } else { [string]$request.ReviewFolderPath }
if (-not (Test-Path -LiteralPath $reviewFolderPath)) {
    New-Item -ItemType Directory -Path $reviewFolderPath -Force | Out-Null
}
$summaryParent = Split-Path -Parent $summaryPath
if (-not [string]::IsNullOrWhiteSpace($summaryParent) -and -not (Test-Path -LiteralPath $summaryParent)) {
    New-Item -ItemType Directory -Path $summaryParent -Force | Out-Null
}
[System.IO.File]::WriteAllText($summaryPath, 'fresh summary from process contract', [System.Text.UTF8Encoding]::new($false))
$notePath = Join-Path $reviewFolderPath 'process-contract-note.txt'
[System.IO.File]::WriteAllText($notePath, 'zip payload', [System.Text.UTF8Encoding]::new($false))
$zipPath = Join-Path $reviewFolderPath 'process-contract-review.zip'
Compress-Archive -LiteralPath $notePath -DestinationPath $zipPath -Force
$probePath = [string]$request.WorkdirProbePath
if (-not [string]::IsNullOrWhiteSpace($probePath)) {
    $probeParent = Split-Path -Parent $probePath
    if ($probeParent -and -not (Test-Path -LiteralPath $probeParent)) {
        New-Item -ItemType Directory -Path $probeParent -Force | Out-Null
    }

    [pscustomobject]@{
        ProcessWorkingDirectory = (Get-Location).Path
        CodexChangeDirectory = $codexWorkingDirectory
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $probePath -Encoding UTF8
}
'@
[System.IO.File]::WriteAllText($successScriptPath, $successScript, (New-Utf8NoBomEncoding))

$successConfigPath = Join-Path $successRunRoot 'settings.headless-process-success.psd1'
$successConfigRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$successConfigRaw = $successConfigRaw.Replace("            Enabled                   = `$false", "            Enabled                   = `$true")
$successConfigRaw = $successConfigRaw.Replace("            CodexExecutable           = 'codex'", ("            CodexExecutable           = '" + (ConvertTo-PowerShellSingleQuotedLiteral -Value $successScriptPath) + "'"))
$successConfigRaw = $successConfigRaw.Replace("            Arguments                 = @('exec', '--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox')", "            Arguments                 = @()")
[System.IO.File]::WriteAllText($successConfigPath, $successConfigRaw, (New-Utf8NoBomEncoding))

$successRequestPath = Join-Path $successRunRoot 'pair01\target01\request.json'
$successRequest = Get-Content -LiteralPath $successRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$successRequest.WorkRepoRoot = $successWorkRepoRoot
$successProbePath = Join-Path $successRunRoot 'pair01\target01\workdir-probe.json'
$successRequest | Add-Member -NotePropertyName WorkdirProbePath -NotePropertyValue $successProbePath -Force
$successRequest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $successRequestPath -Encoding UTF8

$successExec = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $successConfigPath,
    '-RunRoot', $successRunRoot,
    '-TargetId', 'target01',
    '-AsJson'
)

$successTargetRoot = Join-Path $successRunRoot 'pair01\target01'
$successResultPath = Join-Path $successTargetRoot 'result.json'
$successDonePath = Join-Path $successTargetRoot 'done.json'
$successResult = Get-Content -LiteralPath $successResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$successProbe = Get-Content -LiteralPath $successProbePath -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-True ($successExec.ExitCode -eq 0) 'successful fake process should complete cleanly.'
Assert-True ([bool]$successExec.Json.ContractArtifactsReady) 'successful fake process should produce ready contract artifacts.'
Assert-True (-not [bool]$successExec.Json.TimedOut) 'successful fake process should not time out.'
Assert-True (-not [bool]$successExec.Json.Killed) 'successful fake process should not be marked killed.'
Assert-True ([string]$successExec.Json.KillReason -eq '') 'successful fake process should not report a kill reason.'
Assert-True ([int]$successExec.Json.DurationMs -ge 0) 'successful fake process should report DurationMs.'
Assert-True ([int]$successExec.Json.StdOutChars -gt 0) 'successful fake process should report captured stdout.'
Assert-True ([int]$successExec.Json.StdErrChars -gt 0) 'successful fake process should report captured stderr.'
Assert-True ((Test-Path -LiteralPath $successDonePath -PathType Leaf)) 'successful fake process should write done.json.'
Assert-True ([int]$successResult.DurationMs -ge 0) 'result.json should include DurationMs.'
Assert-True ([int]$successResult.StdOutChars -gt 0) 'result.json should include stdout character count.'
Assert-True ([int]$successResult.StdErrChars -gt 0) 'result.json should include stderr character count.'
Assert-True (-not [bool]$successResult.TimedOut) 'result.json should report TimedOut=false on success.'
Assert-True (-not [bool]$successResult.Killed) 'result.json should report Killed=false on success.'
Assert-True ([string]$successExec.Json.WorkRepoRoot -eq $successWorkRepoRoot) 'status should echo WorkRepoRoot from request.'
Assert-True ([string]$successExec.Json.EffectiveWorkingDirectory -eq $successWorkRepoRoot) 'executor should promote WorkRepoRoot to EffectiveWorkingDirectory.'
Assert-True ([string]$successProbe.ProcessWorkingDirectory -eq $successWorkRepoRoot) 'fake codex process should start in WorkRepoRoot.'
Assert-True ([string]$successProbe.CodexChangeDirectory -eq $successWorkRepoRoot) 'codex -C should target WorkRepoRoot.'

$timeoutRunRoot = Join-Path $pairRunRootBase ('run_contract_exec_process_timeout_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $timeoutRunRoot `
    -IncludePairId pair01 | Out-Null

$timeoutScriptPath = Join-Path $timeoutRunRoot 'fake-codex-process-timeout.ps1'
$timeoutScript = @'
param()

[void][Console]::In.ReadToEnd()
Write-Output 'stdout before timeout'
Write-Error 'stderr before timeout'
Start-Sleep -Milliseconds 1800
'@
[System.IO.File]::WriteAllText($timeoutScriptPath, $timeoutScript, (New-Utf8NoBomEncoding))

$timeoutConfigPath = Join-Path $timeoutRunRoot 'settings.headless-process-timeout.psd1'
$timeoutConfigRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$timeoutConfigRaw = $timeoutConfigRaw.Replace("            Enabled                   = `$false", "            Enabled                   = `$true")
$timeoutConfigRaw = $timeoutConfigRaw.Replace("            CodexExecutable           = 'codex'", ("            CodexExecutable           = '" + (ConvertTo-PowerShellSingleQuotedLiteral -Value $timeoutScriptPath) + "'"))
$timeoutConfigRaw = $timeoutConfigRaw.Replace("            Arguments                 = @('exec', '--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox')", "            Arguments                 = @()")
[System.IO.File]::WriteAllText($timeoutConfigPath, $timeoutConfigRaw, (New-Utf8NoBomEncoding))

$timeoutExec = Invoke-PowerShellCommand -ScriptPath (Join-Path $root 'invoke-codex-exec-turn.ps1') -Arguments @(
    '-ConfigPath', $timeoutConfigPath,
    '-RunRoot', $timeoutRunRoot,
    '-TargetId', 'target01',
    '-TimeoutSec', '1',
    '-AsJson'
)

$timeoutTargetRoot = Join-Path $timeoutRunRoot 'pair01\target01'
$timeoutResultPath = Join-Path $timeoutTargetRoot 'result.json'
$timeoutErrorPath = Join-Path $timeoutTargetRoot 'error.json'
$timeoutResult = Get-Content -LiteralPath $timeoutResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$timeoutError = Get-Content -LiteralPath $timeoutErrorPath -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-True ($timeoutExec.ExitCode -ne 0) 'timed out fake process should fail the wrapper script.'
Assert-True ((Test-Path -LiteralPath $timeoutResultPath -PathType Leaf)) 'timed out fake process should still write result.json.'
Assert-True ((Test-Path -LiteralPath $timeoutErrorPath -PathType Leaf)) 'timed out fake process should write error.json.'
Assert-True ([bool]$timeoutResult.TimedOut) 'result.json should report TimedOut=true on timeout.'
Assert-True ([bool]$timeoutResult.Killed) 'result.json should report Killed=true on timeout.'
Assert-True ([string]$timeoutResult.KillReason -eq 'timeout') 'result.json should report timeout kill reason.'
Assert-True ([string]$timeoutResult.ContractArtifactsReadyReason -eq 'timed-out') 'result.json should explain timeout readiness failure.'
Assert-True ([int]$timeoutResult.DurationMs -ge 1000) 'timeout result should report elapsed duration.'
Assert-True ([int]$timeoutResult.StdOutChars -gt 0) 'timeout result should retain stdout diagnostics.'
Assert-True ([int]$timeoutResult.StdErrChars -gt 0) 'timeout result should retain stderr diagnostics.'
Assert-True ([bool]$timeoutError.TimedOut) 'error.json should report TimedOut=true on timeout.'
Assert-True ([bool]$timeoutError.Killed) 'error.json should report Killed=true on timeout.'
Assert-True ([string]$timeoutError.KillReason -eq 'timeout') 'error.json should report timeout kill reason.'
Assert-True ([int]$timeoutError.DurationMs -ge 1000) 'error.json should report elapsed duration on timeout.'

Write-Host ('invoke-codex-exec-turn process invocation contract ok: successRunRoot=' + $successRunRoot + ' timeoutRunRoot=' + $timeoutRunRoot)
