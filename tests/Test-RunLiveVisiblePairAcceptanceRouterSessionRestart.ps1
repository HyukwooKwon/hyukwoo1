[CmdletBinding()]
param()

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

function Load-FunctionText {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Names
    )

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ('parse failed for ' + $ScriptPath)
    }

    $functions = @{}
    foreach ($name in $Names) {
        $match = @(
            $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $name
                }, $true) | Select-Object -First 1
        )
        if (@($match).Count -ne 1) {
            throw ('function not found: ' + $name)
        }
        $functions[$name] = $match[0].Extent.Text
    }

    return $functions
}

function ConvertFrom-RelayJsonText {
    param([Parameter(Mandatory)][string]$Json)
    return ($Json | ConvertFrom-Json)
}

function Get-ConfigValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }
        return $DefaultValue
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }
    return $DefaultValue
}

function Write-Json {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
}

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'pwsh')) {
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

    throw 'pwsh (PowerShell 7+)를 찾지 못했습니다.'
}

function Start-MutexHolderProcess {
    param(
        [Parameter(Mandatory)][string]$MutexName,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ReadyPath,
        [Parameter(Mandatory)][string]$StopPath,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$StderrPath
    )

    @'
param(
    [Parameter(Mandatory)][string]$MutexName,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$StopPath
)

$ErrorActionPreference = 'Stop'
$mutex = [System.Threading.Mutex]::new($false, $MutexName)
$acquired = $false

try {
    $acquired = $mutex.WaitOne(0, $false)
    if (-not $acquired) {
        throw ('failed to acquire mutex: ' + $MutexName)
    }

    [System.IO.File]::WriteAllText($ReadyPath, 'ready', [System.Text.UTF8Encoding]::new($false))
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $StopPath -PathType Leaf)) {
        Start-Sleep -Milliseconds 100
    }
}
finally {
    if ($acquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
'@ | Set-Content -LiteralPath $ScriptPath -Encoding UTF8

    $powershellPath = Resolve-PowerShellExecutable
    $process = Start-Process `
        -FilePath $powershellPath `
        -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $ScriptPath,
            '-MutexName', $MutexName,
            '-ReadyPath', $ReadyPath,
            '-StopPath', $StopPath
        ) `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ReadyPath -PathType Leaf) {
            return $process
        }
        if ($process.HasExited) {
            $stderr = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) { Get-Content -LiteralPath $StderrPath -Raw -Encoding UTF8 } else { '' }
            throw ('mutex holder exited before ready. stderr=' + $stderr)
        }
        Start-Sleep -Milliseconds 100
    }

    throw 'mutex holder did not become ready.'
}

function Stop-MutexHolderProcess {
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][string]$StopPath
    )

    [System.IO.File]::WriteAllText($StopPath, 'stop', [System.Text.UTF8Encoding]::new($false))
    if (-not $Process.WaitForExit(5000)) {
        $Process.Kill()
        $Process.WaitForExit(5000) | Out-Null
    }
}

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1'
$functions = Load-FunctionText -ScriptPath $scriptPath -Names @(
    'Test-NonEmptyString',
    'Read-JsonObject',
    'Test-MutexHeld',
    'Get-RuntimeMapLauncherSessionIds',
    'Get-RouterRuntimeSessionRestartDecision'
)

foreach ($name in @('Test-NonEmptyString', 'Read-JsonObject', 'Test-MutexHeld', 'Get-RuntimeMapLauncherSessionIds', 'Get-RouterRuntimeSessionRestartDecision')) {
    Invoke-Expression $functions[$name]
}

$testRoot = Join-Path $root '_tmp\Test-RunLiveVisiblePairAcceptanceRouterSessionRestart'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$runtimeMapPath = Join-Path $testRoot 'target-runtime.json'
$routerStatePath = Join-Path $testRoot 'router-state.json'

Write-Json -Path $runtimeMapPath -Value @(
    @{ TargetId = 'target01'; LauncherSessionId = 'runtime-session-current' }
    @{ TargetId = 'target05'; LauncherSessionId = 'runtime-session-current' }
)
Write-Json -Path $routerStatePath -Value @{
    Status = 'running'
    LauncherSessionId = 'router-session-stale'
}

$mutexName = ('Global\RelayAcceptanceRouterSessionRestart_' + [guid]::NewGuid().ToString('N'))
$holderScriptPath = Join-Path $testRoot 'Hold-Mutex.ps1'
$holderReadyPath = Join-Path $testRoot 'holder.ready'
$holderStopPath = Join-Path $testRoot 'holder.stop'
$holderStdoutPath = Join-Path $testRoot 'holder.stdout.log'
$holderStderrPath = Join-Path $testRoot 'holder.stderr.log'
$holderProcess = $null
try {
    $holderProcess = Start-MutexHolderProcess `
        -MutexName $mutexName `
        -ScriptPath $holderScriptPath `
        -ReadyPath $holderReadyPath `
        -StopPath $holderStopPath `
        -StdoutPath $holderStdoutPath `
        -StderrPath $holderStderrPath

    $mismatch = Get-RouterRuntimeSessionRestartDecision `
        -RouterMutexName $mutexName `
        -RouterStatePath $routerStatePath `
        -RuntimeMapPath $runtimeMapPath
    Assert-True ([bool]$mismatch.RestartRequired) 'running router with stale launcher session should require restart.'
    Assert-True ([string]$mismatch.RouterLauncherSessionId -eq 'router-session-stale') 'decision should expose router session id.'
    Assert-True ([string]$mismatch.RuntimeLauncherSessionId -eq 'runtime-session-current') 'decision should expose runtime session id.'
    Assert-True ([string]$mismatch.Reason -like '*launcher-session-mismatch*') 'decision reason should be stable.'

    Write-Json -Path $routerStatePath -Value @{
        Status = 'running'
        LauncherSessionId = 'runtime-session-current'
    }
    $match = Get-RouterRuntimeSessionRestartDecision `
        -RouterMutexName $mutexName `
        -RouterStatePath $routerStatePath `
        -RuntimeMapPath $runtimeMapPath
    Assert-True (-not [bool]$match.RestartRequired) 'matching launcher sessions should not require restart.'
    Assert-True ([string]$match.Reason -eq 'session-match') 'matching launcher session should report session-match.'

    Write-Json -Path $runtimeMapPath -Value @(
        @{ TargetId = 'target01'; LauncherSessionId = 'runtime-a' }
        @{ TargetId = 'target05'; LauncherSessionId = 'runtime-b' }
    )
    $multiRuntime = Get-RouterRuntimeSessionRestartDecision `
        -RouterMutexName $mutexName `
        -RouterStatePath $routerStatePath `
        -RuntimeMapPath $runtimeMapPath
    Assert-True (-not [bool]$multiRuntime.RestartRequired) 'multi-session runtime map should not be repaired by router restart.'
    Assert-True ([string]$multiRuntime.Reason -eq 'runtime-session-count=2') 'multi-session runtime map should report the count.'
}
finally {
    if ($null -ne $holderProcess) {
        Stop-MutexHolderProcess -Process $holderProcess -StopPath $holderStopPath
    }
}

$notRunningMutexName = ('Global\RelayAcceptanceRouterSessionRestart_' + [guid]::NewGuid().ToString('N'))
$notRunning = Get-RouterRuntimeSessionRestartDecision `
    -RouterMutexName $notRunningMutexName `
    -RouterStatePath $routerStatePath `
    -RuntimeMapPath $runtimeMapPath
Assert-True (-not [bool]$notRunning.RestartRequired) 'router-not-running should be handled by the normal start branch.'
Assert-True ([string]$notRunning.Reason -eq 'router-not-running') 'router-not-running should be explicit.'

Write-Host 'run-live-visible-pair-acceptance router session restart decision ok'
