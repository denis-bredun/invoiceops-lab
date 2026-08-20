<#
.SYNOPSIS
    Probes whether the Dynamics 365 Sales trial capability is usable right now.

.DESCRIPTION
    The decision is based on live PAC/Dataverse behavior, not on a stored expiry date.

    Capability states and exit codes:

      AVAILABLE     -> 0
      UNAVAILABLE   -> 10
      EXPIRED       -> 11
      ADMIN_BLOCKED -> 12

    Internal guard failures use exit 20. In that case the public capability state is
    conservatively reported as UNAVAILABLE and guardStatus is ERROR.

    The generated JSON intentionally excludes tenant/user/environment identifiers,
    URLs, email addresses, access tokens, cookies, and raw PAC output.

    The script restores the PAC auth profile that was active before the probe. If the
    previous profile cannot be identified, a configurable fallback profile is used.
    A failed restore is treated as an internal guard error so a later PAC command is
    not allowed to continue with an unknown target environment.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 80)]
    [string]$Profile = "invoiceops-d365-sales-trial",

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3,

    [Parameter()]
    [ValidateRange(0, 60)]
    [int]$RetryDelaySeconds = 2,

    [Parameter()]
    [ValidateRange(5, 600)]
    [int]$CommandTimeoutSeconds = 60,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$RequiredSalesAppUniqueNames = @(
        "msdynce_saleshub",
        "msdynce_salestrialhub"
    ),

    [Parameter()]
    [ValidateSet("Any", "All")]
    [string]$SalesAppMatchMode = "Any",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 80)]
    [string]$FallbackRestoreProfile = "invoiceops-dev",

    [Parameter(DontShow = $true)]
    [string]$PacExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CapabilityName = "d365-sales-trial"
$GuardErrorExitCode = 20

$ExitCodes = [ordered]@{
    AVAILABLE     = 0
    UNAVAILABLE   = 10
    EXPIRED       = 11
    ADMIN_BLOCKED = 12
}

$AllowedStates = @($ExitCodes.Keys)

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "..\artifacts\capabilities\d365-trial-state.json"
}

function New-CheckRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [bool]$Required = $true
    )

    [ordered]@{
        name       = $Name
        required   = $Required
        status     = "NOT_RUN"
        attempts   = 0
        exitCode   = $null
        timedOut   = $false
        durationMs = $null
        note       = $null
    }
}

function Set-CheckResult {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Check,

        [Parameter(Mandatory)]
        [ValidateSet("PASS", "FAIL", "SKIP", "ERROR")]
        [string]$Status,

        [Parameter()]
        [int]$Attempts = 0,

        [Parameter()]
        [AllowNull()]
        [Nullable[int]]$ExitCode = $null,

        [Parameter()]
        [bool]$TimedOut = $false,

        [Parameter()]
        [AllowNull()]
        [Nullable[long]]$DurationMs = $null,

        [Parameter()]
        [AllowNull()]
        [string]$Note = $null
    )

    $Check.status = $Status
    $Check.attempts = $Attempts
    $Check.exitCode = $ExitCode
    $Check.timedOut = $TimedOut
    $Check.durationMs = $DurationMs
    $Check.note = $Note
}

function Get-SafeDiagnosticText {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Text,

        [Parameter()]
        [ValidateRange(32, 4096)]
        [int]$MaxLength = 600
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $safe = $Text
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
        '<email>'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
        '<guid>'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)https?://[^\s''"<>]+',
        '<url>'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*\b',
        'Bearer <redacted>'
    )
    $safe = [regex]::Replace(
        $safe,
        '\s+',
        ' '
    ).Trim()

    if ($safe.Length -gt $MaxLength) {
        return $safe.Substring(0, $MaxLength) + "..."
    }

    return $safe
}

function Resolve-ExternalFailureState {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{
            State  = "UNAVAILABLE"
            Signal = "NO_DIAGNOSTIC_SIGNAL"
        }
    }

    # Token/session expiry is not the same as expiry of the Dynamics trial itself.
    $authExpiry = $Text -match '(?is)\b(access|refresh|authentication|auth|session|token)\b.{0,100}\bexpir(?:ed|y|ation)\b'

    $explicitTrialExpiry = (
        $Text -match '(?is)\btrial\b.{0,160}\b(expir(?:ed|y|ation)|ended|disabled)\b' -or
        $Text -match '(?is)\b(environment|organization|subscription|license|entitlement)\b.{0,160}\bexpir(?:ed|y|ation)\b' -or
        $Text -match '(?is)\bexpir(?:ed|y|ation)\b.{0,160}\b(trial|environment|organization|subscription|license|entitlement)\b'
    )

    if (
        $explicitTrialExpiry -and
        -not ($authExpiry -and $Text -notmatch '(?is)\btrial\b.{0,160}\bexpir')
    ) {
        return [pscustomobject]@{
            State  = "EXPIRED"
            Signal = "EXPLICIT_EXPIRY_SIGNAL"
        }
    }

    $adminBlockedPatterns = @(
        '(?i)\b403\b',
        '(?i)\bforbidden\b',
        '(?i)access\s+denied',
        '(?i)permission\s+denied',
        '(?i)insufficient\s+(privilege|privileges|permission|permissions)',
        '(?i)missing.{0,100}\bprivilege\b',
        '(?i)not\s+authori[sz]ed.{0,160}\b(access|perform|read|execute|use)\b',
        '(?i)administrator.{0,160}\b(block|blocked|restrict|restricted|disable|disabled)\b',
        '(?i)admin(?:istrator)?\s+approval\s+required',
        '(?i)conditional\s+access.{0,160}\b(block|blocked|denied)\b',
        '(?i)AADSTS53003'
    )

    foreach ($pattern in $adminBlockedPatterns) {
        if ($Text -match $pattern) {
            return [pscustomobject]@{
                State  = "ADMIN_BLOCKED"
                Signal = "AUTHORIZATION_POLICY_SIGNAL"
            }
        }
    }

    return [pscustomobject]@{
        State  = "UNAVAILABLE"
        Signal = "GENERIC_UNAVAILABLE_SIGNAL"
    }
}

function Get-PacExecutablePath {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidate = [System.IO.Path]::GetFullPath($ExplicitPath)

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Configured PAC executable does not exist."
        }

        return $candidate
    }

    $command = Get-Command pac -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -eq $command) {
        return $null
    }

    $path = $command.Source

    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $command.Path
    }

    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    return $path
}

function Invoke-NativeProcessCapture {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    foreach ($argument in $Arguments) {
        [void]$psi.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if (-not $process.Start()) {
            throw "Failed to start PAC process."
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        $timedOut = -not $completed

        if ($timedOut) {
            try {
                $process.Kill($true)
            }
            catch {
                try {
                    $process.Kill()
                }
                catch {
                    # Best-effort termination only.
                }
            }
        }

        $process.WaitForExit()

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        $combined = @($stdout, $stderr) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.TrimEnd() }

        $exitCode = if ($timedOut) {
            124
        }
        else {
            $process.ExitCode
        }

        return [pscustomobject]@{
            ExitCode   = $exitCode
            Output     = ($combined -join [Environment]::NewLine)
            TimedOut   = $timedOut
            DurationMs = [long]$stopwatch.ElapsedMilliseconds
        }
    }
    finally {
        $stopwatch.Stop()
        $process.Dispose()
    }
}

function Invoke-PacCapture {
    param(
        [Parameter(Mandatory)]
        [string]$PacPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$Attempts = 1,

        [Parameter()]
        [ValidateRange(0, 60)]
        [int]$DelaySeconds = 0,

        [Parameter(Mandatory)]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds
    )

    $lastResult = $null

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $result = Invoke-NativeProcessCapture `
            -FilePath $PacPath `
            -Arguments $Arguments `
            -TimeoutSeconds $TimeoutSeconds

        $lastResult = [pscustomobject]@{
            ExitCode   = $result.ExitCode
            Output     = $result.Output
            TimedOut   = $result.TimedOut
            DurationMs = $result.DurationMs
            Attempts   = $attempt
        }

        if ($result.ExitCode -eq 0 -and -not $result.TimedOut) {
            return $lastResult
        }

        $classification = Resolve-ExternalFailureState -Text $result.Output

        if ($classification.State -in @("EXPIRED", "ADMIN_BLOCKED")) {
            return $lastResult
        }

        if ($attempt -lt $Attempts -and $DelaySeconds -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $lastResult
}

function Get-ActivePacProfileName {
    param(
        [Parameter(Mandatory)]
        [string]$PacPath,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $listResult = Invoke-PacCapture `
        -PacPath $PacPath `
        -Arguments @("auth", "list") `
        -Attempts 1 `
        -TimeoutSeconds $TimeoutSeconds

    if ($listResult.ExitCode -eq 0 -and -not $listResult.TimedOut) {
        $activeMatch = [regex]::Match(
            $listResult.Output,
            '(?m)^\s*\*\s+(?<name>\S+)\s+'
        )

        if ($activeMatch.Success) {
            return [pscustomobject]@{
                Succeeded = $true
                Name      = $activeMatch.Groups["name"].Value.Trim()
                Result    = $listResult
            }
        }
    }

    $whoResult = Invoke-PacCapture `
        -PacPath $PacPath `
        -Arguments @("auth", "who") `
        -Attempts 1 `
        -TimeoutSeconds $TimeoutSeconds

    if ($whoResult.ExitCode -ne 0 -or $whoResult.TimedOut) {
        return [pscustomobject]@{
            Succeeded = $false
            Name      = $null
            Result    = $whoResult
        }
    }

    $nameMatch = [regex]::Match(
        $whoResult.Output,
        '(?im)^\s*(?:Profile\s+)?Name\s*:?\s*(?<name>.+?)\s*$'
    )

    return [pscustomobject]@{
        Succeeded = $true
        Name      = if ($nameMatch.Success) {
            $nameMatch.Groups["name"].Value.Trim()
        }
        else {
            $null
        }
        Result    = $whoResult
    }
}

function ConvertFrom-PacEnvironmentJson {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $trimmed = $Text.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "PAC env who returned empty output."
    }

    try {
        return $trimmed | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $firstBrace = $trimmed.IndexOf('{')
        $lastBrace = $trimmed.LastIndexOf('}')

        if ($firstBrace -lt 0 -or $lastBrace -le $firstBrace) {
            throw "PAC env who did not contain a JSON object."
        }

        $jsonCandidate = $trimmed.Substring(
            $firstBrace,
            ($lastBrace - $firstBrace + 1)
        )

        try {
            return $jsonCandidate | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "PAC env who returned output that could not be parsed as JSON."
        }
    }
}

function Test-EnvironmentIdentityShape {
    param(
        [Parameter(Mandatory)]
        [object]$EnvironmentInfo
    )

    $requiredProperties = @(
        "OrgId",
        "UniqueName",
        "FriendlyName",
        "OrgUrl",
        "EnvironmentId"
    )

    foreach ($propertyName in $requiredProperties) {
        $property = $EnvironmentInfo.PSObject.Properties[$propertyName]

        if (
            $null -eq $property -or
            [string]::IsNullOrWhiteSpace([string]$property.Value)
        ) {
            return [pscustomobject]@{
                Valid      = $false
                ReasonCode = "ENVIRONMENT_IDENTITY_FIELD_MISSING"
            }
        }
    }

    $orgIdGuid = [guid]::Empty

    if (-not [guid]::TryParse([string]$EnvironmentInfo.OrgId, [ref]$orgIdGuid)) {
        return [pscustomobject]@{
            Valid      = $false
            ReasonCode = "ORGANIZATION_ID_INVALID"
        }
    }

    $environmentIdGuid = [guid]::Empty

    if (
        -not [guid]::TryParse(
            [string]$EnvironmentInfo.EnvironmentId,
            [ref]$environmentIdGuid
        )
    ) {
        return [pscustomobject]@{
            Valid      = $false
            ReasonCode = "ENVIRONMENT_ID_INVALID"
        }
    }

    $organizationUri = $null

    if (
        -not [System.Uri]::TryCreate(
            [string]$EnvironmentInfo.OrgUrl,
            [System.UriKind]::Absolute,
            [ref]$organizationUri
        )
    ) {
        return [pscustomobject]@{
            Valid      = $false
            ReasonCode = "ORGANIZATION_URL_INVALID"
        }
    }

    if ($organizationUri.Scheme -ne "https") {
        return [pscustomobject]@{
            Valid      = $false
            ReasonCode = "ORGANIZATION_URL_NOT_HTTPS"
        }
    }

    return [pscustomobject]@{
        Valid      = $true
        ReasonCode = "ENVIRONMENT_IDENTITY_SHAPE_VALID"
    }
}

function Get-ModelDrivenAppUniqueNames {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $matches = [regex]::Matches(
        $Text,
        '(?im)^\s*Unique\s+Name\s*:\s*(?<name>[A-Za-z0-9_.-]+)\s*$'
    )

    return @(
        $matches |
            ForEach-Object { $_.Groups["name"].Value } |
            Sort-Object -Unique
    )
}

function Test-RequiredSalesApps {
    param(
        [Parameter(Mandatory)]
        [string[]]$ObservedUniqueNames,

        [Parameter(Mandatory)]
        [string[]]$RequiredUniqueNames,

        [Parameter(Mandatory)]
        [ValidateSet("Any", "All")]
        [string]$Mode
    )

    $observedSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($name in $ObservedUniqueNames) {
        [void]$observedSet.Add($name)
    }

    $matched = @(
        foreach ($requiredName in $RequiredUniqueNames) {
            if ($observedSet.Contains($requiredName)) {
                $requiredName
            }
        }
    )

    $satisfied = if ($Mode -eq "All") {
        $matched.Count -eq $RequiredUniqueNames.Count
    }
    else {
        $matched.Count -gt 0
    }

    return [pscustomobject]@{
        Satisfied = $satisfied
        Matched   = @($matched | Sort-Object -Unique)
    }
}

function Write-JsonAtomically {
    param(
        [Parameter(Mandatory)]
        [object]$Payload,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath(
            (Join-Path (Get-Location).Path $Path)
        )
    }

    $directory = Split-Path -Parent $fullPath

    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Output path has no parent directory."
    }

    [void](New-Item -ItemType Directory -Force -Path $directory)

    $fileName = [System.IO.Path]::GetFileName($fullPath)
    $tempPath = Join-Path $directory (
        ".{0}.{1}.{2}.tmp" -f $fileName, $PID, [guid]::NewGuid().ToString("N")
    )

    $json = $Payload | ConvertTo-Json -Depth 20
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    try {
        [System.IO.File]::WriteAllText(
            $tempPath,
            $json + [Environment]::NewLine,
            $utf8NoBom
        )

        if (Test-Path -LiteralPath $fullPath) {
            [System.IO.File]::Delete($fullPath)
        }

        [System.IO.File]::Move($tempPath, $fullPath)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $fullPath
}

function Assert-PublicSnapshotSafety {
    param(
        [Parameter(Mandatory)]
        [object]$Payload
    )

    $json = $Payload | ConvertTo-Json -Depth 20 -Compress

    $forbiddenPatterns = [ordered]@{
        email       = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
        guid        = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
        url         = '(?i)https?://'
        bearerToken = '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+'
        jwtShape    = '(?i)\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'
        cookie      = '(?i)\b(Set-Cookie|Cookie)\s*:'
    }

    foreach ($entry in $forbiddenPatterns.GetEnumerator()) {
        if ($json -match $entry.Value) {
            throw "Generated public snapshot failed safety check: $($entry.Key)."
        }
    }
}

$checks = [ordered]@{
    pacCli                 = New-CheckRecord -Name "pac-cli"
    previousProfileCapture = New-CheckRecord -Name "previous-profile-capture" -Required $false
    trialProfileSelect     = New-CheckRecord -Name "trial-profile-select"
    environmentProbe       = New-CheckRecord -Name "environment-probe"
    environmentShape       = New-CheckRecord -Name "environment-identity-shape"
    salesModelQuery        = New-CheckRecord -Name "sales-model-query"
    salesAppDetection      = New-CheckRecord -Name "sales-app-detection"
    profileRestore         = New-CheckRecord -Name "profile-restore"
}

$capabilityState = "UNAVAILABLE"
$guardStatus = "OK"
$reasonCode = "NOT_CHECKED"
$reason = "Capability check has not completed."
$finalExitCode = $ExitCodes.UNAVAILABLE
$pacPath = $null
$restoreTargetProfile = $null
$matchedSalesApps = @()
$overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $pacPath = Get-PacExecutablePath -ExplicitPath $PacExecutable

    if ([string]::IsNullOrWhiteSpace($pacPath)) {
        Set-CheckResult `
            -Check $checks.pacCli `
            -Status "FAIL" `
            -Note "PAC CLI was not found."

        $capabilityState = "UNAVAILABLE"
        $reasonCode = "PAC_CLI_NOT_FOUND"
        $reason = "PAC CLI is unavailable."
    }
    else {
        Set-CheckResult `
            -Check $checks.pacCli `
            -Status "PASS" `
            -Note "PAC CLI executable was found."

        $profileProbe = Get-ActivePacProfileName `
            -PacPath $pacPath `
            -TimeoutSeconds $CommandTimeoutSeconds

        Set-CheckResult `
            -Check $checks.previousProfileCapture `
            -Status $(if ($profileProbe.Succeeded -and $profileProbe.Name) {
                "PASS"
            }
            else {
                "SKIP"
            }) `
            -Attempts $profileProbe.Result.Attempts `
            -ExitCode $profileProbe.Result.ExitCode `
            -TimedOut $profileProbe.Result.TimedOut `
            -DurationMs $profileProbe.Result.DurationMs `
            -Note $(if ($profileProbe.Succeeded -and $profileProbe.Name) {
                "Active PAC profile captured."
            }
            elseif ($profileProbe.Succeeded) {
                "Active profile name was not parseable; fallback restore profile will be used."
            }
            else {
                "Active PAC profile could not be captured; fallback restore profile will be used."
            })

        if ($profileProbe.Succeeded -and -not [string]::IsNullOrWhiteSpace($profileProbe.Name)) {
            $restoreTargetProfile = $profileProbe.Name
        }
        else {
            $restoreTargetProfile = $FallbackRestoreProfile
        }

        $selectResult = Invoke-PacCapture `
            -PacPath $pacPath `
            -Arguments @("auth", "select", "--name", $Profile) `
            -Attempts 1 `
            -TimeoutSeconds $CommandTimeoutSeconds

        if ($selectResult.ExitCode -ne 0 -or $selectResult.TimedOut) {
            $classification = Resolve-ExternalFailureState -Text $selectResult.Output

            Set-CheckResult `
                -Check $checks.trialProfileSelect `
                -Status "FAIL" `
                -Attempts $selectResult.Attempts `
                -ExitCode $selectResult.ExitCode `
                -TimedOut $selectResult.TimedOut `
                -DurationMs $selectResult.DurationMs `
                -Note "Trial PAC profile could not be selected."

            Write-Verbose (
                "Trial profile selection failed: " +
                (Get-SafeDiagnosticText $selectResult.Output)
            )

            $capabilityState = $classification.State
            $reasonCode = if ($selectResult.TimedOut) {
                "TRIAL_PROFILE_SELECT_TIMEOUT"
            }
            else {
                "TRIAL_PROFILE_SELECT_FAILED"
            }
            $reason = "The trial PAC profile is not usable."
        }
        else {
            Set-CheckResult `
                -Check $checks.trialProfileSelect `
                -Status "PASS" `
                -Attempts $selectResult.Attempts `
                -ExitCode $selectResult.ExitCode `
                -TimedOut $selectResult.TimedOut `
                -DurationMs $selectResult.DurationMs `
                -Note "Trial PAC profile was selected."

            $whoResult = Invoke-PacCapture `
                -PacPath $pacPath `
                -Arguments @("env", "who", "--json") `
                -Attempts $MaxAttempts `
                -DelaySeconds $RetryDelaySeconds `
                -TimeoutSeconds $CommandTimeoutSeconds

            if ($whoResult.ExitCode -ne 0 -or $whoResult.TimedOut) {
                $classification = Resolve-ExternalFailureState -Text $whoResult.Output

                Set-CheckResult `
                    -Check $checks.environmentProbe `
                    -Status "FAIL" `
                    -Attempts $whoResult.Attempts `
                    -ExitCode $whoResult.ExitCode `
                    -TimedOut $whoResult.TimedOut `
                    -DurationMs $whoResult.DurationMs `
                    -Note "Dataverse environment probe failed."

                Write-Verbose (
                    "Environment probe failed: " +
                    (Get-SafeDiagnosticText $whoResult.Output)
                )

                $capabilityState = $classification.State
                $reasonCode = if ($whoResult.TimedOut) {
                    "ENVIRONMENT_PROBE_TIMEOUT"
                }
                else {
                    "ENVIRONMENT_PROBE_FAILED"
                }
                $reason = "The trial Dataverse environment is not reachable."
            }
            else {
                Set-CheckResult `
                    -Check $checks.environmentProbe `
                    -Status "PASS" `
                    -Attempts $whoResult.Attempts `
                    -ExitCode $whoResult.ExitCode `
                    -TimedOut $whoResult.TimedOut `
                    -DurationMs $whoResult.DurationMs `
                    -Note "Dataverse environment responded to pac env who --json."

                $environmentInfo = ConvertFrom-PacEnvironmentJson -Text $whoResult.Output
                $shape = Test-EnvironmentIdentityShape -EnvironmentInfo $environmentInfo

                if (-not $shape.Valid) {
                    Set-CheckResult `
                        -Check $checks.environmentShape `
                        -Status "FAIL" `
                        -Note $shape.ReasonCode

                    $capabilityState = "UNAVAILABLE"
                    $reasonCode = $shape.ReasonCode
                    $reason = "The selected profile does not identify a structurally valid Dataverse organization."
                }
                else {
                    Set-CheckResult `
                        -Check $checks.environmentShape `
                        -Status "PASS" `
                        -Note "Dataverse identity fields are structurally valid."

                    $modelResult = Invoke-PacCapture `
                        -PacPath $pacPath `
                        -Arguments @(
                            "model", "list",
                            "--environment", [string]$environmentInfo.OrgUrl
                        ) `
                        -Attempts $MaxAttempts `
                        -DelaySeconds $RetryDelaySeconds `
                        -TimeoutSeconds $CommandTimeoutSeconds

                    if ($modelResult.ExitCode -ne 0 -or $modelResult.TimedOut) {
                        $classification = Resolve-ExternalFailureState -Text $modelResult.Output

                        Set-CheckResult `
                            -Check $checks.salesModelQuery `
                            -Status "FAIL" `
                            -Attempts $modelResult.Attempts `
                            -ExitCode $modelResult.ExitCode `
                            -TimedOut $modelResult.TimedOut `
                            -DurationMs $modelResult.DurationMs `
                            -Note "Model-driven app inventory could not be queried."

                        Write-Verbose (
                            "Model list failed: " +
                            (Get-SafeDiagnosticText $modelResult.Output)
                        )

                        $capabilityState = $classification.State
                        $reasonCode = if ($modelResult.TimedOut) {
                            "SALES_MODEL_QUERY_TIMEOUT"
                        }
                        else {
                            "SALES_MODEL_QUERY_FAILED"
                        }
                        $reason = "Dynamics 365 Sales model-driven apps could not be queried."
                    }
                    else {
                        Set-CheckResult `
                            -Check $checks.salesModelQuery `
                            -Status "PASS" `
                            -Attempts $modelResult.Attempts `
                            -ExitCode $modelResult.ExitCode `
                            -TimedOut $modelResult.TimedOut `
                            -DurationMs $modelResult.DurationMs `
                            -Note "Model-driven app inventory was queried successfully."

                        $observedAppUniqueNames = Get-ModelDrivenAppUniqueNames -Text $modelResult.Output

                        $salesApps = Test-RequiredSalesApps `
                            -ObservedUniqueNames $observedAppUniqueNames `
                            -RequiredUniqueNames $RequiredSalesAppUniqueNames `
                            -Mode $SalesAppMatchMode

                        $matchedSalesApps = @($salesApps.Matched)

                        if ($salesApps.Satisfied) {
                            Set-CheckResult `
                                -Check $checks.salesAppDetection `
                                -Status "PASS" `
                                -Note "Required Dynamics 365 Sales app signature was detected."

                            $capabilityState = "AVAILABLE"
                            $reasonCode = "LIVE_SALES_CAPABILITY_VERIFIED"
                            $reason = "Trial Dataverse and Dynamics 365 Sales are reachable now."
                        }
                        else {
                            Set-CheckResult `
                                -Check $checks.salesAppDetection `
                                -Status "FAIL" `
                                -Note "Required Dynamics 365 Sales app signature was not detected."

                            $capabilityState = "UNAVAILABLE"
                            $reasonCode = "SALES_APP_NOT_DETECTED"
                            $reason = "The environment is reachable, but the required Dynamics 365 Sales app is not currently detected."
                        }
                    }
                }
            }
        }
    }
}
catch {
    $guardStatus = "ERROR"
    $capabilityState = "UNAVAILABLE"
    $reasonCode = "GUARD_INTERNAL_ERROR"
    $reason = "The capability guard encountered an internal or configuration error."

    Write-Verbose (
        "Guard internal error: " +
        (Get-SafeDiagnosticText $_.Exception.Message)
    )
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($pacPath)) {
        if ([string]::IsNullOrWhiteSpace($restoreTargetProfile)) {
            Set-CheckResult `
                -Check $checks.profileRestore `
                -Status "ERROR" `
                -Note "No safe restore target profile was available."

            $guardStatus = "ERROR"
            $capabilityState = "UNAVAILABLE"
            $reasonCode = "PROFILE_RESTORE_TARGET_UNKNOWN"
            $reason = "The guard could not determine a safe PAC profile to restore."
        }
        elseif (
            [string]::Equals(
                $restoreTargetProfile,
                $Profile,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Set-CheckResult `
                -Check $checks.profileRestore `
                -Status "SKIP" `
                -Note "The restore target is already the trial profile."
        }
        else {
            try {
                $restoreResult = Invoke-PacCapture `
                    -PacPath $pacPath `
                    -Arguments @("auth", "select", "--name", $restoreTargetProfile) `
                    -Attempts 1 `
                    -TimeoutSeconds $CommandTimeoutSeconds

                if ($restoreResult.ExitCode -eq 0 -and -not $restoreResult.TimedOut) {
                    Set-CheckResult `
                        -Check $checks.profileRestore `
                        -Status "PASS" `
                        -Attempts $restoreResult.Attempts `
                        -ExitCode $restoreResult.ExitCode `
                        -TimedOut $restoreResult.TimedOut `
                        -DurationMs $restoreResult.DurationMs `
                        -Note "Previous/fallback PAC profile was restored."
                }
                else {
                    Set-CheckResult `
                        -Check $checks.profileRestore `
                        -Status "ERROR" `
                        -Attempts $restoreResult.Attempts `
                        -ExitCode $restoreResult.ExitCode `
                        -TimedOut $restoreResult.TimedOut `
                        -DurationMs $restoreResult.DurationMs `
                        -Note "PAC profile restoration failed."

                    Write-Verbose (
                        "Profile restore failed: " +
                        (Get-SafeDiagnosticText $restoreResult.Output)
                    )

                    $guardStatus = "ERROR"
                    $capabilityState = "UNAVAILABLE"
                    $reasonCode = "PROFILE_RESTORE_FAILED"
                    $reason = "The guard could not safely restore the PAC auth context."
                }
            }
            catch {
                Set-CheckResult `
                    -Check $checks.profileRestore `
                    -Status "ERROR" `
                    -Note "PAC profile restoration raised an exception."

                $guardStatus = "ERROR"
                $capabilityState = "UNAVAILABLE"
                $reasonCode = "PROFILE_RESTORE_EXCEPTION"
                $reason = "The guard could not safely restore the PAC auth context."

                Write-Verbose (
                    "Profile restore exception: " +
                    (Get-SafeDiagnosticText $_.Exception.Message)
                )
            }
        }
    }
    else {
        Set-CheckResult `
            -Check $checks.profileRestore `
            -Status "SKIP" `
            -Note "PAC CLI was unavailable; no profile was changed."
    }
}

$overallStopwatch.Stop()

if ($guardStatus -eq "ERROR") {
    $finalExitCode = $GuardErrorExitCode
}
elseif ($capabilityState -notin $AllowedStates) {
    $guardStatus = "ERROR"
    $capabilityState = "UNAVAILABLE"
    $reasonCode = "INVALID_INTERNAL_STATE"
    $reason = "The guard produced an invalid internal capability state."
    $finalExitCode = $GuardErrorExitCode
}
else {
    $finalExitCode = $ExitCodes[$capabilityState]
}

$payload = [ordered]@{
    capability   = $CapabilityName
    state        = $capabilityState
    guardStatus  = $guardStatus
    exitCode     = $finalExitCode
    checkedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    durationMs   = [long]$overallStopwatch.ElapsedMilliseconds
    reasonCode   = $reasonCode
    reason       = $reason

    policy = [ordered]@{
        decisionSource              = "live-pac-dataverse-probe"
        expiryDateUsedForDecision   = $false
        externalSkipStates          = @("UNAVAILABLE", "EXPIRED", "ADMIN_BLOCKED")
        internalErrorExitCode       = $GuardErrorExitCode
        salesAppMatchMode           = $SalesAppMatchMode
        requiredSalesAppUniqueNames = @($RequiredSalesAppUniqueNames | Sort-Object -Unique)
        restorePreviousProfile      = $true
    }

    observed = [ordered]@{
        liveEnvironmentProbeSucceeded = ($checks.environmentProbe.status -eq "PASS")
        environmentIdentityShapeValid = ($checks.environmentShape.status -eq "PASS")
        salesModelQuerySucceeded      = ($checks.salesModelQuery.status -eq "PASS")
        matchedSalesAppUniqueNames    = @($matchedSalesApps | Sort-Object -Unique)
    }

    checks = $checks
}

try {
    Assert-PublicSnapshotSafety -Payload $payload
    $writtenPath = Write-JsonAtomically -Payload $payload -Path $OutputPath
}
catch {
    Write-Error (
        "Failed to validate/write capability snapshot: " +
        (Get-SafeDiagnosticText $_.Exception.Message)
    ) -ErrorAction Continue

    exit $GuardErrorExitCode
}

Write-Host "Dynamics 365 Sales trial capability: $capabilityState"
Write-Host "Guard status: $guardStatus"
Write-Host "Reason: $reasonCode"
Write-Host "Generated: $writtenPath"
Write-Output "D365_TRIAL_STATE=$capabilityState"
Write-Output "D365_TRIAL_EXIT_CODE=$finalExitCode"

exit $finalExitCode
