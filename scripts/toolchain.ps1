#requires -Version 7.0
<#
AI MAINTENANCE RULES
- Add a tool as one focused Get-<Tool>Inventory function plus one collection-map entry; reuse existing helpers.
- Every tool record keeps installed/status/version/source/path/message. Detected without a version => installed=true, inventoryComplete=false.
- Probe only bounded sources: PATH, registry, AppX/MSIX, known install roots, running processes. Never scan whole drives.
- Missing tools are inventory data, not fatal errors. Never read secrets; normalize user paths; keep atomic JSON writes.
- Keep this file compact: no banners, duplicated probes, history/revision metadata, or explanatory comments unless required for safety/compatibility.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectDirectoryName = 'invoiceops-lab'

function Find-ProjectRoot {
    param([string]$StartDirectory, [string]$DirectoryName)
    $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($StartDirectory))
    while ($null -ne $current) {
        if ($current.Name -ieq $DirectoryName) { return $current.FullName.TrimEnd([char[]]@('\', '/')) }
        $current = $current.Parent
    }
    $null
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Write-Status {
    param([ValidateSet('OK', 'MISS', 'WARN')][string]$State, [string]$Name, [string]$Message)
    $color = switch ($State) { 'OK' { 'Green' } 'MISS' { 'Red' } default { 'Yellow' } }
    Write-Host ("[{0,-4}] {1,-24} {2}" -f $State, $Name, $Message) -ForegroundColor $color
}

function Find-Application {
    param([string]$Name)
    try { Get-Command -Name $Name -CommandType Application, ExternalScript -ErrorAction Stop | Select-Object -First 1 }
    catch { $null }
}

function Get-CommandPath {
    param($CommandInfo)
    if ($null -eq $CommandInfo) { return $null }
    foreach ($name in 'Source', 'Path', 'Definition') {
        $p = $CommandInfo.PSObject.Properties[$name]
        if ($null -ne $p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) { return [string]$p.Value }
    }
    [string]$CommandInfo.Name
}

function Invoke-NativeCapture {
    param([string]$FilePath, [string[]]$Arguments = @())
    try {
        $raw = & $FilePath @Arguments 2>&1
        $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        [pscustomobject]@{ success = ($code -eq 0); exitCode = $code; output = (($raw | ForEach-Object { $_.ToString() }) -join "`n" -replace "`0", '').Trim() }
    }
    catch { [pscustomobject]@{ success = $false; exitCode = -1; output = $_.Exception.Message } }
}

function Get-VersionToken {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    foreach ($pattern in @(
        '(?im)\bversion[:\s]+v?(?<version>\d+(?:\.\d+){1,5}(?:[-+._][0-9A-Za-z.-]+)?)',
        '(?im)\bv?(?<version>\d+(?:\.\d+){1,5}(?:[-+._][0-9A-Za-z.-]+)?)\b'
    )) {
        if ($Text -match $pattern) { return $Matches.version.Trim() }
    }
    $null
}

function Get-FileVersion {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        foreach ($candidate in @($v.ProductVersion, $v.FileVersion)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $parsed = Get-VersionToken ([string]$candidate)
                return $(if ($parsed) { $parsed } else { ([string]$candidate).Trim() })
            }
        }
    }
    catch { Write-Verbose "Version metadata failed for '$Path': $($_.Exception.Message)" }
    $null
}

function New-InventoryRecord {
    param(
        [bool]$Installed,
        [string]$Status,
        [AllowNull()][string]$Version,
        [string]$Source,
        [AllowNull()][string]$Path,
        [AllowNull()][string]$Message,
        [AllowNull()][System.Collections.IDictionary]$Extra
    )
    $r = [ordered]@{ installed = $Installed; status = $Status; version = $Version; source = $Source; path = $Path; message = $Message }
    if ($null -ne $Extra) { foreach ($key in $Extra.Keys) { $r[$key] = $Extra[$key] } }
    $r
}

function New-MissingRecord {
    param([string]$Message, [string]$Source = 'not-detected', [AllowNull()][string]$Path = $null)
    New-InventoryRecord $false 'missing' $null $Source $Path $Message $null
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    $p.Value
}

function Get-UninstallEntries {
    param([string]$DisplayNamePattern)
    $out = @()
    foreach ($path in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        try {
            $out += @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object {
                $name = [string](Get-PropertyValue $_ 'DisplayName')
                -not [string]::IsNullOrWhiteSpace($name) -and $name -match $DisplayNamePattern
            })
        }
        catch { Write-Verbose "Registry probe failed at '$path': $($_.Exception.Message)" }
    }
    @($out)
}

function Get-AppxMatch {
    param([string]$Name, [string]$Pattern)
    try {
        $p = Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        if ($p) { return $p }
    }
    catch { Write-Verbose "AppX '$Name' probe failed: $($_.Exception.Message)" }
    try {
        Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
            [string]$_.Name -match $Pattern -or [string]$_.PackageFamilyName -match $Pattern
        } | Sort-Object Version -Descending | Select-Object -First 1
    }
    catch { Write-Verbose "AppX fallback '$Pattern' probe failed: $($_.Exception.Message)"; $null }
}

function Get-DisplayIconExecutable {
    param([AllowNull()][string]$Value, [string]$ExePattern = '.+?\.exe')
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $m = [regex]::Match($Value, '^\s*"(?<path>[^\"]+\.exe)"|^(?<path2>' + $ExePattern + ')(?:,|\s|$)', 'IgnoreCase')
    if ($m.Groups['path'].Success) { return $m.Groups['path'].Value }
    if ($m.Groups['path2'].Success) { return $m.Groups['path2'].Value }
    $null
}

function Get-FirstExistingFile {
    param([string[]]$Paths)
    $Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction SilentlyContinue) } | Select-Object -First 1
}

function Test-InventoryRecordComplete {
    param($Record)
    if ($null -eq $Record -or -not ($Record -is [System.Collections.IDictionary])) { return $false }
    if ($Record.Contains('inventoryComplete')) { return [bool]$Record.inventoryComplete }
    $Record.Contains('installed') -and [bool]$Record.installed -and $Record.Contains('version') -and -not [string]::IsNullOrWhiteSpace([string]$Record.version)
}

function Protect-JsonUserPaths {
    param([string]$Json)
    $items = @(
        @{ value = $env:LOCALAPPDATA; token = '%LOCALAPPDATA%' },
        @{ value = $env:APPDATA; token = '%APPDATA%' },
        @{ value = $env:USERPROFILE; token = '%USERPROFILE%' },
        @{ value = $HOME; token = '%HOME%' }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.value) }
    $seen = @{}
    $items = foreach ($item in $items) {
        try { $full = [IO.Path]::GetFullPath([string]$item.value).TrimEnd([char[]]@('\', '/')) } catch { continue }
        $key = $full.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; [pscustomobject]@{ value = $full; token = $item.token } }
    }
    $result = $Json
    foreach ($item in @($items | Sort-Object { $_.value.Length } -Descending)) {
        $escaped = ([string]$item.value).Replace('\', '\\')
        $result = [regex]::Replace($result, [regex]::Escape($escaped), [string]$item.token, 'IgnoreCase')
    }
    $result
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-HostInventory {
    $name = [Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim()
    $version = [Environment]::OSVersion.Version.ToString()
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os.Caption) { $name = [string]$os.Caption }
        if ($os.Version) { $version = [string]$os.Version }
    }
    catch { Write-Verbose "OS probe failed: $($_.Exception.Message)" }
    [ordered]@{
        operatingSystem = $name
        osVersion = $version
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powerShell = [ordered]@{
            installed = $true
            status = 'detected'
            version = $PSVersionTable.PSVersion.ToString()
            edition = [string]$PSVersionTable.PSEdition
            path = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        }
    }
}

function Get-WslInventory {
    $cmd = Find-Application 'wsl.exe'
    if (-not $cmd) {
        return [ordered]@{ installed = $false; status = 'missing'; version = $null; path = $null; distributions = @(); preferredDistro = $null; statusCommandPassed = $false; message = 'wsl.exe was not found.' }
    }
    $path = Get-CommandPath $cmd
    $vp = Invoke-NativeCapture $path @('--version')
    $sp = Invoke-NativeCapture $path @('--status')
    $lp = Invoke-NativeCapture $path @('-l', '-q')
    $distros = if ($lp.success) { @((($lp.output -replace "`0", '') -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
    $preferred = if ($distros -contains 'Ubuntu-24.04') { 'Ubuntu-24.04' } else { $distros | Where-Object { $_ -match '(?i)ubuntu' } | Select-Object -First 1 }
    if (-not $preferred -and $distros.Count) { $preferred = $distros[0] }
    [ordered]@{ installed = $true; status = 'detected'; version = $(if ($vp.success) { Get-VersionToken $vp.output } else { $null }); path = $path; distributions = @($distros); preferredDistro = $preferred; statusCommandPassed = [bool]$sp.success; message = $null }
}

function Get-CliInventory {
    param(
        [string]$DisplayName,
        [string]$CommandName,
        [string[]]$VersionArguments = @('--version'),
        [AllowNull()][string]$VersionRegex = $null,
        [ValidateSet('core', 'supplemental')][string]$Importance = 'core'
    )
    $cmd = Find-Application $CommandName
    $state = if ($Importance -eq 'core') { 'MISS' } else { 'WARN' }
    if (-not $cmd) {
        $m = "'$CommandName' was not found in Windows PATH."
        Write-Status $state $DisplayName $m
        return New-MissingRecord $m
    }
    $path = Get-CommandPath $cmd
    $probe = Invoke-NativeCapture $path $VersionArguments
    if (-not $probe.success) {
        $m = "'$CommandName' exists, but its version probe failed with exit code $($probe.exitCode)."
        Write-Status $state $DisplayName $m
        return New-InventoryRecord $false 'unusable' $null 'windows-path' $path $m $null
    }
    $version = if ($VersionRegex -and $probe.output -match $VersionRegex) { $Matches.version } else { Get-VersionToken $probe.output }
    if (-not $version) {
        $m = "'$CommandName' responded, but its version could not be parsed."
        Write-Status $state $DisplayName $m
        return New-InventoryRecord $false 'unusable' $null 'windows-path' $path $m $null
    }
    Write-Status OK $DisplayName $version
    New-InventoryRecord $true 'detected' $version 'windows-path' $path $null $null
}

function Get-PacInventory {
    $cmd = Find-Application 'pac'
    if (-not $cmd) { $m = "'pac' was not found in Windows PATH."; Write-Status MISS pac $m; return New-MissingRecord $m }
    $path = Get-CommandPath $cmd
    $version = $null; $method = $null
    foreach ($p in @(@{ a = @(); m = 'pac' }, @{ a = @('--version'); m = 'pac --version' })) {
        $probe = Invoke-NativeCapture $path $p.a
        if ($probe.success) { $version = Get-VersionToken $probe.output }
        if ($version) { $method = $p.m; break }
    }
    if (-not $version) { $version = Get-FileVersion $path; if ($version) { $method = 'executable metadata' } }
    if (-not $version) { $m = 'PAC CLI was detected, but its version could not be determined.'; Write-Status MISS pac $m; return New-InventoryRecord $false 'unusable' $null 'windows-path' $path $m $null }
    Write-Status OK pac "$version ($method)"
    New-InventoryRecord $true 'detected' $version 'windows-path' $path $null @{ versionMethod = $method }
}

function Get-DockerComposeVersion {
    param([string]$DockerPath, [AllowNull()][string]$WslPath, [AllowNull()][string]$Distribution)
    if ($WslPath) {
        foreach ($command in 'docker compose version --short', 'docker compose version') {
            $p = Invoke-NativeCapture $WslPath @('-d', $Distribution, '--', 'bash', '-lc', $command)
            if ($p.success) { $v = if ($command -like '*--short') { $p.output.Trim().TrimStart('v') } else { Get-VersionToken $p.output }; if ($v) { return $v } }
        }
        return $null
    }
    foreach ($a in @(@('compose', 'version', '--short'), @('compose', 'version'))) {
        $p = Invoke-NativeCapture $DockerPath $a
        if ($p.success) { $v = if ($a -contains '--short') { $p.output.Trim().TrimStart('v') } else { Get-VersionToken $p.output }; if ($v) { return $v } }
    }
    $null
}

function Get-DockerInventory {
    param($WslInventory)
    $cmd = Find-Application 'docker'
    if ($cmd) {
        $path = Get-CommandPath $cmd; $p = Invoke-NativeCapture $path @('--version'); $version = if ($p.success) { Get-VersionToken $p.output } else { $null }
        if ($version) {
            $compose = Get-DockerComposeVersion $path $null $null
            Write-Status OK docker "$version (Windows PATH)"
            if ($compose) { Write-Status OK 'docker compose' $compose } else { Write-Status WARN 'docker compose' 'version not detected' }
            return New-InventoryRecord $true 'detected' $version 'windows-path' $path $null @{ distribution = $null; composeVersion = $compose }
        }
        Write-Status WARN docker 'Windows command is unusable; trying WSL.'
    }
    if (-not $WslInventory.installed -or [string]::IsNullOrWhiteSpace([string]$WslInventory.preferredDistro)) {
        $m = 'Docker was not found in Windows PATH and no usable WSL distribution is available.'; Write-Status MISS docker $m; return New-MissingRecord $m
    }
    $d = [string]$WslInventory.preferredDistro; $wsl = [string]$WslInventory.path
    $pp = Invoke-NativeCapture $wsl @('-d', $d, '--', 'bash', '-lc', 'command -v docker')
    if (-not $pp.success -or -not $pp.output) { $m = "Docker was not found in Windows PATH or WSL '$d'."; Write-Status MISS docker $m; return New-MissingRecord $m }
    $vp = Invoke-NativeCapture $wsl @('-d', $d, '--', 'bash', '-lc', 'docker --version')
    $version = if ($vp.success) { Get-VersionToken $vp.output } else { $null }
    if (-not $version) { $m = "Docker exists in WSL '$d', but its version could not be read."; Write-Status MISS docker $m; return New-InventoryRecord $false 'unusable' $null 'wsl' $pp.output.Trim() $m $null }
    $compose = Get-DockerComposeVersion $null $wsl $d
    Write-Status OK docker "$version (WSL: $d)"
    if ($compose) { Write-Status OK 'docker compose' $compose } else { Write-Status WARN 'docker compose' "version not detected in WSL '$d'" }
    New-InventoryRecord $true 'detected' $version 'wsl' $pp.output.Trim() $null @{ distribution = $d; composeVersion = $compose }
}

function Get-PadInventory {
    $reg = @(Get-UninstallEntries '(?i)^(Microsoft )?Power Automate for desktop$')
    $paths = @()
    if (${env:ProgramFiles(x86)}) { $paths += Join-Path ${env:ProgramFiles(x86)} 'Power Automate Desktop\dotnet\PAD.Console.Host.exe' }
    if ($env:ProgramFiles) { $paths += Join-Path $env:ProgramFiles 'Power Automate Desktop\dotnet\PAD.Console.Host.exe' }
    $exe = Get-FirstExistingFile $paths
    $entry = $reg | Sort-Object DisplayVersion -Descending | Select-Object -First 1
    $directVersion = [string](Get-PropertyValue $entry 'DisplayVersion'); if (-not $directVersion -and $exe) { $directVersion = Get-FileVersion $exe }
    $store = Get-AppxMatch 'Microsoft.PowerAutomateDesktop' '(?i)PowerAutomate'
    $hasDirect = $reg.Count -gt 0 -or $exe; $hasStore = $null -ne $store
    if ($hasDirect -and $hasStore) {
        $m = 'Both MSI and Microsoft Store/MSIX PAD installations were detected.'; Write-Status WARN PAD $m
        return New-InventoryRecord $true 'detected-with-warning' $(if ($directVersion) { $directVersion } else { [string]$store.Version }) 'multiple-installations' $exe $m @{
            inventoryComplete = (-not [string]::IsNullOrWhiteSpace($directVersion) -and -not [string]::IsNullOrWhiteSpace([string]$store.Version)); installType = 'multiple'
            installations = @(
                [ordered]@{ type = 'msi'; version = $directVersion; path = $exe; displayName = [string](Get-PropertyValue $entry 'DisplayName') },
                [ordered]@{ type = 'msix'; version = [string]$store.Version; path = [string]$store.InstallLocation; packageName = [string]$store.Name }
            )
        }
    }
    if ($hasDirect) {
        if (-not $directVersion) { $m = 'PAD MSI installation was detected, but its version is unknown.'; Write-Status WARN PAD $m; return New-InventoryRecord $true 'detected-version-unknown' $null 'msi' $exe $m @{ inventoryComplete = $false; installType = 'msi' } }
        Write-Status OK PAD "$directVersion (MSI)"
        return New-InventoryRecord $true 'detected' $directVersion 'msi' $exe $null @{ installType = 'msi'; displayName = [string](Get-PropertyValue $entry 'DisplayName'); packageName = $null }
    }
    if ($hasStore) {
        $v = [string]$store.Version
        if (-not $v) { $m = 'PAD Store/MSIX installation was detected, but its version is unknown.'; Write-Status WARN PAD $m; return New-InventoryRecord $true 'detected-version-unknown' $null 'msix' ([string]$store.InstallLocation) $m @{ inventoryComplete = $false; installType = 'msix' } }
        Write-Status OK PAD "$v (Store/MSIX)"
        return New-InventoryRecord $true 'detected' $v 'msix' ([string]$store.InstallLocation) $null @{ installType = 'msix'; displayName = 'Power Automate'; packageName = [string]$store.Name }
    }
    $m = 'Power Automate for desktop was not detected.'; Write-Status MISS PAD $m; New-MissingRecord $m
}

function Get-PowerBiDesktopInventory {
    $reg = @(Get-UninstallEntries '(?i)^(Microsoft )?Power BI Desktop\b' | Where-Object { [string](Get-PropertyValue $_ 'DisplayName') -notmatch '(?i)Report Server' })
    $store = Get-AppxMatch 'Microsoft.MicrosoftPowerBIDesktop' '(?i)PowerBIDesktop'
    $storeRoot = if ($store) { [string]$store.InstallLocation } else { $null }
    if (-not $storeRoot -and $env:ProgramFiles) {
        try {
            $storeDir = Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'WindowsApps') -Directory -Filter 'Microsoft.MicrosoftPowerBIDesktop_*__8wekyb3d8bbwe' -ErrorAction Stop |
                Where-Object { $_.Name -match '^Microsoft\.MicrosoftPowerBIDesktop_\d+(?:\.\d+){1,3}_(?:x64|x86|arm64)__8wekyb3d8bbwe$' } |
                Sort-Object { [version](($_.Name -split '_')[1]) } -Descending | Select-Object -First 1
            if ($storeDir) { $storeRoot = $storeDir.FullName }
        }
        catch {}
    }
    $isStorePath = {
        param([string]$Path)
        if (-not $Path) { return $false }
        if ($Path -match '(?i)[\\/]WindowsApps[\\/]') { return $true }
        if (-not $storeRoot) { return $false }
        try {
            $p = [IO.Path]::GetFullPath($Path); $r = [IO.Path]::GetFullPath($storeRoot).TrimEnd([char[]]@('\', '/'))
            $p -ieq $r -or $p.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
        }
        catch { $false }
    }
    $candidates = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([AllowNull()][string]$Path, [string]$Source)
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) { return }
        try { $full = [IO.Path]::GetFullPath($Path) } catch { return }
        if ([IO.Path]::GetFileName($full) -ine 'PBIDesktop.exe' -or (& $isStorePath $full)) { return }
        if (-not ($candidates | Where-Object { $_.path -ieq $full })) { $candidates.Add([pscustomobject]@{ path = $full; source = $Source }) }
    }
    $storeProcessExe = $null
    try {
        foreach ($p in @(Get-Process PBIDesktop -ErrorAction SilentlyContinue)) {
            try {
                $processPath = [string]$p.Path
                if (& $isStorePath $processPath) { if (-not $storeProcessExe) { $storeProcessExe = $processPath } }
                else { & $add $processPath 'running process' }
            }
            catch {}
        }
    }
    catch {}
    foreach ($entry in $reg) {
        $name = [string](Get-PropertyValue $entry 'DisplayName'); $loc = [string](Get-PropertyValue $entry 'InstallLocation')
        if ($loc) { & $add (Join-Path $loc 'bin\PBIDesktop.exe') "registry InstallLocation: $name"; & $add (Join-Path $loc 'PBIDesktop.exe') "registry InstallLocation: $name" }
        & $add (Get-DisplayIconExecutable ([string](Get-PropertyValue $entry 'DisplayIcon')) '.+?PBIDesktop\.exe') "registry DisplayIcon: $name"
    }
    if ($env:ProgramFiles) { & $add (Join-Path $env:ProgramFiles 'Microsoft Power BI Desktop\bin\PBIDesktop.exe') 'known install root' }
    if (${env:ProgramFiles(x86)}) { & $add (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Power BI Desktop\bin\PBIDesktop.exe') 'known x86 install root' }
    $direct = $candidates | Select-Object -First 1; $entry = $reg | Sort-Object DisplayVersion -Descending | Select-Object -First 1
    $directPath = if ($direct) { [string]$direct.path } else { [string](Get-PropertyValue $entry 'InstallLocation') }
    $directVersion = if ($direct) { Get-FileVersion $direct.path } else { $null }; $directMethod = if ($directVersion) { 'PBIDesktop.exe metadata' } else { $null }
    if (-not $directVersion) { $directVersion = [string](Get-PropertyValue $entry 'DisplayVersion'); if ($directVersion) { $directMethod = 'Windows uninstall registry' } }
    $storeExe = $storeProcessExe
    if (-not $storeExe -and $storeRoot) { $storeExe = Get-FirstExistingFile @((Join-Path $storeRoot 'bin\PBIDesktop.exe'), (Join-Path $storeRoot 'PBIDesktop.exe')) }
    $storeVersion = if ($storeExe) { Get-FileVersion $storeExe } else { $null }; $storeMethod = if ($storeVersion) { 'PBIDesktop.exe metadata' } else { $null }
    if (-not $storeVersion -and $store) { $storeVersion = [string]$store.Version; if ($storeVersion) { $storeMethod = 'Microsoft Store package' } }
    if (-not $storeVersion -and $storeRoot -and $storeRoot -match '(?i)Microsoft\.MicrosoftPowerBIDesktop_(?<v>\d+(?:\.\d+){1,3})_') { $storeVersion = $Matches.v; $storeMethod = 'WindowsApps package directory' }
    $hasDirect = $reg.Count -gt 0 -or $direct; $hasStore = $null -ne $store -or $storeExe -or $storeRoot
    if ($hasDirect -and $hasStore) {
        $m = 'Both direct and Microsoft Store/MSIX Power BI Desktop installations were detected.'; Write-Status WARN 'Power BI Desktop' $m
        return New-InventoryRecord $true 'detected-with-warning' $(if ($directVersion) { $directVersion } else { $storeVersion }) 'multiple-installations' $directPath $m @{
            inventoryComplete = (-not [string]::IsNullOrWhiteSpace($directVersion) -and -not [string]::IsNullOrWhiteSpace($storeVersion)); installType = 'multiple'
            installations = @(
                [ordered]@{ type = 'direct'; version = $directVersion; path = $directPath; displayName = [string](Get-PropertyValue $entry 'DisplayName'); versionMethod = $directMethod; discoverySource = $(if ($direct) { $direct.source } else { $null }) },
                [ordered]@{ type = 'msix'; version = $storeVersion; path = $(if ($storeExe) { $storeExe } else { $storeRoot }); packageName = $(if ($store) { [string]$store.Name } else { 'Microsoft.MicrosoftPowerBIDesktop' }); versionMethod = $storeMethod }
            )
        }
    }
    if ($hasDirect) {
        $path = $directPath
        if (-not $directVersion) { $m = 'Power BI Desktop direct installation was detected, but its version is unknown.'; Write-Status WARN 'Power BI Desktop' $m; return New-InventoryRecord $true 'detected-version-unknown' $null 'direct-installation' $path $m @{ inventoryComplete = $false; installType = 'direct' } }
        Write-Status OK 'Power BI Desktop' "$directVersion (direct)"
        return New-InventoryRecord $true 'detected' $directVersion 'direct-installation' $path $null @{ installType = 'direct'; displayName = [string](Get-PropertyValue $entry 'DisplayName'); versionMethod = $directMethod; discoverySource = $(if ($direct) { $direct.source } else { $null }) }
    }
    if ($hasStore) {
        $path = if ($storeExe) { $storeExe } else { $storeRoot }
        if (-not $storeVersion) { $m = 'Power BI Desktop Store/MSIX installation was detected, but its version is unknown.'; Write-Status WARN 'Power BI Desktop' $m; return New-InventoryRecord $true 'detected-version-unknown' $null 'msix' $path $m @{ inventoryComplete = $false; installType = 'msix' } }
        Write-Status OK 'Power BI Desktop' "$storeVersion (Store/MSIX)"
        return New-InventoryRecord $true 'detected' $storeVersion 'msix' $path $null @{ installType = 'msix'; packageName = $(if ($store) { [string]$store.Name } else { 'Microsoft.MicrosoftPowerBIDesktop' }); versionMethod = $storeMethod }
    }
    $m = 'Power BI Desktop was not detected.'; Write-Status MISS 'Power BI Desktop' $m; New-MissingRecord $m
}

function Get-UiPathRole {
    param([string]$Path)
    switch -Regex ([IO.Path]::GetFileName($Path)) {
        '^UiPath\.Studio\.exe$' { 'studio'; break }
        '^UiPath\.Studio\.CommandLine\.exe$' { 'studioCommandLine'; break }
        '^UiPath\.Assistant\.exe$' { 'assistant'; break }
        '^UiRobot\.exe$' { 'robot'; break }
        '^UiPath\.Connected\.Updater\.App\.exe$' { 'updater'; break }
        default { $null }
    }
}

function Get-UiPathPathVersion {
    param([string]$Path)
    $parts = @($Path -split '[\\/]+' | Where-Object { $_ })
    $seen = $false
    foreach ($part in $parts) {
        if ($part -ieq 'UiPathPlatform') { $seen = $true; continue }
        if ($seen -and $part -match '^(?<version>\d+(?:\.\d+){1,5}(?:[-+._][0-9A-Za-z][0-9A-Za-z._-]*)?)$') { return $Matches.version }
    }
    $null
}

function Get-UiPathCandidate {
    param([string]$Path, [string]$Source)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) { return $null }
    try { $full = [IO.Path]::GetFullPath($Path); $role = Get-UiPathRole $full; if (-not $role) { return $null } } catch { return $null }
    $version = Get-UiPathPathVersion $full; $method = if ($version) { 'UiPathPlatform install directory' } else { $null }
    if (-not $version) { $version = Get-FileVersion $full; if ($version) { $method = 'executable metadata' } }
    [pscustomobject]@{ role = $role; path = $full; version = $version; versionMethod = $method; discoverySource = $Source; lastWriteTimeUtc = (Get-Item -LiteralPath $full).LastWriteTimeUtc }
}

function Select-UiPathCandidate {
    param([object[]]$Candidates, [string[]]$Roles)
    @($Candidates | Where-Object { $_.role -in $Roles }) | Sort-Object @{ Expression = { $i = [array]::IndexOf($Roles, [string]$_.role); if ($i -lt 0) { 0 } else { 100 - $i } }; Descending = $true }, @{ Expression = { if ($_.version) { 1 } else { 0 } }; Descending = $true }, @{ Expression = { if ($_.path -match '(?i)[\\/]UiPathPlatform[\\/]') { 1 } else { 0 } }; Descending = $true }, @{ Expression = 'lastWriteTimeUtc'; Descending = $true } | Select-Object -First 1
}

function Get-UiPathRegistryVersion {
    param([object[]]$Entries, [string]$Pattern)
    $e = $Entries | Where-Object { [string](Get-PropertyValue $_ 'DisplayName') -match $Pattern -and [string](Get-PropertyValue $_ 'DisplayVersion') } | Select-Object -First 1
    if ($e) { [pscustomobject]@{ version = ([string](Get-PropertyValue $e 'DisplayVersion')).Trim(); displayName = [string](Get-PropertyValue $e 'DisplayName'); method = 'Windows uninstall registry' } }
}

function Get-UiPathInventory {
    $reg = @(Get-UninstallEntries '(?i)UiPath')
    $roots = [ordered]@{}; $map = [ordered]@{}
    $addRoot = {
        param([string]$Path, [string]$Source)
        if (-not $Path) { return }
        try { $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/')) } catch { return }
        if (Test-Path -LiteralPath $full -PathType Container -ErrorAction SilentlyContinue) { $key = $full.ToLowerInvariant(); if (-not $roots.Contains($key)) { $roots[$key] = [pscustomobject]@{ path = $full; source = $Source } } }
    }
    $addCandidate = {
        param([string]$Path, [string]$Source)
        $c = Get-UiPathCandidate $Path $Source
        if ($c) { $key = $c.path.ToLowerInvariant(); if (-not $map.Contains($key)) { $map[$key] = $c } }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { & $addRoot (Join-Path $base 'UiPathPlatform') 'known root'; & $addRoot (Join-Path $base 'UiPath') 'known root' }
    }
    if ($env:LOCALAPPDATA) { foreach ($rel in 'Programs\UiPathPlatform', 'Programs\UiPath', 'UiPathPlatform', 'UiPath') { & $addRoot (Join-Path $env:LOCALAPPDATA $rel) 'known per-user root' } }
    if ($env:ProgramData) { & $addRoot (Join-Path $env:ProgramData 'UiPath') 'known ProgramData root' }
    foreach ($entry in $reg) {
        $name = [string](Get-PropertyValue $entry 'DisplayName'); $loc = [string](Get-PropertyValue $entry 'InstallLocation'); if ($loc) { & $addRoot $loc "registry: $name" }
        foreach ($prop in 'DisplayIcon', 'UninstallString', 'QuietUninstallString') {
            $path = Get-DisplayIconExecutable ([string](Get-PropertyValue $entry $prop))
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
                $role = Get-UiPathRole $path
                if ($role -or $path -match '(?i)[\\/]UiPath(?:Platform)?[\\/]') { & $addRoot (Split-Path $path -Parent) "registry ${prop}: $name" }
                if ($role) { & $addCandidate $path "registry ${prop}: $name" }
            }
        }
    }
    $exeNames = @('UiPath.Studio.exe', 'UiPath.Studio.CommandLine.exe', 'UiPath.Assistant.exe', 'UiRobot.exe', 'UiPath.Connected.Updater.App.exe')
    foreach ($exe in $exeNames) {
        foreach ($rp in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$exe", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe")) {
            try { $key = Get-Item -LiteralPath $rp -ErrorAction Stop; $path = [string]$key.GetValue(''); if ($path) { & $addCandidate $path 'Windows App Paths'; & $addRoot (Split-Path $path -Parent) 'Windows App Paths' } } catch {}
        }
    }
    foreach ($processName in 'UiPath.Studio', 'UiPath.Assistant', 'UiRobot', 'UiPath.Executor') {
        try { foreach ($p in @(Get-Process $processName -ErrorAction SilentlyContinue)) { try { if ($p.Path) { & $addCandidate ([string]$p.Path) 'running process'; & $addRoot (Split-Path ([string]$p.Path) -Parent) 'running process' } } catch {} } } catch {}
    }
    $shortcutRoots = @()
    if ($env:APPDATA) { $shortcutRoots += Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
    if ($env:ProgramData) { $shortcutRoots += Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs' }
    try {
        $shell = New-Object -ComObject WScript.Shell
        try {
            foreach ($root in $shortcutRoots | Where-Object { Test-Path -LiteralPath $_ -PathType Container -ErrorAction SilentlyContinue }) {
                foreach ($lnk in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)UiPath' })) {
                    try { $path = [string]$shell.CreateShortcut($lnk.FullName).TargetPath; if ($path) { & $addCandidate $path 'Start Menu shortcut'; & $addRoot (Split-Path $path -Parent) 'Start Menu shortcut' } } catch {}
                }
            }
        }
        finally { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch {} }
    }
    catch { Write-Verbose "UiPath shortcut probe unavailable: $($_.Exception.Message)" }
    foreach ($root in @($roots.Values)) {
        foreach ($exe in $exeNames) {
            try { foreach ($f in @(Get-ChildItem -LiteralPath $root.path -Filter $exe -File -Recurse -ErrorAction SilentlyContinue)) { & $addCandidate $f.FullName "filesystem: $($root.source)" } } catch {}
        }
    }
    $all = @($map.Values)
    $studio = Select-UiPathCandidate $all @('studio', 'studioCommandLine'); $assistant = Select-UiPathCandidate $all @('assistant'); $robot = Select-UiPathCandidate $all @('robot'); $updater = Select-UiPathCandidate $all @('updater')
    $studioReg = Get-UiPathRegistryVersion $reg '(?i)UiPath.*Studio|Studio.*UiPath'; $assistantReg = Get-UiPathRegistryVersion $reg '(?i)UiPath.*Assistant|Assistant.*UiPath'; $platformReg = Get-UiPathRegistryVersion $reg '(?i)^UiPath\s+Platform(?:\s.*)?$|UiPath.*Platform.*Installer'
    $studioInstalled = $null -ne $studio -or $null -ne $studioReg; $assistantInstalled = $null -ne $assistant -or $null -ne $assistantReg
    $studioVersion = if ($studio -and $studio.version) { [string]$studio.version } elseif ($studioReg) { [string]$studioReg.version } elseif ($studioInstalled -and $platformReg) { [string]$platformReg.version } else { $null }
    $studioMethod = if ($studio -and $studio.version) { [string]$studio.versionMethod } elseif ($studioReg) { $studioReg.method } elseif ($studioInstalled -and $platformReg) { 'UiPath Platform uninstall registry' } else { $null }
    $assistantVersion = if ($assistant -and $assistant.version) { [string]$assistant.version } elseif ($assistantReg) { [string]$assistantReg.version } else { $null }
    $assistantMethod = if ($assistant -and $assistant.version) { [string]$assistant.versionMethod } elseif ($assistantReg) { $assistantReg.method } else { $null }
    $anything = $studioInstalled -or $assistantInstalled -or $robot -or $updater -or $reg.Count
    if (-not $anything) {
        $m = 'UiPath Studio/Assistant was not detected.'; Write-Status MISS UiPath $m
        return New-InventoryRecord $false 'missing' $null 'not-detected' $null $m @{ inventoryComplete = $false; studio = [ordered]@{ installed = $false; version = $null; path = $null }; assistant = [ordered]@{ installed = $false; version = $null; path = $null } }
    }
    $source = if (($studio -and $studio.path -match '(?i)[\\/]UiPathPlatform[\\/]') -or ($assistant -and $assistant.path -match '(?i)[\\/]UiPathPlatform[\\/]') -or $updater -or $platformReg) { 'uipath-platform-installer' } else { 'windows-installation' }
    if (-not $studioInstalled) {
        $m = 'UiPath components were detected, but Studio was not found.'; Write-Status WARN 'UiPath Studio' $m
        return New-InventoryRecord $false 'studio-missing' $null $source $null $m @{ inventoryComplete = $false; studio = [ordered]@{ installed = $false; version = $null; path = $null }; assistant = [ordered]@{ installed = $assistantInstalled; version = $assistantVersion; path = $(if ($assistant) { $assistant.path } else { $null }); versionMethod = $assistantMethod } }
    }
    if (-not $studioVersion) {
        $m = 'UiPath Studio was found, but its version is unknown.'; Write-Status WARN 'UiPath Studio' $m
        return New-InventoryRecord $true 'detected-version-unknown' $null $source $(if ($studio) { $studio.path } else { $null }) $m @{ inventoryComplete = $false; studio = [ordered]@{ installed = $true; version = $null; path = $(if ($studio) { $studio.path } else { $null }) }; assistant = [ordered]@{ installed = $assistantInstalled; version = $assistantVersion; path = $(if ($assistant) { $assistant.path } else { $null }) } }
    }
    Write-Status OK 'UiPath Studio' "$studioVersion ($studioMethod)"
    if ($assistantInstalled -and $assistantVersion) { Write-Status OK 'UiPath Assistant' "$assistantVersion ($assistantMethod)" } elseif ($assistantInstalled) { Write-Status WARN 'UiPath Assistant' 'version unknown' } else { Write-Status WARN 'UiPath Assistant' 'not found' }
    $complete = $studioInstalled -and $studioVersion -and $assistantInstalled -and $assistantVersion
    New-InventoryRecord $true $(if ($complete) { 'detected' } else { 'detected-partial' }) $studioVersion $source $(if ($studio) { $studio.path } else { $null }) $(if ($complete) { $null } elseif (-not $assistantInstalled) { 'UiPath Assistant is missing.' } else { 'UiPath Assistant version is unknown.' }) @{
        inventoryComplete = [bool]$complete
        studio = [ordered]@{ installed = $studioInstalled; version = $studioVersion; path = $(if ($studio) { $studio.path } else { $null }); versionMethod = $studioMethod; discoverySource = $(if ($studio) { $studio.discoverySource } else { $null }) }
        assistant = [ordered]@{ installed = $assistantInstalled; version = $assistantVersion; path = $(if ($assistant) { $assistant.path } else { $null }); versionMethod = $assistantMethod; discoverySource = $(if ($assistant) { $assistant.discoverySource } else { $null }) }
        robot = [ordered]@{ installed = ($null -ne $robot); version = $(if ($robot) { $robot.version } else { $null }); path = $(if ($robot) { $robot.path } else { $null }) }
        updater = [ordered]@{ installed = ($null -ne $updater); version = $(if ($updater) { $updater.version } else { $null }); path = $(if ($updater) { $updater.path } else { $null }) }
        detection = [ordered]@{ registryEntryCount = $reg.Count; searchRootCount = $roots.Count; executableCount = $all.Count }
    }
}

function Get-AutomationAnywhereInventory {
    $reg = @(Get-UninstallEntries '(?i)Automation Anywhere.*Bot Agent|Automation 360.*Bot Agent')
    $dirs = @()
    if ($env:ProgramFiles) { $dirs += Join-Path $env:ProgramFiles 'Automation Anywhere\Bot Agent' }
    if ($env:LOCALAPPDATA) { $dirs += Join-Path $env:LOCALAPPDATA 'Programs\Automation Anywhere\Bot Agent' }
    $dir = $dirs | Where-Object { Test-Path -LiteralPath $_ -PathType Container -ErrorAction SilentlyContinue } | Select-Object -First 1
    $entry = $reg | Sort-Object DisplayVersion -Descending | Select-Object -First 1
    $version = [string](Get-PropertyValue $entry 'DisplayVersion'); $method = if ($version) { 'Windows uninstall registry' } else { $null }; $versionExe = $null
    if ($dir -and -not $version) { $versionExe = Get-FirstExistingFile @(('NodeManager.exe', 'AADiagnosticUtility.exe', 'BotLauncher.exe') | ForEach-Object { Join-Path $dir $_ }); if ($versionExe) { $version = Get-FileVersion $versionExe; if ($version) { $method = 'Bot Agent executable metadata' } } }
    if (-not ($reg.Count -or $dir)) { $m = 'Automation Anywhere Bot Agent was not detected.'; Write-Status MISS 'Automation Anywhere' $m; return New-InventoryRecord $false 'missing' $null 'not-detected' $null $m @{ inventoryComplete = $false } }
    if (-not $version) { $m = 'Automation Anywhere Bot Agent was detected, but its version is unknown.'; Write-Status WARN 'Automation Anywhere' $m; return New-InventoryRecord $true 'detected-version-unknown' $null 'windows-installation' $dir $m @{ inventoryComplete = $false; displayName = [string](Get-PropertyValue $entry 'DisplayName') } }
    Write-Status OK 'Automation Anywhere' "$version ($method)"
    New-InventoryRecord $true 'detected' $version 'windows-installation' $dir $null @{ inventoryComplete = $true; displayName = [string](Get-PropertyValue $entry 'DisplayName'); versionMethod = $method; versionExecutable = $versionExe }
}

function Get-CoverageSummary {
    param([System.Collections.IDictionary]$Map)
    $missing = @($Map.GetEnumerator() | Where-Object { -not (Test-InventoryRecordComplete $_.Value) } | ForEach-Object { [string]$_.Key })
    [ordered]@{ expectedCount = $Map.Count; detectedCount = $Map.Count - $missing.Count; missingOrUnusableCount = $missing.Count; missingOrUnusableTools = $missing; complete = ($missing.Count -eq 0) }
}

function Show-FinalSummary {
    param([string]$Message, $CoreSummary, $VendorSummary)
    Write-Section 'Inventory complete'
    Write-Status OK 'toolchain.lock.json' $Message
    Write-Host "Core tools detected        : $($CoreSummary.detectedCount) / $($CoreSummary.expectedCount)"
    Write-Host "Evergreen clients detected : $($VendorSummary.detectedCount) / $($VendorSummary.expectedCount)"
    foreach ($label in 'Core', 'Evergreen') {
        $summary = if ($label -eq 'Core') { $CoreSummary } else { $VendorSummary }
        if (-not $summary.complete) { Write-Host "$label missing/unusable: $($summary.missingOrUnusableTools -join ', ')" -ForegroundColor Yellow }
    }
}

$ScriptDirectory = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([char[]]@('\', '/'))
$RepoRoot = Find-ProjectRoot $ScriptDirectory $ProjectDirectoryName
if (-not $RepoRoot) { Write-Host "FATAL: parent directory '$ProjectDirectoryName' not found." -ForegroundColor Red; exit 2 }
$ProjectName = Split-Path $RepoRoot -Leaf
$LockFile = Join-Path $RepoRoot 'toolchain.lock.json'
$TempFile = "$LockFile.tmp-$PID"
Set-Location -LiteralPath $RepoRoot

Write-Section 'InvoiceOps toolchain inventory'
Write-Status OK 'project root' $ProjectName

$cliSpecs = [ordered]@{
    git = @{ DisplayName = 'git'; CommandName = 'git' }
    dotnet = @{ DisplayName = 'dotnet'; CommandName = 'dotnet' }
    python = @{ DisplayName = 'python'; CommandName = 'python'; VersionRegex = '(?i)Python\s+(?<version>\d+(?:\.\d+){1,3})' }
    node = @{ DisplayName = 'node'; CommandName = 'node' }
}
$CoreTools = [ordered]@{}
foreach ($name in $cliSpecs.Keys) { $spec = $cliSpecs[$name]; $CoreTools[$name] = Get-CliInventory @spec }
$Pac = Get-PacInventory
$Wsl = Get-WslInventory
$Docker = Get-DockerInventory $Wsl
$Pad = Get-PadInventory
$CoreTools.pac = $Pac
$CoreTools.docker = $Docker
$CoreTools.powerAutomateDesktop = $Pad

Write-Section 'Evergreen vendor clients'
$PowerBi = Get-PowerBiDesktopInventory
try { $UiPath = Get-UiPathInventory }
catch { $m = $_.Exception.Message; Write-Status WARN UiPath "probe failed: $m"; $UiPath = New-InventoryRecord $false 'probe-error' $null 'inventory-error' $null $m @{ inventoryComplete = $false } }
$AutomationAnywhere = Get-AutomationAnywhereInventory
$VendorClients = [ordered]@{ powerPlatformCli = $Pac; powerAutomateDesktop = $Pad; powerBiDesktop = $PowerBi; uiPath = $UiPath; automationAnywhere = $AutomationAnywhere }

Write-Section 'Supplemental local context'
$Uv = Get-CliInventory uv uv -Importance supplemental
$Pnpm = Get-CliInventory pnpm pnpm -Importance supplemental
if ($Wsl.installed) { Write-Status OK WSL "$(if ($Wsl.version) { $Wsl.version } else { 'version unknown' }); preferred: $(if ($Wsl.preferredDistro) { $Wsl.preferredDistro } else { 'none' })" } else { Write-Status WARN WSL 'not detected' }
$Compose = if ($Docker.installed -and $Docker.composeVersion) { [ordered]@{ installed = $true; status = 'detected'; version = [string]$Docker.composeVersion; source = [string]$Docker.source } } else { [ordered]@{ installed = $false; status = 'missing-or-unknown'; version = $null; source = $null } }

$CoreSummary = Get-CoverageSummary $CoreTools
$VendorSummary = Get-CoverageSummary $VendorClients
$Payload = [ordered]@{
    project = $ProjectName
    policy = [ordered]@{ missingToolIsFatal = $false; missingToolEncoding = 'installed=false; version=null' }
    coverage = [ordered]@{ coreTools = @($CoreTools.Keys); evergreenVendorClients = @($VendorClients.Keys) }
    status = [ordered]@{ core = $CoreSummary; evergreenVendorClients = $VendorSummary }
    host = Get-HostInventory
    tools = $CoreTools
    evergreenVendorClients = $VendorClients
    supplemental = [ordered]@{ wsl = $Wsl; uv = $Uv; pnpm = $Pnpm; dockerCompose = $Compose }
}
$PayloadJson = Protect-JsonUserPaths ($Payload | ConvertTo-Json -Depth 24)
$Hash = Get-Sha256Text $PayloadJson
$SafePayload = $PayloadJson | ConvertFrom-Json -AsHashtable -Depth 24 -ErrorAction Stop
$Lock = [ordered]@{
    project = $ProjectName
    generatedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    inventorySha256 = $Hash
    policy = $SafePayload.policy
    coverage = $SafePayload.coverage
    status = $SafePayload.status
    host = $SafePayload.host
    tools = $SafePayload.tools
    evergreenVendorClients = $SafePayload.evergreenVendorClients
    supplemental = $SafePayload.supplemental
}

try {
    $Json = $Lock | ConvertTo-Json -Depth 24
    $Parsed = $Json | ConvertFrom-Json -Depth 24 -ErrorAction Stop
    if ([string]$Parsed.project -ne $ProjectName) { throw 'Generated JSON has an unexpected project value.' }
    foreach ($name in $CoreTools.Keys) {
        $r = $Parsed.tools.$name
        if ($null -eq $r -or -not ($r.PSObject.Properties.Name -contains 'installed') -or -not ($r.PSObject.Properties.Name -contains 'version')) { throw "Generated JSON is incomplete at tools.$name." }
    }
    foreach ($name in $VendorClients.Keys) {
        $r = $Parsed.evergreenVendorClients.$name
        if ($null -eq $r -or -not ($r.PSObject.Properties.Name -contains 'installed')) { throw "Generated JSON is incomplete at evergreenVendorClients.$name." }
    }
}
catch { Write-Section 'FATAL JSON validation'; Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }

$unchanged = $false
if (Test-Path -LiteralPath $LockFile -PathType Leaf) {
    try { $old = Get-Content $LockFile -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 24 -ErrorAction Stop; $unchanged = ($old.PSObject.Properties.Name -contains 'inventorySha256' -and [string]$old.inventorySha256 -eq $Hash) }
    catch { Write-Status WARN 'existing lock' 'invalid or incompatible; replacing' }
}
if ($unchanged) { Show-FinalSummary 'inventory unchanged; existing file kept' $CoreSummary $VendorSummary; exit 0 }

try {
    if (Test-Path $TempFile) { Remove-Item $TempFile -Force }
    [IO.File]::WriteAllText($TempFile, $Json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $written = [IO.File]::ReadAllText($TempFile, [Text.Encoding]::UTF8) | ConvertFrom-Json -Depth 24 -ErrorAction Stop
    if ([string]$written.inventorySha256 -ne $Hash) { throw 'On-disk inventory hash mismatch.' }
    Move-Item $TempFile $LockFile -Force
}
catch {
    if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    Write-Section 'FATAL write error'; Write-Host $_.Exception.Message -ForegroundColor Red; exit 1
}

Show-FinalSummary 'valid JSON written' $CoreSummary $VendorSummary
exit 0
