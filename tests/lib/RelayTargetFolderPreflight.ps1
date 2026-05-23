Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-RelayTargetFolderNonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-RelayTargetFolderNormalizedPath {
    param([string]$Path)

    if (-not (Test-RelayTargetFolderNonEmptyString $Path)) {
        return ''
    }

    try {
        return ([System.IO.Path]::GetFullPath($Path).TrimEnd('\')).ToLowerInvariant()
    }
    catch {
        return (($Path.TrimEnd('\')).ToLowerInvariant())
    }
}

function Test-RelayTargetFolderPathMatch {
    param(
        [string]$Left,
        [string]$Right
    )

    if (-not (Test-RelayTargetFolderNonEmptyString $Left) -or -not (Test-RelayTargetFolderNonEmptyString $Right)) {
        return $false
    }

    return ((Get-RelayTargetFolderNormalizedPath -Path $Left) -eq (Get-RelayTargetFolderNormalizedPath -Path $Right))
}

function Get-RelayTargetFolderPreflight {
    param(
        [string]$ConfiguredFolder,
        [string]$InboxRoot,
        [Parameter(Mandatory)][string]$TargetKey
    )

    $expectedFolder = if (Test-RelayTargetFolderNonEmptyString $InboxRoot) { Join-Path $InboxRoot $TargetKey } else { '' }

    return [pscustomobject]@{
        ConfiguredFolder       = [string]$ConfiguredFolder
        ConfiguredFolderExists = if (Test-RelayTargetFolderNonEmptyString $ConfiguredFolder) { [bool](Test-Path -LiteralPath $ConfiguredFolder) } else { $false }
        InboxRoot              = [string]$InboxRoot
        ExpectedFolder         = [string]$expectedFolder
        ExpectedFolderExists   = if (Test-RelayTargetFolderNonEmptyString $expectedFolder) { [bool](Test-Path -LiteralPath $expectedFolder) } else { $false }
    }
}

function Assert-RelayTargetFolderReady {
    param(
        [string]$ConfiguredFolder,
        [string]$InboxRoot,
        [Parameter(Mandatory)][string]$TargetKey
    )

    $preflight = Get-RelayTargetFolderPreflight -ConfiguredFolder $ConfiguredFolder -InboxRoot $InboxRoot -TargetKey $TargetKey

    if (-not (Test-RelayTargetFolderNonEmptyString ([string]$preflight.ConfiguredFolder))) {
        $message = "target relay folder missing in config: target=$TargetKey"
        if (Test-RelayTargetFolderNonEmptyString ([string]$preflight.ExpectedFolder)) {
            $message += " expectedFolder=$([string]$preflight.ExpectedFolder)"
        }
        throw $message
    }

    if (
        (Test-RelayTargetFolderNonEmptyString ([string]$preflight.ExpectedFolder)) -and
        -not (Test-RelayTargetFolderPathMatch -Left ([string]$preflight.ConfiguredFolder) -Right ([string]$preflight.ExpectedFolder))
    ) {
        throw "target relay folder mismatch: target=$TargetKey configFolder=$([string]$preflight.ConfiguredFolder) expectedFolder=$([string]$preflight.ExpectedFolder)"
    }

    if (-not [bool]$preflight.ConfiguredFolderExists) {
        $message = "target relay folder missing: target=$TargetKey configFolder=$([string]$preflight.ConfiguredFolder)"
        if (Test-RelayTargetFolderNonEmptyString ([string]$preflight.ExpectedFolder)) {
            $message += " expectedFolder=$([string]$preflight.ExpectedFolder)"
        }
        throw $message
    }

    return $preflight
}

function Get-RelayTargetFolderIssueStateFromMessage {
    param([AllowEmptyString()][string]$Message)

    $normalized = [string]$Message
    if (-not (Test-RelayTargetFolderNonEmptyString $normalized)) {
        return ''
    }

    if ($normalized -match '^target relay folder mismatch:') {
        return 'relay-folder-mismatch'
    }
    if ($normalized -match '^target relay folder missing in config:') {
        return 'relay-folder-config-missing'
    }
    if ($normalized -match '^target relay folder missing:') {
        return 'relay-folder-missing'
    }

    return ''
}
