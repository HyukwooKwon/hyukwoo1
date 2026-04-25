[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DiagnosticOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\config\settings.psd1'
}

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-EnvironmentFlagValue {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($scope in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [string]$value
        }
    }

    return ''
}

function ConvertTo-EnvironmentToken {
    param([Parameter(Mandatory)][string]$Value)

    $normalized = ([string]$Value).ToUpperInvariant() -replace '[^A-Z0-9]+', '_'
    $normalized = $normalized.Trim('_')
    if (-not (Test-NonEmptyString $normalized)) {
        return 'WRAPPER_MANAGED'
    }

    return $normalized
}

function Get-WrapperManagedLanePolicy {
    param([Parameter(Mandatory)][string]$ResolvedConfigPath)

    $configDoc = Import-PowerShellDataFile -Path $ResolvedConfigPath
    $launcherWrapperPath = if ($configDoc.ContainsKey('LauncherWrapperPath')) { [string]$configDoc.LauncherWrapperPath } else { '' }
    if (-not (Test-NonEmptyString $launcherWrapperPath)) {
        return [pscustomobject]@{
            WrapperManaged            = $false
            LaneName                  = if ($configDoc.ContainsKey('LaneName')) { [string]$configDoc.LaneName } else { '' }
            LauncherWrapperPath       = ''
            DirectStartAllowed        = $true
            DirectStartAllowEnvVar    = ''
        }
    }

    $laneName = if ($configDoc.ContainsKey('LaneName')) { [string]$configDoc.LaneName } else { '' }
    $windowLaunch = if ($configDoc.ContainsKey('WindowLaunch')) { $configDoc.WindowLaunch } else { @{} }
    $laneToken = ConvertTo-EnvironmentToken -Value $laneName
    $directStartAllowEnvVar = if ($windowLaunch.ContainsKey('DirectStartAllowEnvVar')) { [string]$windowLaunch.DirectStartAllowEnvVar } else { ('RELAY_ALLOW_DIRECT_START_TARGETS_' + $laneToken) }

    return [pscustomobject]@{
        WrapperManaged         = $true
        LaneName               = $laneName
        LauncherWrapperPath    = $launcherWrapperPath
        DirectStartAllowed     = [bool]$(if ($windowLaunch.ContainsKey('DirectStartAllowed')) { $windowLaunch.DirectStartAllowed } else { $false })
        DirectStartAllowEnvVar = $directStartAllowEnvVar
    }
}

function Assert-WrapperManagedLaneDirectLaunchAllowed {
    param([Parameter(Mandatory)]$Policy)

    if (-not [bool]$Policy.WrapperManaged) {
        return
    }

    if (-not [bool]$Policy.DirectStartAllowed) {
        throw ("Direct Ensure-Targets is blocked for wrapper-managed lanes. Use the UI '8창 열기' action or LauncherWrapperPath instead: {0}. This lane only allows attach-only reuse." -f [string]$Policy.LauncherWrapperPath)
    }

    $allowFlagName = [string]$Policy.DirectStartAllowEnvVar
    $allowFlagValue = Get-EnvironmentFlagValue -Name $allowFlagName
    if ($allowFlagValue -eq '1') {
        return
    }

    throw ("Direct Ensure-Targets requires wrapper-managed maintenance unlock. Use the UI '8창 열기' action or LauncherWrapperPath instead: {0}. Set {1}=1 only when the lane explicitly allows direct launch." -f [string]$Policy.LauncherWrapperPath, $allowFlagName)
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$wrapperManagedLanePolicy = Get-WrapperManagedLanePolicy -ResolvedConfigPath $resolvedConfigPath
Assert-WrapperManagedLaneDirectLaunchAllowed -Policy $wrapperManagedLanePolicy

if ($DiagnosticOnly) {
    & (Join-Path $PSScriptRoot 'Attach-Targets.ps1') -ConfigPath $resolvedConfigPath -DiagnosticOnly
    return
}

try {
    & (Join-Path $PSScriptRoot 'Attach-Targets.ps1') -ConfigPath $resolvedConfigPath
}
catch {
    Write-Host ("attach failed, launching new targets without cleanup: {0}" -f $_.Exception.Message)
    & (Join-Path $PSScriptRoot 'Start-Targets.ps1') -ConfigPath $resolvedConfigPath
}
