[CmdletBinding()]
param(
    [string]$CodexCommand = 'codex',
    [string]$PackageName = '@openai/codex',
    [string]$SideBySideRoot,
    [string]$LatestVersionOverride,
    [switch]$SkipNpmView,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)
    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Invoke-TextCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    try {
        $output = & $FilePath @ArgumentList 2>&1
        return [pscustomobject]@{
            Success = ($LASTEXITCODE -eq 0)
            ExitCode = [int]($LASTEXITCODE ?? 0)
            Text = [string]($output -join [Environment]::NewLine)
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            ExitCode = -1
            Text = [string]$_.Exception.Message
        }
    }
}

function ConvertTo-VersionText {
    param([AllowNull()][string]$Text)

    $value = [string]($Text ?? '')
    $match = [regex]::Match($value, '\d+(?:\.\d+){1,3}')
    if ($match.Success) {
        return $match.Value
    }
    return ''
}

function Get-PackageVersionFromJson {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    try {
        $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]($document.version ?? '')
    }
    catch {
        return ''
    }
}

function Get-NpmRoot {
    $result = Invoke-TextCommand -FilePath 'npm' -ArgumentList @('root', '-g')
    if ($result.Success) {
        return ([string]$result.Text).Trim()
    }
    return ''
}

function Get-NpmPrefix {
    $result = Invoke-TextCommand -FilePath 'npm' -ArgumentList @('prefix', '-g')
    if ($result.Success) {
        return ([string]$result.Text).Trim()
    }
    return ''
}

function Get-NpmGlobalVersion {
    param([Parameter(Mandatory)][string]$PackageName)

    $result = Invoke-TextCommand -FilePath 'npm' -ArgumentList @('list', '-g', $PackageName, '--depth=0', '--json')
    if (-not $result.Success -and -not (Test-NonEmptyString $result.Text)) {
        return ''
    }
    try {
        $document = [string]$result.Text | ConvertFrom-Json
        $dependency = $document.dependencies.$PackageName
        if ($null -ne $dependency) {
            return [string]($dependency.version ?? '')
        }
    }
    catch {
        return ConvertTo-VersionText ([string]$result.Text)
    }
    return ''
}

function Get-NpmLatestVersion {
    param([Parameter(Mandatory)][string]$PackageName)

    $result = Invoke-TextCommand -FilePath 'npm' -ArgumentList @('view', $PackageName, 'version')
    if ($result.Success) {
        return ConvertTo-VersionText ([string]$result.Text)
    }
    return ''
}

function Get-CodexCommandSources {
    param([Parameter(Mandatory)][string]$CommandName)

    try {
        return @(
            Get-Command $CommandName -All -ErrorAction Stop |
                ForEach-Object {
                    [pscustomobject]@{
                        Source = [string]$_.Source
                        CommandType = [string]$_.CommandType
                        Definition = [string]$_.Definition
                    }
                }
        )
    }
    catch {
        return @()
    }
}

function Get-WhereCommandSources {
    param([Parameter(Mandatory)][string]$CommandName)

    $result = Invoke-TextCommand -FilePath 'where.exe' -ArgumentList @($CommandName)
    if (-not $result.Success) {
        return @()
    }
    return @(
        [string]$result.Text -split "\r?\n" |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-SideBySideInstalls {
    param([Parameter(Mandatory)][string]$RootPath)

    if (-not (Test-NonEmptyString $RootPath) -or -not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $packageJson = Join-Path $_.FullName 'node_modules\@openai\codex\package.json'
                $version = Get-PackageVersionFromJson -Path $packageJson
                $shimPs1 = Join-Path $_.FullName 'node_modules\.bin\codex.ps1'
                $shimCmd = Join-Path $_.FullName 'node_modules\.bin\codex.cmd'
                [pscustomobject]@{
                    Name = [string]$_.Name
                    Root = [string]$_.FullName
                    Version = $version
                    PowerShellShim = if (Test-Path -LiteralPath $shimPs1 -PathType Leaf) { $shimPs1 } else { '' }
                    CmdShim = if (Test-Path -LiteralPath $shimCmd -PathType Leaf) { $shimCmd } else { '' }
                    Usable = (Test-NonEmptyString $version) -and (Test-Path -LiteralPath $shimPs1 -PathType Leaf)
                }
            } |
            Sort-Object -Property Version, Name
    )
}

function Get-CodexProcesses {
    param([AllowNull()][string]$GlobalPackageRoot)

    $globalRoot = [string]($GlobalPackageRoot ?? '')
    try {
        $processes = @(
            Get-CimInstance Win32_Process -ErrorAction Stop |
                Where-Object {
                    $name = [string]($_.Name ?? '')
                    $commandLine = [string]($_.CommandLine ?? '')
                    $executablePath = [string]($_.ExecutablePath ?? '')
                    $name -ieq 'codex.exe' -or
                    $commandLine -like '*@openai/codex*' -or
                    $commandLine -like '*@openai\codex*' -or
                    $commandLine -like '*codex-win32*' -or
                    $executablePath -like '*codex-win32*'
                } |
                ForEach-Object {
                    $commandLine = [string]($_.CommandLine ?? '')
                    $executablePath = [string]($_.ExecutablePath ?? '')
                    $usesGlobalPackage = $false
                    if (Test-NonEmptyString $globalRoot) {
                        $usesGlobalPackage = (
                            $executablePath.StartsWith($globalRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                            $commandLine.Contains($globalRoot)
                        )
                    }
                    [pscustomobject]@{
                        ProcessId = [int]$_.ProcessId
                        ParentProcessId = [int]$_.ParentProcessId
                        Name = [string]$_.Name
                        ExecutablePath = $executablePath
                        CommandLine = $commandLine
                        UsesGlobalPackage = [bool]$usesGlobalPackage
                    }
                }
        )
        return $processes
    }
    catch {
        return @()
    }
}

function Select-LatestSideBySideInstall {
    param(
        [object[]]$Installs,
        [AllowNull()][string]$LatestVersion
    )

    $usable = @($Installs | Where-Object { [bool]$_.Usable })
    if ($usable.Count -eq 0) {
        return $null
    }
    if (Test-NonEmptyString $LatestVersion) {
        $exact = @($usable | Where-Object { [string]$_.Version -eq [string]$LatestVersion } | Select-Object -Last 1)
        if ($exact.Count -gt 0) {
            return $exact[0]
        }
    }
    return @($usable | Select-Object -Last 1)[0]
}

if (-not (Test-NonEmptyString $SideBySideRoot)) {
    $localAppData = [string]($env:LOCALAPPDATA ?? '')
    if (Test-NonEmptyString $localAppData) {
        $SideBySideRoot = Join-Path $localAppData 'codex-cli-versions'
    }
    else {
        $SideBySideRoot = ''
    }
}

$generatedAt = (Get-Date).ToString('o')
$commandSources = @(Get-CodexCommandSources -CommandName $CodexCommand)
$whereSources = @(Get-WhereCommandSources -CommandName $CodexCommand)
$cliVersionResult = Invoke-TextCommand -FilePath $CodexCommand -ArgumentList @('--version')
$cliReportedVersion = if ($cliVersionResult.Success) { ConvertTo-VersionText ([string]$cliVersionResult.Text) } else { '' }
$npmPrefix = Get-NpmPrefix
$npmRoot = Get-NpmRoot
$globalPackageRoot = if (Test-NonEmptyString $npmRoot) { Join-Path $npmRoot $PackageName } else { '' }
$globalPackageJson = if (Test-NonEmptyString $globalPackageRoot) { Join-Path $globalPackageRoot 'package.json' } else { '' }
$globalPackageJsonVersion = if (Test-NonEmptyString $globalPackageJson) { Get-PackageVersionFromJson -Path $globalPackageJson } else { '' }
$globalInstalledVersion = Get-NpmGlobalVersion -PackageName $PackageName
if (-not (Test-NonEmptyString $globalInstalledVersion)) {
    $globalInstalledVersion = $globalPackageJsonVersion
}
$latestVersion = if (Test-NonEmptyString $LatestVersionOverride) {
    [string]$LatestVersionOverride
}
elseif ($SkipNpmView) {
    ''
}
else {
    Get-NpmLatestVersion -PackageName $PackageName
}
$sideBySideInstalls = @(Get-SideBySideInstalls -RootPath $SideBySideRoot)
$selectedSideBySide = Select-LatestSideBySideInstall -Installs $sideBySideInstalls -LatestVersion $latestVersion
$codexProcesses = @(Get-CodexProcesses -GlobalPackageRoot $globalPackageRoot)
$globalPackageProcesses = @($codexProcesses | Where-Object { [bool]$_.UsesGlobalPackage })
$updateAvailable = $false
if ((Test-NonEmptyString $latestVersion) -and (Test-NonEmptyString $globalInstalledVersion)) {
    $updateAvailable = ([string]$latestVersion -ne [string]$globalInstalledVersion)
}
$sideBySideLatestAvailable = $false
if ($null -ne $selectedSideBySide -and (Test-NonEmptyString $latestVersion)) {
    $sideBySideLatestAvailable = ([string]$selectedSideBySide.Version -eq [string]$latestVersion)
}
$recommendedLaunchCommand = ''
if ($null -ne $selectedSideBySide -and (Test-NonEmptyString ([string]$selectedSideBySide.PowerShellShim))) {
    $recommendedLaunchCommand = "& '" + ([string]$selectedSideBySide.PowerShellShim).Replace("'", "''") + "' -a never -s danger-full-access"
}
$globalUpdateBlocked = ($globalPackageProcesses.Count -gt 0)
$updateState = 'unknown'
if ((Test-NonEmptyString $latestVersion) -and (Test-NonEmptyString $globalInstalledVersion)) {
    $updateState = if ($updateAvailable) { 'update-available' } else { 'current' }
}
$recommendation = if ($updateAvailable -and $globalUpdateBlocked -and $sideBySideLatestAvailable) {
    'global-update-locked-use-side-by-side'
}
elseif ($updateAvailable -and $globalUpdateBlocked) {
    'global-update-locked-close-codex-or-install-side-by-side'
}
elseif ($updateAvailable) {
    'run-global-npm-update'
}
elseif ($updateState -eq 'current') {
    'global-codex-current'
}
else {
    'inspect-codex-installation'
}

$payload = [ordered]@{
    SchemaVersion = 1
    GeneratedAt = $generatedAt
    IsReadOnly = $true
    PackageName = $PackageName
    CodexCommand = $CodexCommand
    CommandSources = @($commandSources)
    WhereSources = @($whereSources)
    CliVersionCommandSucceeded = [bool]$cliVersionResult.Success
    CliReportedVersion = $cliReportedVersion
    CliVersionOutput = [string]$cliVersionResult.Text
    NpmPrefixGlobal = $npmPrefix
    NpmRootGlobal = $npmRoot
    GlobalPackageRoot = $globalPackageRoot
    GlobalInstalledVersion = $globalInstalledVersion
    GlobalPackageJsonVersion = $globalPackageJsonVersion
    LatestVersion = $latestVersion
    LatestVersionSource = if (Test-NonEmptyString $LatestVersionOverride) { 'override' } elseif ($SkipNpmView) { 'skipped' } else { 'npm-view' }
    UpdateState = $updateState
    UpdateAvailable = [bool]$updateAvailable
    CodexProcessCount = [int]$codexProcesses.Count
    GlobalPackageProcessCount = [int]$globalPackageProcesses.Count
    GlobalUpdateBlocked = [bool]$globalUpdateBlocked
    Processes = @($codexProcesses)
    SideBySideRoot = [string]($SideBySideRoot ?? '')
    SideBySideInstalls = @($sideBySideInstalls)
    SideBySideLatestAvailable = [bool]$sideBySideLatestAvailable
    RecommendedTargetLaunchCommand = $recommendedLaunchCommand
    Recommendation = $recommendation
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 8
    exit 0
}

$lines = @(
    'Codex CLI update status',
    ('GeneratedAt: ' + $generatedAt),
    ('GlobalInstalledVersion: ' + $(if (Test-NonEmptyString $globalInstalledVersion) { $globalInstalledVersion } else { '(unknown)' })),
    ('LatestVersion: ' + $(if (Test-NonEmptyString $latestVersion) { $latestVersion } else { '(unknown)' })),
    ('CliReportedVersion: ' + $(if (Test-NonEmptyString $cliReportedVersion) { $cliReportedVersion } else { '(unknown)' })),
    ('UpdateState: ' + $updateState),
    ('GlobalUpdateBlocked: ' + [string]$globalUpdateBlocked),
    ('GlobalPackageProcessCount: ' + [string]$globalPackageProcesses.Count),
    ('SideBySideLatestAvailable: ' + [string]$sideBySideLatestAvailable),
    ('Recommendation: ' + $recommendation)
)
if (Test-NonEmptyString $recommendedLaunchCommand) {
    $lines += ('RecommendedTargetLaunchCommand: ' + $recommendedLaunchCommand)
}
$lines -join [Environment]::NewLine
