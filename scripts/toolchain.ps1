#requires -Version 7.0
<#
.SYNOPSIS
    Captures the installed local toolchain and writes toolchain.lock.json.

.DESCRIPTION
    The script inventories the local development and automation tools that are
    currently detectable on the machine.

    Installed tools are recorded with their discovered version and source.
    Missing or unusable tools are also recorded explicitly in the JSON output and
    are highlighted in red or yellow in the console. Missing software does not
    prevent the inventory file from being written.

    The project root is discovered dynamically. Starting from the directory that
    contains this script, the script walks upward through parent directories until
    it finds a directory named "invoiceops-lab". toolchain.lock.json is written to
    that discovered project root. If no such parent directory exists, execution
    stops with an error before any lock file is created.

    User-specific path prefixes are normalized in the generated JSON so that local
    Windows profile names are not persisted in the inventory file.

    The script does not read or serialize credentials, authentication tokens,
    passwords, PAC authentication profiles, .env values, or secret material.

.EXAMPLE
    pwsh .\toolchain.ps1

.EXAMPLE
    pwsh .\toolchain.ps1 -Verbose
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==============================================================================
# 1. PROJECT ROOT DISCOVERY
# ==============================================================================

$SchemaVersion = 4
$ProjectDirectoryName = 'invoiceops-lab'

function Find-ProjectRoot {
    param(
        [Parameter(Mandatory)]
        [string]$StartDirectory,

        [Parameter(Mandatory)]
        [string]$DirectoryName
    )

    $current = [System.IO.DirectoryInfo]::new(
        [System.IO.Path]::GetFullPath($StartDirectory)
    )

    while ($null -ne $current) {
        if ($current.Name -ieq $DirectoryName) {
            return $current.FullName.TrimEnd([char[]]@('\', '/'))
        }

        $current = $current.Parent
    }

    return $null
}

$ScriptDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd(
    [char[]]@('\', '/')
)

$RepoRoot = Find-ProjectRoot `
    -StartDirectory $ScriptDirectory `
    -DirectoryName $ProjectDirectoryName

if ([string]::IsNullOrWhiteSpace([string]$RepoRoot)) {
    Write-Host ''
    Write-Host (
        "FATAL: could not find a parent directory named '$ProjectDirectoryName'."
    ) -ForegroundColor Red
    Write-Host (
        'Place this script somewhere inside that project directory and run it again.'
    ) -ForegroundColor Red
    exit 2
}

$ProjectName = Split-Path -Path $RepoRoot -Leaf
$LockFile = Join-Path -Path $RepoRoot -ChildPath 'toolchain.lock.json'
$TemporaryLockFile = "$LockFile.tmp-$PID"

# ==============================================================================
# 2. CONSOLE HELPERS
# ==============================================================================

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkGray
}

function Write-Detected {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Host '[ OK ] ' -ForegroundColor Green -NoNewline
    Write-Host ('{0,-28} {1}' -f $Name, $Message)
}

function Write-Missing {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Host '[MISS] ' -ForegroundColor Red -NoNewline
    Write-Host ('{0,-28} {1}' -f $Name, $Message) -ForegroundColor Red
}

function Write-WarningLine {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Host '[WARN] ' -ForegroundColor Yellow -NoNewline
    Write-Host ('{0,-28} {1}' -f $Name, $Message) -ForegroundColor Yellow
}

# ==============================================================================
# 3. GENERIC HELPERS
# ==============================================================================

function Find-Application {
    param([Parameter(Mandatory)][string]$Name)

    try {
        return Get-Command `
            -Name $Name `
            -CommandType Application,ExternalScript `
            -ErrorAction Stop |
            Select-Object -First 1
    }
    catch {
        return $null
    }
}

function Get-CommandPath {
    param($CommandInfo)

    if ($null -eq $CommandInfo) {
        return $null
    }

    foreach ($propertyName in @('Source', 'Path', 'Definition')) {
        if ($CommandInfo.PSObject.Properties.Name -contains $propertyName) {
            $value = [string]$CommandInfo.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return [string]$CommandInfo.Name
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    try {
        $rawOutput = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE

        if ($null -eq $exitCode) {
            $exitCode = 0
        }

        $output = (($rawOutput | ForEach-Object { $_.ToString() }) -join "`n")
        $output = ($output -replace "`0", '').Trim()

        return [pscustomobject]@{
            success  = ($exitCode -eq 0)
            exitCode = [int]$exitCode
            output   = $output
        }
    }
    catch {
        return [pscustomobject]@{
            success  = $false
            exitCode = -1
            output   = $_.Exception.Message
        }
    }
}

function Get-VersionToken {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    # Prefer a dotted token explicitly following the word "version".
    if ($Text -match '(?im)\bversion[:\s]+v?(?<version>\d+(?:\.\d+){1,5}(?:[-+._][0-9A-Za-z.-]+)?)') {
        return $Matches.version.Trim()
    }

    # Generic fallback for output such as "uv 0.8.8" or "1.2.3".
    if ($Text -match '(?im)\bv?(?<version>\d+(?:\.\d+){1,5}(?:[-+._][0-9A-Za-z.-]+)?)\b') {
        return $Matches.version.Trim()
    }

    return $null
}

function Get-FileVersion {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }

        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)

        foreach ($candidate in @($versionInfo.ProductVersion, $versionInfo.FileVersion)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $version = Get-VersionToken -Text ([string]$candidate)
                if ($version) {
                    return $version
                }

                return ([string]$candidate).Trim()
            }
        }
    }
    catch {
        Write-Verbose "Unable to read version metadata for '$Path': $($_.Exception.Message)"
    }

    return $null
}

function New-InstalledRecord {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Source,
        [AllowNull()][string]$Path,
        [AllowNull()][hashtable]$Extra
    )

    $record = [ordered]@{
        installed = $true
        status    = 'detected'
        version   = $Version
        source    = $Source
        path      = $Path
        message   = $null
    }

    if ($null -ne $Extra) {
        foreach ($key in $Extra.Keys) {
            $record[$key] = $Extra[$key]
        }
    }

    return $record
}

function New-MissingRecord {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Source = 'not-detected',
        [AllowNull()][string]$Path = $null
    )

    return [ordered]@{
        installed = $false
        status    = 'missing'
        version   = $null
        source    = $Source
        path      = $Path
        message   = $Message
    }
}

function New-UnusableRecord {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Source,
        [AllowNull()][string]$Path
    )

    return [ordered]@{
        installed = $false
        status    = 'unusable'
        version   = $null
        source    = $Source
        path      = $Path
        message   = $Message
    }
}

function Get-UninstallEntries {
    param([Parameter(Mandatory)][string]$DisplayNamePattern)

    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        try {
            $matches = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue |
                Where-Object {
                    $displayNameProperty = $_.PSObject.Properties['DisplayName']

                    $null -ne $displayNameProperty -and
                    -not [string]::IsNullOrWhiteSpace([string]$displayNameProperty.Value) -and
                    ([string]$displayNameProperty.Value -match $DisplayNamePattern)
                }

            foreach ($entry in $matches) {
                $entries.Add($entry)
            }
        }
        catch {
            Write-Verbose "Registry inventory failed at '$registryPath': $($_.Exception.Message)"
        }
    }

    return @($entries)
}

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}


function Test-InventoryRecordComplete {
    param([Parameter(Mandatory)]$Record)

    if ($null -eq $Record) {
        return $false
    }

    if (
        $Record -is [System.Collections.IDictionary] -and
        $Record.Contains('inventoryComplete')
    ) {
        return [bool]$Record['inventoryComplete']
    }

    if (-not ($Record -is [System.Collections.IDictionary])) {
        return $false
    }

    $installed = (
        $Record.Contains('installed') -and
        [bool]$Record['installed']
    )

    $versionCaptured = (
        $Record.Contains('version') -and
        -not [string]::IsNullOrWhiteSpace([string]$Record['version'])
    )

    return ($installed -and $versionCaptured)
}

# ==============================================================================
# 4. PRIVACY-SAFE JSON PATHS
# ==============================================================================

function Protect-JsonUserPaths {
    param(
        [Parameter(Mandatory)]
        [string]$Json
    )

    $result = $Json
    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @(
        @{ value = $env:LOCALAPPDATA; token = '%LOCALAPPDATA%' },
        @{ value = $env:APPDATA;      token = '%APPDATA%' },
        @{ value = $env:USERPROFILE;  token = '%USERPROFILE%' },
        @{ value = $HOME;             token = '%HOME%' }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.value)) {
            continue
        }

        $fullPath = [System.IO.Path]::GetFullPath([string]$entry.value).TrimEnd(
            [char[]]@('\', '/')
        )

        $alreadyPresent = $false

        foreach ($candidate in $candidates) {
            if (
                [string]::Equals(
                    [string]$candidate.value,
                    $fullPath,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $alreadyPresent = $true
                break
            }
        }

        if (-not $alreadyPresent) {
            $candidates.Add(
                [pscustomobject]@{
                    value = $fullPath
                    token = [string]$entry.token
                }
            )
        }
    }

    $orderedCandidates = @(
        $candidates |
        Sort-Object {
            ([string]$_.value).Length
        } -Descending
    )

    foreach ($candidate in $orderedCandidates) {
        # Convert the Windows path to the representation used inside JSON strings.
        $jsonPath = ([string]$candidate.value).Replace('\', '\\')

        $result = [System.Text.RegularExpressions.Regex]::Replace(
            $result,
            [System.Text.RegularExpressions.Regex]::Escape($jsonPath),
            [string]$candidate.token,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    return $result
}

# ==============================================================================
# 5. DISCOVERED PROJECT ROOT
# ==============================================================================

Write-Section 'InvoiceOps · Toolchain inventory'

Write-Host "Script : $(Split-Path -Path $PSCommandPath -Leaf)" -ForegroundColor DarkGray
Write-Host "Root   : $ProjectName" -ForegroundColor DarkGray
Write-Host "Output : toolchain.lock.json" -ForegroundColor DarkGray

Write-Detected 'project root' $ProjectName

# Run context-sensitive version probes from the discovered project root. This avoids
# accidentally inheriting project-local configuration from the caller's directory.
Set-Location -LiteralPath $RepoRoot

# ==============================================================================
# 6. HOST / POWERSHELL / WSL
# ==============================================================================

function Get-HostInventory {
    $operatingSystem = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim()
    $osVersion = [System.Environment]::OSVersion.Version.ToString()

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop

        if (-not [string]::IsNullOrWhiteSpace([string]$os.Caption)) {
            $operatingSystem = [string]$os.Caption
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$os.Version)) {
            $osVersion = [string]$os.Version
        }
    }
    catch {
        Write-Verbose "Win32_OperatingSystem query failed: $($_.Exception.Message)"
    }

    return [ordered]@{
        operatingSystem = $operatingSystem
        osVersion       = $osVersion
        architecture    = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powerShell      = [ordered]@{
            installed = $true
            status    = 'detected'
            version   = $PSVersionTable.PSVersion.ToString()
            edition   = [string]$PSVersionTable.PSEdition
            path      = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        }
    }
}

function Get-WslInventory {
    $command = Find-Application -Name 'wsl.exe'

    if ($null -eq $command) {
        return [ordered]@{
            installed           = $false
            status              = 'missing'
            version             = $null
            path                = $null
            distributions       = @()
            preferredDistro     = $null
            statusCommandPassed = $false
            message             = 'wsl.exe was not found.'
        }
    }

    $path = Get-CommandPath -CommandInfo $command

    $versionProbe = Invoke-NativeCapture -FilePath $path -Arguments @('--version')
    $statusProbe = Invoke-NativeCapture -FilePath $path -Arguments @('--status')
    $listProbe = Invoke-NativeCapture -FilePath $path -Arguments @('-l', '-q')

    $version = $null
    if ($versionProbe.success) {
        $version = Get-VersionToken -Text $versionProbe.output
    }

    $distributions = @()
    if ($listProbe.success -and -not [string]::IsNullOrWhiteSpace($listProbe.output)) {
        $cleanOutput = $listProbe.output -replace "`0", ''

        $distributions = @(
            $cleanOutput -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
        )
    }

    $preferredDistro = $null

    if ($distributions -contains 'Ubuntu-24.04') {
        $preferredDistro = 'Ubuntu-24.04'
    }
    elseif ($distributions.Count -gt 0) {
        $preferredDistro = $distributions |
            Where-Object { $_ -match '(?i)ubuntu' } |
            Select-Object -First 1

        if (-not $preferredDistro) {
            $preferredDistro = $distributions | Select-Object -First 1
        }
    }

    return [ordered]@{
        installed           = $true
        status              = 'detected'
        version             = $version
        path                = $path
        distributions       = @($distributions)
        preferredDistro     = $preferredDistro
        statusCommandPassed = [bool]$statusProbe.success
        message             = $null
    }
}

# ==============================================================================
# 6. GENERIC CLI INVENTORY
# ==============================================================================

function Get-CliInventory {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$CommandName,
        [string[]]$VersionArguments = @('--version'),
        [AllowNull()][string]$VersionRegex = $null,
        [ValidateSet('core', 'supplemental')][string]$Importance = 'core'
    )

    $command = Find-Application -Name $CommandName

    if ($null -eq $command) {
        $message = "'$CommandName' was not found in Windows PATH."

        if ($Importance -eq 'core') {
            Write-Missing $DisplayName $message
        }
        else {
            Write-WarningLine $DisplayName $message
        }

        return New-MissingRecord -Message $message
    }

    $path = Get-CommandPath -CommandInfo $command
    $probe = Invoke-NativeCapture -FilePath $path -Arguments $VersionArguments

    if (-not $probe.success) {
        $message = "'$CommandName' exists, but its version probe failed with exit code $($probe.exitCode)."

        if ($Importance -eq 'core') {
            Write-Missing $DisplayName $message
        }
        else {
            Write-WarningLine $DisplayName $message
        }

        return New-UnusableRecord -Message $message -Source 'windows-path' -Path $path
    }

    $version = $null

    if (
        -not [string]::IsNullOrWhiteSpace($VersionRegex) -and
        $probe.output -match $VersionRegex
    ) {
        $version = $Matches.version
    }

    if (-not $version) {
        $version = Get-VersionToken -Text $probe.output
    }

    if (-not $version) {
        $message = "'$CommandName' responded successfully, but its version could not be parsed."

        if ($Importance -eq 'core') {
            Write-Missing $DisplayName $message
        }
        else {
            Write-WarningLine $DisplayName $message
        }

        return New-UnusableRecord -Message $message -Source 'windows-path' -Path $path
    }

    Write-Detected $DisplayName $version

    return New-InstalledRecord `
        -Version $version `
        -Source 'windows-path' `
        -Path $path `
        -Extra $null
}

# ==============================================================================
# 7. PAC CLI
# ==============================================================================

function Get-PacInventory {
    $command = Find-Application -Name 'pac'

    if ($null -eq $command) {
        $message = "'pac' was not found in Windows PATH."
        Write-Missing 'pac' $message
        return New-MissingRecord -Message $message
    }

    $path = Get-CommandPath -CommandInfo $command
    $version = $null
    $versionMethod = $null

    # Microsoft's documented version check is invoking `pac` with no command.
    # Keep --version and executable metadata as resilient fallbacks.
    foreach ($probeDefinition in @(
        @{ arguments = @();            method = 'pac' },
        @{ arguments = @('--version'); method = 'pac --version' }
    )) {
        $probe = Invoke-NativeCapture `
            -FilePath $path `
            -Arguments $probeDefinition.arguments

        if ($probe.success -and -not [string]::IsNullOrWhiteSpace($probe.output)) {
            $candidate = Get-VersionToken -Text $probe.output

            if ($candidate) {
                $version = $candidate
                $versionMethod = $probeDefinition.method
                break
            }
        }
    }

    if (-not $version -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        $version = Get-FileVersion -Path $path
        if ($version) {
            $versionMethod = 'executable metadata'
        }
    }

    if (-not $version) {
        $message = 'PAC CLI was detected, but its version could not be determined.'
        Write-Missing 'pac' $message

        return New-UnusableRecord `
            -Message $message `
            -Source 'windows-path' `
            -Path $path
    }

    Write-Detected 'pac' "$version ($versionMethod)"

    return New-InstalledRecord `
        -Version $version `
        -Source 'windows-path' `
        -Path $path `
        -Extra @{
            versionMethod = $versionMethod
        }
}

# ==============================================================================
# 8. DOCKER + COMPOSE
# ==============================================================================

function Get-DockerComposeVersionWindows {
    param([Parameter(Mandatory)][string]$DockerPath)

    $probe = Invoke-NativeCapture `
        -FilePath $DockerPath `
        -Arguments @('compose', 'version', '--short')

    if ($probe.success -and -not [string]::IsNullOrWhiteSpace($probe.output)) {
        return $probe.output.Trim().TrimStart('v')
    }

    $probe = Invoke-NativeCapture `
        -FilePath $DockerPath `
        -Arguments @('compose', 'version')

    if ($probe.success) {
        return Get-VersionToken -Text $probe.output
    }

    return $null
}

function Get-DockerComposeVersionWsl {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Distribution
    )

    $probe = Invoke-NativeCapture `
        -FilePath $WslPath `
        -Arguments @(
            '-d', $Distribution, '--',
            'bash', '-lc',
            'docker compose version --short'
        )

    if ($probe.success -and -not [string]::IsNullOrWhiteSpace($probe.output)) {
        return $probe.output.Trim().TrimStart('v')
    }

    $probe = Invoke-NativeCapture `
        -FilePath $WslPath `
        -Arguments @(
            '-d', $Distribution, '--',
            'bash', '-lc',
            'docker compose version'
        )

    if ($probe.success) {
        return Get-VersionToken -Text $probe.output
    }

    return $null
}

function Get-DockerInventory {
    param([Parameter(Mandatory)]$WslInventory)

    # 1. Native Windows Docker, if present.
    $nativeCommand = Find-Application -Name 'docker'

    if ($null -ne $nativeCommand) {
        $path = Get-CommandPath -CommandInfo $nativeCommand
        $probe = Invoke-NativeCapture -FilePath $path -Arguments @('--version')

        if ($probe.success) {
            $version = Get-VersionToken -Text $probe.output

            if ($version) {
                $composeVersion = Get-DockerComposeVersionWindows -DockerPath $path

                Write-Detected 'docker' "$version (Windows PATH)"

                if ($composeVersion) {
                    Write-Detected 'docker compose' $composeVersion
                }
                else {
                    Write-WarningLine 'docker compose' 'Compose plugin version was not detected.'
                }

                return New-InstalledRecord `
                    -Version $version `
                    -Source 'windows-path' `
                    -Path $path `
                    -Extra @{
                        distribution   = $null
                        composeVersion = $composeVersion
                    }
            }
        }

        Write-WarningLine 'docker' 'Windows docker command exists but did not yield a usable version; trying WSL.'
    }

    # 2. Expected InvoiceOps topology: Docker Engine in Ubuntu/WSL.
    if (-not $WslInventory.installed) {
        $message = 'Docker was not found in Windows PATH and WSL is unavailable.'
        Write-Missing 'docker' $message
        return New-MissingRecord -Message $message
    }

    $distribution = [string]$WslInventory.preferredDistro

    if ([string]::IsNullOrWhiteSpace($distribution)) {
        $message = 'Docker was not found in Windows PATH and no usable WSL distribution was detected.'
        Write-Missing 'docker' $message
        return New-MissingRecord -Message $message
    }

    $wslPath = [string]$WslInventory.path

    $pathProbe = Invoke-NativeCapture `
        -FilePath $wslPath `
        -Arguments @(
            '-d', $distribution, '--',
            'bash', '-lc',
            'command -v docker'
        )

    if (-not $pathProbe.success -or [string]::IsNullOrWhiteSpace($pathProbe.output)) {
        $message = "Docker was not found in Windows PATH or WSL distribution '$distribution'."
        Write-Missing 'docker' $message
        return New-MissingRecord -Message $message
    }

    $versionProbe = Invoke-NativeCapture `
        -FilePath $wslPath `
        -Arguments @(
            '-d', $distribution, '--',
            'bash', '-lc',
            'docker --version'
        )

    if (-not $versionProbe.success) {
        $message = "Docker exists in WSL '$distribution', but 'docker --version' failed."
        Write-Missing 'docker' $message

        return New-UnusableRecord `
            -Message $message `
            -Source 'wsl' `
            -Path $pathProbe.output.Trim()
    }

    $version = Get-VersionToken -Text $versionProbe.output

    if (-not $version) {
        $message = "Docker exists in WSL '$distribution', but its version could not be parsed."
        Write-Missing 'docker' $message

        return New-UnusableRecord `
            -Message $message `
            -Source 'wsl' `
            -Path $pathProbe.output.Trim()
    }

    $composeVersion = Get-DockerComposeVersionWsl `
        -WslPath $wslPath `
        -Distribution $distribution

    Write-Detected 'docker' "$version (WSL: $distribution)"

    if ($composeVersion) {
        Write-Detected 'docker compose' $composeVersion
    }
    else {
        Write-WarningLine 'docker compose' "Compose plugin version was not detected in WSL '$distribution'."
    }

    return New-InstalledRecord `
        -Version $version `
        -Source 'wsl' `
        -Path $pathProbe.output.Trim() `
        -Extra @{
            distribution   = $distribution
            composeVersion = $composeVersion
        }
}

# ==============================================================================
# 9. POWER AUTOMATE FOR DESKTOP
# ==============================================================================

function Get-PadInventory {
    $registryEntries = @(
        Get-UninstallEntries `
            -DisplayNamePattern '(?i)^(Microsoft )?Power Automate for desktop$'
    )

    $knownExecutables = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $knownExecutables.Add(
            (Join-Path ${env:ProgramFiles(x86)} 'Power Automate Desktop\dotnet\PAD.Console.Host.exe')
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $knownExecutables.Add(
            (Join-Path $env:ProgramFiles 'Power Automate Desktop\dotnet\PAD.Console.Host.exe')
        )
    }

    $msiExecutable = $knownExecutables |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    $msiVersion = $null
    $msiDisplayName = $null

    if ($registryEntries.Count -gt 0) {
        $entry = $registryEntries |
            Sort-Object -Property DisplayVersion -Descending |
            Select-Object -First 1

        $displayNameProperty = $entry.PSObject.Properties['DisplayName']
        if ($null -ne $displayNameProperty) {
            $msiDisplayName = [string]$displayNameProperty.Value
        }

        $displayVersionProperty = $entry.PSObject.Properties['DisplayVersion']
        if (
            $null -ne $displayVersionProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$displayVersionProperty.Value)
        ) {
            $msiVersion = [string]$displayVersionProperty.Value
        }
    }

    if (-not $msiVersion -and $msiExecutable) {
        $msiVersion = Get-FileVersion -Path $msiExecutable
    }

    $storePackage = $null

    try {
        $storePackage = Get-AppxPackage `
            -Name 'Microsoft.PowerAutomateDesktop' `
            -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1
    }
    catch {
        Write-Verbose "PAD Get-AppxPackage query failed: $($_.Exception.Message)"
    }

    if (-not $storePackage) {
        try {
            $storePackage = Get-AppxPackage -ErrorAction SilentlyContinue |
                Where-Object {
                    ([string]$_.Name -match '(?i)PowerAutomate') -or
                    ([string]$_.PackageFamilyName -match '(?i)PowerAutomate')
                } |
                Sort-Object -Property Version -Descending |
                Select-Object -First 1
        }
        catch {
            Write-Verbose "PAD fallback Appx query failed: $($_.Exception.Message)"
        }
    }

    $hasMsi = (-not [string]::IsNullOrWhiteSpace($msiVersion)) -or ($null -ne $msiExecutable)
    $hasStore = $null -ne $storePackage

    if ($hasMsi -and $hasStore) {
        $message = 'Both MSI and Microsoft Store/MSIX PAD installations were detected.'

        Write-WarningLine 'PAD' $message

        $primaryVersion = [string]$storePackage.Version
        if ($msiVersion) {
            $primaryVersion = $msiVersion
        }

        return [ordered]@{
            installed     = $true
            status        = 'detected-with-warning'
            version       = $primaryVersion
            source        = 'multiple-installations'
            path          = $msiExecutable
            message       = $message
            installType   = 'multiple'
            installations = @(
                [ordered]@{
                    type        = 'msi'
                    version     = $msiVersion
                    path        = $msiExecutable
                    displayName = $msiDisplayName
                },
                [ordered]@{
                    type        = 'msix'
                    version     = [string]$storePackage.Version
                    path        = [string]$storePackage.InstallLocation
                    packageName = [string]$storePackage.Name
                }
            )
        }
    }

    if ($hasMsi) {
        if (-not $msiVersion) {
            $message = 'PAD MSI installation was detected, but its version could not be determined.'
            Write-Missing 'PAD' $message

            return New-UnusableRecord `
                -Message $message `
                -Source 'msi' `
                -Path $msiExecutable
        }

        Write-Detected 'PAD' "$msiVersion (MSI)"

        return New-InstalledRecord `
            -Version $msiVersion `
            -Source 'msi' `
            -Path $msiExecutable `
            -Extra @{
                installType = 'msi'
                displayName = $msiDisplayName
                packageName = $null
            }
    }

    if ($hasStore) {
        $version = [string]$storePackage.Version

        if ([string]::IsNullOrWhiteSpace($version)) {
            $message = 'PAD Store/MSIX installation was detected, but its version is unavailable.'
            Write-Missing 'PAD' $message

            return New-UnusableRecord `
                -Message $message `
                -Source 'msix' `
                -Path ([string]$storePackage.InstallLocation)
        }

        Write-Detected 'PAD' "$version (Microsoft Store/MSIX)"

        return New-InstalledRecord `
            -Version $version `
            -Source 'msix' `
            -Path ([string]$storePackage.InstallLocation) `
            -Extra @{
                installType = 'msix'
                displayName = 'Power Automate'
                packageName = [string]$storePackage.Name
            }
    }

    $message = 'Power Automate for desktop was not detected as MSI or Microsoft Store/MSIX.'
    Write-Missing 'PAD' $message
    return New-MissingRecord -Message $message
}

# ==============================================================================
# 10. UIPATH STUDIO + ASSISTANT
# ==============================================================================

function Get-UiPathInventory {
    $registryEntries = @(
        Get-UninstallEntries `
            -DisplayNamePattern '(?i)^UiPath( Studio.*|Studio.*)$'
    )

    $studioDirectories = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $studioDirectories.Add(
            (Join-Path $env:ProgramFiles 'UiPath\Studio')
        )
    }

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $studioDirectories.Add(
            (Join-Path ${env:ProgramFiles(x86)} 'UiPath\Studio')
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $studioDirectories.Add(
            (Join-Path $env:LOCALAPPDATA 'Programs\UiPath\Studio')
        )
    }

    $studioExecutable = $null
    $commandLineExecutable = $null
    $assistantExecutable = $null

    foreach ($directory in $studioDirectories) {
        $studioCandidate = Join-Path $directory 'UiPath.Studio.exe'
        $cliCandidate = Join-Path $directory 'UiPath.Studio.CommandLine.exe'
        $assistantCandidate = Join-Path $directory 'UiPathAssistant\UiPath.Assistant.exe'

        if (-not $studioExecutable -and (Test-Path -LiteralPath $studioCandidate -PathType Leaf)) {
            $studioExecutable = $studioCandidate
        }

        if (-not $commandLineExecutable -and (Test-Path -LiteralPath $cliCandidate -PathType Leaf)) {
            $commandLineExecutable = $cliCandidate
        }

        if (-not $assistantExecutable -and (Test-Path -LiteralPath $assistantCandidate -PathType Leaf)) {
            $assistantExecutable = $assistantCandidate
        }
    }

    $registryVersion = $null
    $registryDisplayName = $null

    if ($registryEntries.Count -gt 0) {
        $entry = $registryEntries |
            Sort-Object -Property DisplayVersion -Descending |
            Select-Object -First 1

        $displayNameProperty = $entry.PSObject.Properties['DisplayName']
        if ($null -ne $displayNameProperty) {
            $registryDisplayName = [string]$displayNameProperty.Value
        }

        $displayVersionProperty = $entry.PSObject.Properties['DisplayVersion']
        if (
            $null -ne $displayVersionProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$displayVersionProperty.Value)
        ) {
            $registryVersion = [string]$displayVersionProperty.Value
        }
    }

    $studioVersion = $null
    $versionMethod = $null

    if ($commandLineExecutable) {
        $probe = Invoke-NativeCapture `
            -FilePath $commandLineExecutable `
            -Arguments @('--version')

        if ($probe.success) {
            $studioVersion = Get-VersionToken -Text $probe.output
            if ($studioVersion) {
                $versionMethod = 'UiPath.Studio.CommandLine.exe --version'
            }
        }
    }

    if (-not $studioVersion -and $studioExecutable) {
        $studioVersion = Get-FileVersion -Path $studioExecutable
        if ($studioVersion) {
            $versionMethod = 'UiPath.Studio.exe metadata'
        }
    }

    if (-not $studioVersion -and $registryVersion) {
        $studioVersion = $registryVersion
        $versionMethod = 'Windows uninstall registry'
    }

    $assistantVersion = $null
    if ($assistantExecutable) {
        $assistantVersion = Get-FileVersion -Path $assistantExecutable
    }

    $anythingDetected = (
        $null -ne $studioExecutable -or
        $null -ne $commandLineExecutable -or
        $null -ne $assistantExecutable -or
        $registryEntries.Count -gt 0
    )

    if (-not $anythingDetected) {
        $message = 'UiPath Studio/Assistant was not detected.'
        Write-Missing 'UiPath' $message

        return [ordered]@{
            installed         = $false
            inventoryComplete = $false
            status            = 'missing'
            version           = $null
            source            = 'not-detected'
            path              = $null
            message           = $message
            studio            = [ordered]@{
                installed = $false
                version   = $null
                path      = $null
            }
            assistant = [ordered]@{
                installed = $false
                version   = $null
                path      = $null
            }
        }
    }

    if (-not $studioVersion) {
        $message = 'UiPath installation was detected, but Studio version could not be determined.'
        Write-WarningLine 'UiPath' $message

        return [ordered]@{
            installed         = $true
            inventoryComplete = $false
            status            = 'detected-version-unknown'
            version           = $null
            source            = 'windows-installation'
            path              = $studioExecutable
            message           = $message
            studio            = [ordered]@{
                installed     = ($null -ne $studioExecutable)
                version       = $null
                path          = $studioExecutable
                versionMethod = $null
                displayName   = $registryDisplayName
            }
            assistant = [ordered]@{
                installed = ($null -ne $assistantExecutable)
                version   = $assistantVersion
                path      = $assistantExecutable
            }
        }
    }

    Write-Detected 'UiPath Studio' "$studioVersion ($versionMethod)"

    if ($assistantExecutable) {
        $assistantLabel = 'installed; version unknown'
        if ($assistantVersion) {
            $assistantLabel = $assistantVersion
        }

        Write-Detected 'UiPath Assistant' $assistantLabel
    }
    else {
        Write-WarningLine 'UiPath Assistant' 'Studio detected, but Assistant executable was not found.'
    }

    $uiPathInventoryComplete = (
        -not [string]::IsNullOrWhiteSpace($studioVersion) -and
        $null -ne $assistantExecutable -and
        -not [string]::IsNullOrWhiteSpace($assistantVersion)
    )

    $uiPathStatus = 'detected-partial'
    $uiPathMessage = 'UiPath Studio version was captured, but Assistant installation/version is incomplete.'

    if ($uiPathInventoryComplete) {
        $uiPathStatus = 'detected'
        $uiPathMessage = $null
    }

    return [ordered]@{
        installed         = $true
        inventoryComplete = $uiPathInventoryComplete
        status            = $uiPathStatus
        version           = $studioVersion
        source            = 'windows-installation'
        path              = $studioExecutable
        message           = $uiPathMessage
        studio            = [ordered]@{
            installed     = $true
            version       = $studioVersion
            path          = $studioExecutable
            commandLine   = $commandLineExecutable
            versionMethod = $versionMethod
            displayName   = $registryDisplayName
        }
        assistant = [ordered]@{
            installed = ($null -ne $assistantExecutable)
            version   = $assistantVersion
            path      = $assistantExecutable
        }
    }
}

# ==============================================================================
# 11. AUTOMATION ANYWHERE BOT AGENT
# ==============================================================================

function Get-AutomationAnywhereInventory {
    $registryEntries = @(
        Get-UninstallEntries `
            -DisplayNamePattern '(?i)Automation Anywhere.*Bot Agent|Automation 360.*Bot Agent'
    )

    $installDirectories = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $installDirectories.Add(
            (Join-Path $env:ProgramFiles 'Automation Anywhere\Bot Agent')
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $installDirectories.Add(
            (Join-Path $env:LOCALAPPDATA 'Programs\Automation Anywhere\Bot Agent')
        )
    }

    $installDirectory = $installDirectories |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        Select-Object -First 1

    $registryVersion = $null
    $registryDisplayName = $null

    if ($registryEntries.Count -gt 0) {
        $entry = $registryEntries |
            Sort-Object -Property DisplayVersion -Descending |
            Select-Object -First 1

        $displayNameProperty = $entry.PSObject.Properties['DisplayName']
        if ($null -ne $displayNameProperty) {
            $registryDisplayName = [string]$displayNameProperty.Value
        }

        $displayVersionProperty = $entry.PSObject.Properties['DisplayVersion']
        if (
            $null -ne $displayVersionProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$displayVersionProperty.Value)
        ) {
            $registryVersion = [string]$displayVersionProperty.Value
        }
    }

    $versionExecutable = $null

    if ($installDirectory) {
        foreach ($fileName in @(
            'NodeManager.exe',
            'AADiagnosticUtility.exe',
            'BotLauncher.exe'
        )) {
            $candidate = Join-Path $installDirectory $fileName

            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $versionExecutable = $candidate
                break
            }
        }
    }

    $version = $registryVersion
    $versionMethod = $null

    if ($registryVersion) {
        $versionMethod = 'Windows uninstall registry'
    }

    if (-not $version -and $versionExecutable) {
        $version = Get-FileVersion -Path $versionExecutable

        if ($version) {
            $versionMethod = 'Bot Agent executable metadata'
        }
    }

    $anythingDetected = (
        $registryEntries.Count -gt 0 -or
        $null -ne $installDirectory
    )

    if (-not $anythingDetected) {
        $message = 'Automation Anywhere Bot Agent was not detected. This is valid before the Automation Anywhere lab is configured.'
        Write-Missing 'Automation Anywhere' $message

        $record = New-MissingRecord -Message $message
        $record['inventoryComplete'] = $false
        return $record
    }

    if (-not $version) {
        $message = 'Automation Anywhere Bot Agent was detected, but its version could not be determined.'
        Write-WarningLine 'Automation Anywhere' $message

        return [ordered]@{
            installed         = $true
            inventoryComplete = $false
            status            = 'detected-version-unknown'
            version           = $null
            source            = 'windows-installation'
            path              = $installDirectory
            message           = $message
            displayName       = $registryDisplayName
            versionMethod     = $null
        }
    }

    Write-Detected 'Automation Anywhere' "$version ($versionMethod)"

    $record = New-InstalledRecord `
        -Version $version `
        -Source 'windows-installation' `
        -Path $installDirectory `
        -Extra @{
            displayName       = $registryDisplayName
            versionMethod     = $versionMethod
            versionExecutable = $versionExecutable
        }

    $record['inventoryComplete'] = $true
    return $record
}

# ==============================================================================
# 12. COLLECT INVENTORY
# ==============================================================================

Write-Section 'Core tools'

$Git = Get-CliInventory `
    -DisplayName 'git' `
    -CommandName 'git' `
    -Importance core

$DotNet = Get-CliInventory `
    -DisplayName 'dotnet' `
    -CommandName 'dotnet' `
    -Importance core

$Python = Get-CliInventory `
    -DisplayName 'python' `
    -CommandName 'python' `
    -VersionRegex '(?i)Python\s+(?<version>\d+(?:\.\d+){1,3})' `
    -Importance core

$Node = Get-CliInventory `
    -DisplayName 'node' `
    -CommandName 'node' `
    -Importance core

$Pac = Get-PacInventory

$Wsl = Get-WslInventory
$Docker = Get-DockerInventory -WslInventory $Wsl

$Pad = Get-PadInventory

Write-Section 'Evergreen vendor clients'

$UiPath = Get-UiPathInventory
$AutomationAnywhere = Get-AutomationAnywhereInventory

Write-Section 'Supplemental local context'

$Uv = Get-CliInventory `
    -DisplayName 'uv' `
    -CommandName 'uv' `
    -Importance supplemental

$Pnpm = Get-CliInventory `
    -DisplayName 'pnpm' `
    -CommandName 'pnpm' `
    -Importance supplemental

if ($Wsl.installed) {
    $wslVersionLabel = 'version unknown'
    if ($Wsl.version) {
        $wslVersionLabel = [string]$Wsl.version
    }

    if ($Wsl.preferredDistro) {
        Write-Detected 'WSL' "$wslVersionLabel; preferred: $($Wsl.preferredDistro)"
    }
    else {
        Write-Detected 'WSL' "$wslVersionLabel; no distro detected"
    }
}
else {
    Write-WarningLine 'WSL' 'not detected'
}

# ==============================================================================
# 13. STATUS SUMMARY
# ==============================================================================

$CoreTools = [ordered]@{
    git                  = $Git
    dotnet               = $DotNet
    python               = $Python
    node                 = $Node
    pac                  = $Pac
    docker               = $Docker
    powerAutomateDesktop = $Pad
}

$coreDetected = @(
    $CoreTools.GetEnumerator() |
    Where-Object { Test-InventoryRecordComplete -Record $_.Value }
).Count

$coreMissingNames = @(
    $CoreTools.GetEnumerator() |
    Where-Object { -not (Test-InventoryRecordComplete -Record $_.Value) } |
    ForEach-Object { [string]$_.Key }
)

$EvergreenVendorClients = [ordered]@{
    powerPlatformCli      = $Pac
    powerAutomateDesktop  = $Pad
    uiPath                = $UiPath
    automationAnywhere    = $AutomationAnywhere
}

$evergreenDetected = @(
    $EvergreenVendorClients.GetEnumerator() |
    Where-Object { Test-InventoryRecordComplete -Record $_.Value }
).Count

$evergreenMissingNames = @(
    $EvergreenVendorClients.GetEnumerator() |
    Where-Object { -not (Test-InventoryRecordComplete -Record $_.Value) } |
    ForEach-Object { [string]$_.Key }
)

$DockerComposeRecord = [ordered]@{
    installed = $false
    status    = 'missing-or-unknown'
    version   = $null
    source    = $null
}

if (
    $Docker.installed -and
    -not [string]::IsNullOrWhiteSpace([string]$Docker.composeVersion)
) {
    $DockerComposeRecord = [ordered]@{
        installed = $true
        status    = 'detected'
        version   = [string]$Docker.composeVersion
        source    = [string]$Docker.source
    }
}

# ==============================================================================
# 14. BUILD LOCK OBJECT
# ==============================================================================

# The payload below intentionally excludes generatedAtUtc and inventorySha256.
# It is hashed so repeated runs do not modify Git state when nothing changed.
$InventoryPayload = [ordered]@{
    schemaVersion = $SchemaVersion
    project       = $ProjectName

    policy = [ordered]@{
        missingToolIsFatal = $false
        missingToolEncoding = 'installed=false; version=null'
    }

    coverage = [ordered]@{
        coreTools = @(
            'git',
            'dotnet',
            'python',
            'node',
            'pac',
            'docker',
            'powerAutomateDesktop'
        )

        evergreenVendorClients = @(
            'powerPlatformCli',
            'powerAutomateDesktop',
            'uiPath',
            'automationAnywhere'
        )
    }

    status = [ordered]@{
        core = [ordered]@{
            expectedCount          = $CoreTools.Count
            detectedCount          = $coreDetected
            missingOrUnusableCount = ($CoreTools.Count - $coreDetected)
            missingOrUnusableTools = @($coreMissingNames)
            complete               = ($coreDetected -eq $CoreTools.Count)
        }

        evergreenVendorClients = [ordered]@{
            expectedCount          = $EvergreenVendorClients.Count
            detectedCount          = $evergreenDetected
            missingOrUnusableCount = ($EvergreenVendorClients.Count - $evergreenDetected)
            missingOrUnusableTools = @($evergreenMissingNames)
            complete               = ($evergreenDetected -eq $EvergreenVendorClients.Count)
        }
    }

    host = Get-HostInventory

    tools = $CoreTools

    evergreenVendorClients = $EvergreenVendorClients

    supplemental = [ordered]@{
        wsl           = $Wsl
        uv            = $Uv
        pnpm          = $Pnpm
        dockerCompose = $DockerComposeRecord
    }
}

$PayloadJson = $InventoryPayload | ConvertTo-Json -Depth 24
$PayloadJson = Protect-JsonUserPaths -Json $PayloadJson
$InventorySha256 = Get-Sha256Text -Text $PayloadJson

# Parse the privacy-normalized payload back into an ordered hashtable so the final
# lock object contains only normalized user-specific paths.
$SafeInventoryPayload = $PayloadJson |
    ConvertFrom-Json -AsHashtable -Depth 24 -ErrorAction Stop

$LockObject = [ordered]@{
    schemaVersion   = $SchemaVersion
    project         = $ProjectName
    generatedAtUtc  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    inventorySha256 = $InventorySha256

    policy                 = $SafeInventoryPayload.policy
    coverage               = $SafeInventoryPayload.coverage
    status                 = $SafeInventoryPayload.status
    host                   = $SafeInventoryPayload.host
    tools                  = $SafeInventoryPayload.tools
    evergreenVendorClients = $SafeInventoryPayload.evergreenVendorClients
    supplemental           = $SafeInventoryPayload.supplemental
}

# ==============================================================================
# 15. SERIALIZE + VALIDATE IN MEMORY
# ==============================================================================

try {
    $Json = $LockObject | ConvertTo-Json -Depth 24
    $Parsed = $Json | ConvertFrom-Json -Depth 24 -ErrorAction Stop

    if ([int]$Parsed.schemaVersion -ne $SchemaVersion) {
        throw 'Generated JSON has an unexpected schemaVersion.'
    }

    if ([string]$Parsed.project -ne $ProjectName) {
        throw 'Generated JSON has an unexpected project value.'
    }

    foreach ($toolName in @(
        'git',
        'dotnet',
        'python',
        'node',
        'pac',
        'docker',
        'powerAutomateDesktop'
    )) {
        if ($null -eq $Parsed.tools.$toolName) {
            throw "Generated JSON is missing tools.$toolName."
        }

        if (-not ($Parsed.tools.$toolName.PSObject.Properties.Name -contains 'installed')) {
            throw "Generated JSON is missing tools.$toolName.installed."
        }

        if (-not ($Parsed.tools.$toolName.PSObject.Properties.Name -contains 'version')) {
            throw "Generated JSON is missing tools.$toolName.version."
        }
    }

    foreach ($vendorClientName in @(
        'powerPlatformCli',
        'powerAutomateDesktop',
        'uiPath',
        'automationAnywhere'
    )) {
        if ($null -eq $Parsed.evergreenVendorClients.$vendorClientName) {
            throw "Generated JSON is missing evergreenVendorClients.$vendorClientName."
        }

        if (
            -not (
                $Parsed.evergreenVendorClients.$vendorClientName.PSObject.Properties.Name `
                    -contains 'installed'
            )
        ) {
            throw "Generated JSON is missing evergreenVendorClients.$vendorClientName.installed."
        }
    }
}
catch {
    Write-Section 'FATAL · JSON generation/validation error'
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host 'toolchain.lock.json was not replaced.' -ForegroundColor Yellow
    exit 1
}

# ==============================================================================
# 16. DO NOT REWRITE AN UNCHANGED INVENTORY
# ==============================================================================

$InventoryUnchanged = $false

if (Test-Path -LiteralPath $LockFile -PathType Leaf) {
    try {
        $existingText = Get-Content -LiteralPath $LockFile -Raw -Encoding UTF8
        $existingJson = $existingText | ConvertFrom-Json -Depth 24 -ErrorAction Stop

        if (
            $existingJson.PSObject.Properties.Name -contains 'inventorySha256' -and
            [string]$existingJson.inventorySha256 -eq $InventorySha256
        ) {
            $InventoryUnchanged = $true
        }
    }
    catch {
        Write-WarningLine 'existing lock' 'existing file is invalid/old; it will be replaced'
    }
}

if ($InventoryUnchanged) {
    Write-Section 'Inventory complete'

    Write-Detected 'toolchain.lock.json' 'inventory unchanged; existing file kept'
    Write-Host "Output: toolchain.lock.json" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host "Core tools detected         : $coreDetected / $($CoreTools.Count)"
    Write-Host "Evergreen clients detected  : $evergreenDetected / $($EvergreenVendorClients.Count)"

    if ($coreDetected -ne $CoreTools.Count) {
        Write-Host ''
        Write-Host 'Core tools currently missing/unusable:' -ForegroundColor Red
        foreach ($name in $coreMissingNames) {
            Write-Host "  - $name" -ForegroundColor Red
        }
    }

    if ($evergreenDetected -ne $EvergreenVendorClients.Count) {
        Write-Host ''
        Write-Host 'Evergreen vendor clients currently missing/unusable:' -ForegroundColor Red
        foreach ($name in $evergreenMissingNames) {
            Write-Host "  - $name" -ForegroundColor Red
        }
    }

    Write-Host ''
    Write-Host 'Exit code: 0 (inventory succeeded; missing software is recorded, not fatal).' `
        -ForegroundColor Green
    exit 0
}

# ==============================================================================
# 17. ATOMIC WRITE + ON-DISK JSON VALIDATION
# ==============================================================================

try {
    if (Test-Path -LiteralPath $TemporaryLockFile) {
        Remove-Item -LiteralPath $TemporaryLockFile -Force
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    [System.IO.File]::WriteAllText(
        $TemporaryLockFile,
        ($Json + [Environment]::NewLine),
        $utf8NoBom
    )

    # Validate the actual bytes written before replacing the real lock file.
    $writtenText = [System.IO.File]::ReadAllText(
        $TemporaryLockFile,
        [System.Text.Encoding]::UTF8
    )

    $writtenJson = $writtenText | ConvertFrom-Json -Depth 24 -ErrorAction Stop

    if ([string]$writtenJson.inventorySha256 -ne $InventorySha256) {
        throw 'On-disk JSON validation failed: inventorySha256 mismatch.'
    }

    Move-Item `
        -LiteralPath $TemporaryLockFile `
        -Destination $LockFile `
        -Force
}
catch {
    if (Test-Path -LiteralPath $TemporaryLockFile) {
        Remove-Item `
            -LiteralPath $TemporaryLockFile `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Section 'FATAL · write error'
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host 'Could not safely write toolchain.lock.json.' -ForegroundColor Red
    exit 1
}

# ==============================================================================
# 18. FINAL REPORT
# ==============================================================================

Write-Section 'Inventory written successfully'

Write-Detected 'toolchain.lock.json' 'valid JSON written'
Write-Host "Output : toolchain.lock.json" -ForegroundColor DarkGray
Write-Host "SHA-256: $InventorySha256" -ForegroundColor DarkGray

Write-Host ''
Write-Host "Core tools detected         : $coreDetected / $($CoreTools.Count)"
Write-Host "Evergreen clients detected  : $evergreenDetected / $($EvergreenVendorClients.Count)"

if ($coreDetected -ne $CoreTools.Count) {
    Write-Host ''
    Write-Host 'Core tools currently missing/unusable:' -ForegroundColor Red

    foreach ($name in $coreMissingNames) {
        Write-Host "  - $name" -ForegroundColor Red
    }
}

if ($evergreenDetected -ne $EvergreenVendorClients.Count) {
    Write-Host ''
    Write-Host 'Evergreen vendor clients currently missing/unusable:' -ForegroundColor Red

    foreach ($name in $evergreenMissingNames) {
        Write-Host "  - $name" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host 'Missing tools are intentionally recorded in JSON and do not fail inventory.' `
    -ForegroundColor Yellow
Write-Host 'Exit code: 0' -ForegroundColor Green
exit 0
