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

function Get-FullPath {
    param([Parameter(Mandatory)][string]$PathValue)

    return [System.IO.Path]::GetFullPath($PathValue)
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

function Test-PathEqualsOrIsDescendant {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BasePath
    )

    $resolvedPath = Get-FullPath -PathValue $Path
    $resolvedBasePath = (Get-FullPath -PathValue $BasePath).TrimEnd('\')
    if ($resolvedPath.Equals($resolvedBasePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $resolvedPath.StartsWith(($resolvedBasePath + '\'), [System.StringComparison]::OrdinalIgnoreCase)
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedBaseConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$powershellPath = Resolve-PowerShellExecutable
$payload = & $powershellPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Write-PairExternalizedRelayConfigs.ps1') `
    -BaseConfigPath $resolvedBaseConfigPath `
    -PairId pair01 `
    -BootstrapBindingProfile `
    -AsJson | ConvertFrom-Json

Assert-True (@($payload.GeneratedConfigs).Count -eq 1) 'Expected exactly one generated config for pair01.'
$generated = @($payload.GeneratedConfigs | Select-Object -First 1)[0]
Assert-True ($null -ne $generated) 'Expected one generated externalized config.'
Assert-True ([bool]$generated.BootstrapBindingProfile) 'BootstrapBindingProfile flag should flow into pair-scoped writer results.'

$automationRoot = Get-FullPath -PathValue $root
$workRepoRoot = Get-FullPath -PathValue ([string]$generated.WorkRepoRoot)
$outputConfigPath = Get-FullPath -PathValue ([string]$generated.OutputConfigPath)
Assert-True (-not (Test-PathEqualsOrIsDescendant -Path $workRepoRoot -BasePath $automationRoot)) 'WorkRepoRoot itself must be outside automation repo.'
Assert-True (-not (Test-PathEqualsOrIsDescendant -Path $outputConfigPath -BasePath $automationRoot)) 'Generated config must be outside automation repo.'
Assert-True (Test-PathEqualsOrIsDescendant -Path $outputConfigPath -BasePath $workRepoRoot) 'Generated config must live inside WorkRepoRoot.'

$config = Import-PowerShellDataFile -Path $outputConfigPath
$targetIds = @($config.Targets | ForEach-Object { [string]$_.Id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
Assert-True ($targetIds -contains 'target01') 'Generated config should include pair01 top target.'
Assert-True ($targetIds -contains 'target05') 'Generated config should include pair01 bottom target.'
$pathsToCheck = @(
    [string]$config.InboxRoot
    [string]$config.ProcessedRoot
    [string]$config.FailedRoot
    [string]$config.IgnoredRoot
    [string]$config.RetryPendingRoot
    [string]$config.RuntimeRoot
    [string]$config.LogsRoot
    [string]$config.BindingProfilePath
    [string]$config.RuntimeMapPath
    [string]$config.RouterStatePath
    [string]$config.RouterLogPath
    [string]$config.PairActivation.StatePath
    [string]$config.PairTest.VisibleWorker.QueueRoot
    [string]$config.PairTest.VisibleWorker.StatusRoot
    [string]$config.PairTest.VisibleWorker.LogRoot
    [string]$config.PairTest.RunRootBase
    [string]$config.TargetAutoloop.RunRootBase
    [string]$config.TargetAutoloop.StatusRoot
    [string]$config.TargetAutoloop.QueueRoot
)

foreach ($target in @($config.Targets)) {
    $pathsToCheck += [string]$target.Folder
}

foreach ($path in @($pathsToCheck)) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($path)) 'Generated config path should not be empty.'
    Assert-True (-not (Test-PathEqualsOrIsDescendant -Path $path -BasePath $automationRoot)) ("Generated path must be outside automation repo: {0}" -f $path)
    Assert-True (Test-PathEqualsOrIsDescendant -Path $path -BasePath $workRepoRoot) ("Generated path must stay inside WorkRepoRoot: {0}" -f $path)
}

Assert-True (Test-Path -LiteralPath ([string]$config.BindingProfilePath) -PathType Leaf) 'Bootstrapped binding profile copy should exist for generated pair config.'

Write-Host ('pair externalized config roots ok: ' + $outputConfigPath)
