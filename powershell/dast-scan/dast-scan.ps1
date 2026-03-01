#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initiates a DAST scan in FoD, optionally waiting for completion.

.DESCRIPTION
    This script authenticates to an FoD instance, resolves a target release (by ReleaseId or by ApplicationName+ReleaseName),
    triggers and polls a DAST scan until completion. Configuration values may be provided as parameters, environment variables,
    or in a fortify.config INI file under the [fod] section. Precedence: Parameter > Environment Variable > Config file.

.PARAMETER FodApiUrl
    The base URL for the FoD API (for example https://api.emea.fortify.com). This value is required.

.PARAMETER FodUsername
    Username for user/password authentication (used together with FodPassword and FodTenant).

.PARAMETER FodPassword
    Password for user authentication. Sensitive value; will be masked in summaries unless -Debug is provided.

.PARAMETER FodTenant
    Tenant name (domain) used for user authentication. Required for username/password authentication.

.PARAMETER FodClientId
    Client ID for OAuth client_credentials authentication. Used together with FodClientSecret.

.PARAMETER FodClientSecret
    Client secret for OAuth client_credentials authentication. Sensitive value.

.PARAMETER ApplicationName
    The FoD application name used when resolving a ReleaseId by name.

.PARAMETER ReleaseName
    The FoD release name used when resolving a ReleaseId by name.

.PARAMETER ReleaseId
    Numeric FoD releaseId. If provided the script will validate the release exists and use it for uploads. If not
    provided the script will attempt to resolve the releaseId using ApplicationName and ReleaseName.

.PARAMETER WhatIfConfig
    When specified, the script prints the effective configuration (showing sources) and exits without performing actions.

.PARAMETER PollingInterval
    When using -WaitFor, the number of seconds to wait between polling attempts against the polling-summary endpoint.
    Defaults to 10 seconds.

.PARAMETER WaitFor
    If specified, after initiating the scan the script will poll the scan polling-summary endpoint until the
    analysis status becomes Completed or Canceled.

.PARAMETER ApiScope
    OAuth scope to request when acquiring an access token. Defaults to 'api-tenant'. Change this only if your FoD
    deployment requires a different scope string.

.EXAMPLE
    .\dast-scan.ps1 -FodApiUrl https://api.example.com -FodClientId abc -FodClientSecret def -ReleaseId 12345 -Verbose

.EXAMPLE
    .\dast-scan.ps1 -FodApiUrl https://api.example.com -FodUsername user -FodPassword pass -FodTenant tenant -ApplicationName MyApp -ReleaseName "2025.1" -WaitFor -PollingInterval 15
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$FodApiUrl,

    [Parameter(Mandatory=$false)]
    [string]$FodUsername,

    [Parameter(Mandatory=$false)]
    [string]$FodPassword,

    [Parameter(Mandatory=$false)]
    [string]$FodTenant,

    [Parameter(Mandatory=$false)]
    [string]$FodClientId,

    [Parameter(Mandatory=$false)]
    [string]$FodClientSecret,

    [Parameter(Mandatory=$false)]
    [string]$ApplicationName,

    [Parameter(Mandatory=$false)]
    [string]$ReleaseName,

    [Parameter(Mandatory=$false)]
    [string]$ReleaseId,

    [Parameter(Mandatory=$false)]
    [switch]$WhatIfConfig,

    [Parameter(Mandatory=$false)]
    [int]$PollingInterval = 30,

    [Parameter(Mandatory=$false)]
    [switch]$WaitFor
    ,
    [Parameter(Mandatory=$false)]
    [string]$ApiScope = 'api-tenant'
)

# Set error action preference
$ErrorActionPreference = "Stop"

function Parse-IniSection {
    param(
        [string]$Path,
        [string]$Section
    )
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    $lines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    $inSection = $false
    foreach ($l in $lines) {
        $line = $l.Trim()
        if ($line -match '^[;#]') { continue }
        if ($line -match '^\[(.+)\]$') {
            $inSection = ($Matches[1] -ieq $Section)
            continue
        }
        if ($inSection -and $line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim()
            $result[$k] = $v
        }
    }
    return $result
}

function Resolve-ConfigValue {
    param(
        [string]$Name,
        [string]$ParamValue,
        [string[]]$EnvNames,
        [string]$ConfigValue
    )

    if (-not [string]::IsNullOrEmpty($ParamValue)) {
        return @{ Value = $ParamValue; Source = 'parameter' }
    }

    foreach ($envName in $EnvNames) {
        if ($envName) {
            $ev = Get-Item -Path "Env:$envName" -ErrorAction SilentlyContinue
            if ($ev -and -not [string]::IsNullOrEmpty($ev.Value)) {
                return @{ Value = $ev.Value; Source = 'environment' }
            }
        }
    }

    if (-not [string]::IsNullOrEmpty($ConfigValue)) {
        return @{ Value = $ConfigValue; Source = 'config' }
    }

    return @{ Value = $null; Source = '<unset>' }
}

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} catch {
    $scriptDir = Get-Location
}

# locate fortify.config (current dir then script dir)
$configPath = Join-Path -Path (Get-Location) -ChildPath 'fortify.config'
if (-not (Test-Path $configPath)) {
    $alt = Join-Path -Path $scriptDir -ChildPath 'fortify.config'
    if (Test-Path $alt) { $configPath = $alt }
}

Write-Verbose "Config path: $configPath"

if (Test-Path $configPath) {
    Write-Host "Reading options from $configPath..." -ForegroundColor Cyan
    $fodConfig = Parse-IniSection -Path $configPath -Section 'fod'
} else {
    Write-Host "No options file found ($configPath)" -ForegroundColor Gray
    $fodConfig = @{}
}

# env var names
$envMap = @{
    'FodApiUrl' = 'FOD_API_URL'
    'FodUsername' = 'FOD_USERNAME'
    'FodPassword' = 'FOD_PASSWORD'
    'FodTenant' = 'FOD_TENANT'
    'FodApplicationName' = 'FOD_APPLICATION_NAME'
    'FodReleaseName' = 'FOD_RELEASE_NAME'
    'FodClientId' = 'FOD_CLIENT_ID'
    'FodClientSecret' = 'FOD_CLIENT_SECRET'
    'ReleaseId' = 'RELEASE_ID'
    'ApiScope' = 'API_SCOPE'
    'PollingInterval' = 'POLLING_INTERVAL'
    'WaitFor' = 'WAIT_FOR'
}

# Masking helper for secrets in preview
function MaskVal([string]$key, [string]$val) {
    if (-not $val) { return '<not set>' }
    if ($PSBoundParameters.ContainsKey('Debug')) { return $val }
    $lk = $key.ToLower()
    if ($lk -like '*token*' -or $lk -like '*auth*' -or $lk -like '*pass*' -or $lk -like '*secret*' -or $lk -like '*password*' -or $lk -like '*clientsecret*') { return '****(masked)' }
    return $val
}

# Wrapper for Invoke-RestMethod that logs requests and responses when -Debug is used
function Invoke-FodApi {
    param(
        [Parameter(Mandatory=$true)] [ValidateSet('Get','Post','Put','Delete','Patch')] [string]$Method,
        [Parameter(Mandatory=$true)] [string]$Uri,
        [hashtable]$Headers = $null,
        $Body = $null,
        [string]$InFile = $null,
        [string]$ContentType = $null
    )

    # remove annoying progress bar
    $ProgressPreference = 'SilentlyContinue'

    Write-Verbose "REQUEST: $Method $Uri"
    try {
        if ($InFile) {
            if ($ContentType) {
                $resp = Invoke-RestMethod -Uri $Uri -Method $Method -InFile $InFile -ContentType $ContentType -Headers $Headers -ErrorAction Stop
            } else {
                $resp = Invoke-RestMethod -Uri $Uri -Method $Method -InFile $InFile -Headers $Headers -ErrorAction Stop
            }
        } elseif ($null -ne $Body) {
            # If Body is not a string, convert to JSON unless a non-JSON content type is specified
            if ($Body -isnot [string] -and $ContentType -eq 'application/json') {
                $bodyStr = $Body | ConvertTo-Json -Depth 10
            } elseif ($Body -isnot [string] -and $ContentType -eq 'application/x-www-form-urlencoded') {
                # Body may be a hashtable for form posts; pass through as-is
                $bodyStr = $Body
            } else {
                $bodyStr = $Body
            }
            Write-Verbose "Request body: $([string]$bodyStr)"
            if ($ContentType) {
                $resp = Invoke-RestMethod -Uri $Uri -Method $Method -Body $bodyStr -ContentType $ContentType -Headers $Headers -ErrorAction Stop
            } else {
                $resp = Invoke-RestMethod -Uri $Uri -Method $Method -Body $bodyStr -Headers $Headers -ErrorAction Stop
            }
        } else {
            $resp = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -ErrorAction Stop
        }

        if ($PSBoundParameters.ContainsKey('Debug')) {
            try { $dbg = $resp | ConvertTo-Json -Depth 5 } catch { $dbg = $resp }
            Write-Verbose "RESPONSE: $dbg"
        }

        return $resp
    } catch {
        Write-Error ("ERROR invoking {0} {1}: {2}" -f $Method, $Uri, $_)
        throw $_
    }
}

# Environment candidates checked mapping (for verbose preview)
$envCandidates = @{
    'FodApiUrl' = @($envMap['FodApiUrl'])
    'FodUsername' = @($envMap['FodUsername'])
    'FodPassword' = @($envMap['FodPassword'])
    'FodTenant' = @($envMap['FodTenant'])
    'FodClientId' = @($envMap['FodClientId'])
    'FodClientSecret' = @($envMap['FodClientSecret'])
    'FodApplicationName' = @($envMap['FodApplicationName'])
    'FodReleaseName' = @($envMap['FodReleaseName'])
    'ReleaseId' = @($envMap['ReleaseId'])
    'ApiScope' = @($envMap['ApiScope'])
    'PollingInterval' = @($envMap['PollingInterval'])
    'WaitFor' = @($envMap['WaitFor'])
}

# If user requested a WhatIf preview, build and print table then exit
if ($WhatIfConfig) {
    $report = @()
    $r = Resolve-ConfigValue -Name 'FodApiUrl' -ParamValue $FodApiUrl -EnvNames $envCandidates['FodApiUrl'] -ConfigValue ($fodConfig['FodApiUrl'])
    $report += [PSCustomObject]@{ Key='FodApiUrl'; Value = MaskVal 'FodApiUrl' $r.Value; Source = $r.Source }

    $r = Resolve-ConfigValue -Name 'FodUsername' -ParamValue $FodUsername -EnvNames $envCandidates['FodUsername'] -ConfigValue ($fodConfig['FodUsername'])
    $report += [PSCustomObject]@{ Key='FodUsername'; Value = MaskVal 'FodUsername' $r.Value; Source = $r.Source }

    $r = Resolve-ConfigValue -Name 'FodPassword' -ParamValue $FodPassword -EnvNames $envCandidates['FodPassword'] -ConfigValue ($fodConfig['FodPassword'])
    $report += [PSCustomObject]@{ Key='FodPassword'; Value = MaskVal 'FodPassword' $r.Value; Source = $r.Source }

    $r = Resolve-ConfigValue -Name 'FodTenant' -ParamValue $FodTenant -EnvNames $envCandidates['FodTenant'] -ConfigValue ($fodConfig['FodTenant'])
    $report += [PSCustomObject]@{ Key='FodTenant'; Value = MaskVal 'FodTenant' $r.Value; Source = $r.Source }

    $r = Resolve-ConfigValue -Name 'FodClientId' -ParamValue $FodClientId -EnvNames $envCandidates['FodClientId'] -ConfigValue ($fodConfig['FodClientId'])
    $report += [PSCustomObject]@{ Key='FodClientId'; Value = MaskVal 'FodClientId' $r.Value; Source = $r.Source }

    $r = Resolve-ConfigValue -Name 'FodClientSecret' -ParamValue $FodClientSecret -EnvNames $envCandidates['FodClientSecret'] -ConfigValue ($fodConfig['FodClientSecret'])
    $report += [PSCustomObject]@{ Key='FodClientSecret'; Value = MaskVal 'FodClientSecret' $r.Value; Source = $r.Source }

    $r = Resolve-ConfigValue -Name 'FodApplicationName' -ParamValue $ApplicationName -EnvNames $envCandidates['FodApplicationName'] -ConfigValue ($fodConfig['FodApplicationName'])
    $report += [PSCustomObject]@{ Key='FodApplicationName'; Value = MaskVal 'FodApplicationName' $r.Value; Source = $r.Source }

    $r = Resolve-ConfigValue -Name 'FodReleaseName' -ParamValue $ReleaseName -EnvNames $envCandidates['FodReleaseName'] -ConfigValue ($fodConfig['FodReleaseName'])
    $report += [PSCustomObject]@{ Key='FodReleaseName'; Value = MaskVal 'FodReleaseName' $r.Value; Source = $r.Source }

    $r = Resolve-ConfigValue -Name 'ReleaseId' -ParamValue $ReleaseId -EnvNames $envCandidates['ReleaseId'] -ConfigValue ($fodConfig['ReleaseId'])
    $report += [PSCustomObject]@{ Key='ReleaseId'; Value = MaskVal 'ReleaseId' $r.Value; Source = $r.Source }

    $param = if ($PSBoundParameters.ContainsKey('ApiScope')) { $ApiScope } else { $null }
    $r = Resolve-ConfigValue -Name 'ApiScope' -ParamValue $param -EnvNames $envCandidates['ApiScope'] -ConfigValue ($fodConfig['ApiScope'])
    $report += [PSCustomObject]@{ Key='ApiScope'; Value = MaskVal 'ApiScope' $r.Value; Source = $r.Source }

    $param = if ($PSBoundParameters.ContainsKey('PollingInterval')) { $PollingInterval } else { $null }
    $r = Resolve-ConfigValue -Name 'PollingInterval' -ParamValue $param -EnvNames $envCandidates['PollingInterval'] -ConfigValue ($fodConfig['PollingInterval'])
    $report += [PSCustomObject]@{ Key='PollingInterval'; Value = $r.Value; Source = $r.Source }

    $param = if ($PSBoundParameters.ContainsKey('WaitFor')) { $WaitFor } else { $null }
    $r = Resolve-ConfigValue -Name 'WaitFor' -ParamValue $param -EnvNames $envCandidates['WaitFor'] -ConfigValue ($fodConfig['WaitFor'])
    $report += [PSCustomObject]@{ Key='WaitFor'; Value = $r.Value; Source = $r.Source }

    Write-Host "=== fod-scan.ps1 Effective Configuration (WhatIf) ===" -ForegroundColor Yellow
    $report | Format-Table -Property Key, Value, Source -AutoSize
    Write-Host "Note: values containing 'token', 'auth', 'pass', 'secret', or 'password' are masked unless you pass -Debug." -ForegroundColor Yellow

    if ($PSBoundParameters.ContainsKey('Verbose')) {
        Write-Host "`nEnvironment variables checked (per key):" -ForegroundColor Yellow
        foreach ($k in $envCandidates.Keys) {
            $cands = $envCandidates[$k]
            foreach ($envName in $cands) {
                if (-not $envName) { continue }
                $val = Get-Item -Path "Env:$envName" -ErrorAction SilentlyContinue
                $valShown = if ($val -and $val.Value -ne '') { MaskVal $envName $val.Value } else { '<not present>' }
                Write-Host ('    {0,-35} -> {1, -20}' -f $envName, $valShown)
            }
        }
    }

    exit 0
}

# Resolve final values with precedence Param > Env > Config using Resolve-ConfigValue (same as scan.ps1)
$rc = Resolve-ConfigValue -Name 'FodApiUrl' -ParamValue $FodApiUrl -EnvNames @($envMap['FodApiUrl']) -ConfigValue ($fodConfig['FodApiUrl'])
$ApiUrl = $rc.Value
$rc = Resolve-ConfigValue -Name 'FodUsername' -ParamValue $FodUsername -EnvNames @($envMap['FodUsername']) -ConfigValue ($fodConfig['FodUsername'])
$ApiUser = $rc.Value
$rc = Resolve-ConfigValue -Name 'FodPassword' -ParamValue $FodPassword -EnvNames @($envMap['FodPassword']) -ConfigValue ($fodConfig['FodPassword'])
$ApiPass = $rc.Value
$rc = Resolve-ConfigValue -Name 'FodTenant' -ParamValue $FodTenant -EnvNames @($envMap['FodTenant']) -ConfigValue ($fodConfig['FodTenant'])
$Tenant = $rc.Value
$rc = Resolve-ConfigValue -Name 'FodApplicationName' -ParamValue $ApplicationName -EnvNames @($envMap['FodApplicationName']) -ConfigValue ($fodConfig['FodApplicationName'])
$AppName = $rc.Value
$rc = Resolve-ConfigValue -Name 'FodReleaseName' -ParamValue $ReleaseName -EnvNames @($envMap['FodReleaseName']) -ConfigValue ($fodConfig['FodReleaseName'])
$RelName = $rc.Value
$rc = Resolve-ConfigValue -Name 'ReleaseId' -ParamValue $ReleaseId -EnvNames @($envMap['ReleaseId']) -ConfigValue ($fodConfig['ReleaseId'])
$RelId = $rc.Value

# Allow PollingInterval and WaitFor to be overridden via environment or fortify.config
# but only if the user did not explicitly pass the parameter (so explicit args take precedence).
$paramPolling = if ($PSBoundParameters.ContainsKey('PollingInterval')) { $PollingInterval } else { $null }
$rc = Resolve-ConfigValue -Name 'PollingInterval' -ParamValue $paramPolling -EnvNames @($envMap['PollingInterval']) -ConfigValue ($fodConfig['PollingInterval'])
if ($rc.Value -ne $null -and $rc.Value -ne '') { try { $PollingInterval = [int]$rc.Value } catch { Write-Verbose "Could not parse PollingInterval '$($rc.Value)' as int; keeping current value $PollingInterval" } }

$paramWait = if ($PSBoundParameters.ContainsKey('WaitFor')) { $WaitFor } else { $null }
$rc = Resolve-ConfigValue -Name 'WaitFor' -ParamValue $paramWait -EnvNames @($envMap['WaitFor']) -ConfigValue ($fodConfig['WaitFor'])
if ($rc.Value -ne $null -and $rc.Value -ne '') {
    $val = $rc.Value
    if ($val -is [bool]) { $WaitFor = $val } else {
        if ($val -match '^(1|true|yes|y)$') { $WaitFor = $true } else { $WaitFor = $false }
    }
}

$rc = Resolve-ConfigValue -Name 'FodClientId' -ParamValue $FodClientId -EnvNames @($envMap['FodClientId']) -ConfigValue ($fodConfig['FodClientId'])
$ClientId = $rc.Value
$rc = Resolve-ConfigValue -Name 'FodClientSecret' -ParamValue $FodClientSecret -EnvNames @($envMap['FodClientSecret']) -ConfigValue ($fodConfig['FodClientSecret'])
$ClientSecret = $rc.Value

# Allow ApiScope and ChunkSize to be overridden via environment or fortify.config
$paramScope = if ($PSBoundParameters.ContainsKey('ApiScope')) { $ApiScope } else { $null }
$rc = Resolve-ConfigValue -Name 'ApiScope' -ParamValue $paramScope -EnvNames @($envMap['ApiScope']) -ConfigValue ($fodConfig['ApiScope'])
if ($rc.Value -ne $null -and $rc.Value -ne '') { $ApiScope = $rc.Value }

# Ensure sensible defaults if none of parameter/env/config supplied a value
if (-not $ApiScope -or $ApiScope -eq '') { $ApiScope = 'api-tenant' }
if (-not $PollingInterval -or $PollingInterval -le 0) { $PollingInterval = 30 }

if (-not $ApiUrl) {
    $msg = "Fortify API URL not provided. Provide -FodApiUrl, set environment variable FOD_API_URL, or add 'FodApiUrl' under [fod] in fortify.config."
    Write-Error $msg
    exit 2
}

Write-Verbose "Resolved values: ApiUrl=$ApiUrl, AppName=$AppName, ReleaseName=$RelName, ReleaseId=$RelId, Package=$Pkg"

# Require either a ReleaseId, or both ApplicationName and ReleaseName
if (-not $RelId) {
    if (-not $AppName -or -not $RelName) {
        $msg = "Fortify target not specified. Provide -ReleaseId, or both -ApplicationName and -ReleaseName, or set corresponding environment variables or fortify.config entries."
        Write-Error $msg
        exit 2
    }
}

# Authentication: explicit selection and validation
# Priority: explicit env token -> API (client credentials) -> User (username/password/tenant)
$token = $null
if ($env:FOD_AUTH_TOKEN) {
    Write-Host "Using FOD_AUTH_TOKEN from environment." -ForegroundColor Cyan
    $token = $env:FOD_AUTH_TOKEN
} else {
    # Determine intended auth mode and validate required fields
    if ($ClientId -or $ClientSecret) {
        # API auth selected (client credentials) but both values required
        if (-not ($ClientId -and $ClientSecret)) {
            Write-Error "API authentication selected but both FodClientId and FodClientSecret must be set."
            exit 2
        }
        Write-Host "API authentication selected (client credentials)." -ForegroundColor Yellow
        try {
            $tokenUrl = "$ApiUrl/oauth/token"
            $body = @{ grant_type='client_credentials'; client_id=$ClientId; client_secret=$ClientSecret; scope=$ApiScope }
            Write-Verbose "Token URL: $tokenUrl"
            $resp = Invoke-FodApi -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -Headers $null
            if ($resp.access_token) {
                $token = $resp.access_token
                Write-Host 'Obtained access token via client credentials.' -ForegroundColor Green
            } else {
                Write-Verbose "Token response: $($resp | ConvertTo-Json -Depth 3)"
            }
        } catch {
            Write-Error "Client credentials token request failed: $_"
            exit 3
        }
    } elseif ($ApiUser -or $ApiPass -or $Tenant) {
        # User auth selected, require username, password and tenant
        if (-not ($ApiUser -and $ApiPass -and $Tenant)) {
            Write-Error "User authentication selected but FodUsername, FodPassword and FodTenant must all be set."
            exit 2
        }
        Write-Host "User authentication selected (username/password/tenant)." -ForegroundColor Cyan
        try {
            $tokenUrl = "$ApiUrl/oauth/token"
            $userField = "${Tenant}\${ApiUser}"
            $body = @{ grant_type='password'; username=$userField; password=$ApiPass; scope=$ApiScope }
            Write-Verbose "Token URL: $tokenUrl"
            $resp = Invoke-FodApi -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -Headers $null
            if ($resp.access_token) {
                $token = $resp.access_token
                Write-Host 'Obtained access token via user credentials.' -ForegroundColor Green
            } else {
                Write-Verbose "Token response: $($resp | ConvertTo-Json -Depth 3)"
            }
        } catch {
            Write-Error "User token request failed: $_"
            exit 3
        }
    } else {
        Write-Error "No authentication provided. Set FOD_AUTH_TOKEN, or provide FodClientId+FodClientSecret, or FodUsername+FodPassword+FodTenant."
        exit 2
    }
}

if (-not $token) {
    Write-Verbose "No access token obtained; proceeding without Authorization header (may fail)."
} else {
    if ($PSBoundParameters.ContainsKey('Debug')) {
        Write-Host "Access token: $token" -ForegroundColor Yellow
    }
}

# If ReleaseId supplied, validate it exists and display releaseName/applicationName
if ($RelId) {
    Write-Verbose "Validating supplied ReleaseId: $RelId"
    try {
        $checkUrl = "$ApiUrl/api/v3/releases/$RelId"
        $checkHeaders = @{}
        if ($token) { $checkHeaders['Authorization'] = "Bearer $token" }
        $checkResp = Invoke-FodApi -Method Get -Uri $checkUrl -Headers $checkHeaders
        $apiRelName = $checkResp.releaseName
        $apiAppName = $checkResp.applicationName
        Write-Host "Release $RelId resolved: applicationName='$apiAppName', releaseName='$apiRelName'" -ForegroundColor Green
        if (-not $RelName) { $RelName = $apiRelName }
        if (-not $AppName) { $AppName = $apiAppName }
    } catch {
        # Try to detect 404 from the underlying web response
        $err = $_
        $status = $null
        try { $status = $err.Exception.Response.StatusCode.Value__ } catch { }
        if ($status -eq 404) {
            Write-Error "ReleaseId $RelId not found (404)."
            exit 2
        } else {
            Write-Error "Release lookup for ReleaseId $RelId failed: $_"
            exit 3
        }
    }
}

# If ReleaseId not provided, attempt to resolve it via the FoD API using applicationName+releaseName
if (-not $RelId -and $AppName -and $RelName) {
    Write-Verbose "ReleaseId not supplied; looking up release via API"
    try {
        $filters = "applicationName:$AppName+releaseName:$RelName"
        $filtersEnc = [System.Uri]::EscapeDataString($filters)
        $fieldsEnc = [System.Uri]::EscapeDataString('releaseId,releaseName')
        $lookupUrl = "$ApiUrl/api/v3/releases?filters=$filtersEnc&fields=$fieldsEnc"
        Write-Verbose "Release lookup URL: $lookupUrl"

        $lookupHeaders = @{}
        if ($token) { $lookupHeaders['Authorization'] = "Bearer $token" }

        $relResp = Invoke-FodApi -Method Get -Uri $lookupUrl -Headers $lookupHeaders

        # Normalize possible response shapes to an array of results
        $results = @()
        if ($null -ne $relResp.items) { $results = $relResp.items }
        elseif ($null -ne $relResp.content) { $results = $relResp.content }
        elseif ($null -ne $relResp.releases) { $results = $relResp.releases }
        elseif ($relResp -is [System.Array]) { $results = $relResp }
        elseif ($null -ne $relResp.releaseId) { $results = @($relResp) }

        if (-not $results -or $results.Count -eq 0) {
            Write-Error "No release found matching application='$AppName' release='$RelName'"
            exit 2
        } elseif ($results.Count -eq 1) {
            $RelId = $results[0].releaseId
            Write-Host "Resolved ReleaseId: $RelId" -ForegroundColor Green
        } else {
            # Multiple matches: prefer an exact releaseName match
            $exact = $results | Where-Object { $_.releaseName -eq $RelName }
            if ($exact -and $exact.Count -ge 1) {
                # if multiple exact matches, pick the first but warn
                $RelId = $exact[0].releaseId
                if ($exact.Count -gt 1) { Write-Warning "Multiple releases found with exact name; using first releaseId $RelId" }
                else { Write-Host "Resolved ReleaseId by exact name match: $RelId" -ForegroundColor Green }
            } else {
                Write-Error "Multiple releases returned by lookup and none match releaseName exactly. Returned release names: $($results | ForEach-Object { $_.releaseName } | Sort-Object | Get-Unique -ErrorAction SilentlyContinue)"
                exit 2
            }
        }
    } catch {
        Write-Error "Release lookup failed: $_"
        exit 3
    }
}

# Upload package - chunked POSTs to the release static-scans endpoint; ReleaseId is required
try {
    $headers = @{}
    if ($token) { $headers['Authorization'] = "Bearer $token" }

    if (-not $RelId) {
        Write-Error "ReleaseId not resolved; cannot perform chunked upload without a releaseId."
        exit 2
    }

    Write-Verbose "Initiating dynamic scan endpoint for releaseId $RelId"

    $scriptFile = Split-Path -Leaf $MyInvocation.MyCommand.Path
    $scriptVersion = '1.0.0'
    try { $fv = (Get-Item $MyInvocation.MyCommand.Path).VersionInfo.FileVersion; if ($fv) { $scriptVersion = $fv } } catch { }

    # Normalize and validate ApiUrl and RelId, then construct the upload endpoint safely
    if ($null -eq $ApiUrl) {
        Write-Verbose "DEBUG: ApiUrl is $null"
        Write-Error "Fortify API URL is null; cannot construct upload endpoint."
        exit 2
    } else {
        $ApiUrl = $ApiUrl.ToString().Trim()
        if ($ApiUrl -notmatch '^[a-zA-Z]+://') {
            Write-Verbose "ApiUrl missing scheme; assuming https://" -Forre
            $ApiUrl = "https://$ApiUrl"
        }
        $ApiUrl = $ApiUrl.TrimEnd('/')
        Write-Verbose ("DEBUG: ApiUrl='{0}' (len={1}, type={2})" -f $ApiUrl, ($ApiUrl.ToString().Length), $ApiUrl.GetType().FullName)
    }

    if ($null -eq $RelId) {
        Write-Verbose "DEBUG: RelId is $null"
        Write-Error "ReleaseId is null; cannot construct upload endpoint."
        exit 2
    } else {
        $RelId = $RelId.ToString().Trim()
        Write-Verbose ("DEBUG: RelId='{0}' (type={1})" -f $RelId, $RelId.GetType().FullName)
    }

    try {
        $baseUri = [System.Uri]::new($ApiUrl)
        $scanBaseUri = [System.Uri]::new($baseUri, "/api/v3/releases/$RelId/dast-automated-scans/start-scan")
        $scanBase = $scanBaseUri.AbsoluteUri
        Write-Verbose ("DEBUG: scanBase='{0}'" -f $scanBase)
    } catch {
        Write-Verbose ("ERROR constructing scan URI from ApiUrl='{0}' and RelId='{1}': {2}" -f $ApiUrl, $RelId, $_)
        Write-Error "Failed to construct scan URI; check FodApiUrl and ReleaseId."
        exit 3
    }
    
    $query = "" # TODO: add "networkName"

    try {
        $uriBuilder = New-Object System.UriBuilder($scanBase)
        $uriBuilder.Query = $query
        $url = $uriBuilder.Uri.AbsoluteUri
    } catch {
        Write-Verbose ("ERROR building fragment URL from scanBase='{0}' and query='{1}': {2}" -f $scanBase, $query, $_)
        throw $_
    }

    Write-Verbose "Initiating scan for releaseId $RelId via $url"
    $resp = Invoke-FodApi -Method Post -Uri $url -Headers $headers
    $response = $resp

    Write-Verbose "Scan response: $($response | ConvertTo-Json -Depth 3)"
    Write-Host "Scan initiated." -ForegroundColor Green
    
    # Extract scanId from scan response (if present)
    $scanId = $null
    try {
        if ($response -ne $null) {
            if ($response.PSObject.Properties.Name -contains 'scanId') { $scanId = $response.scanId }
            elseif ($response.PSObject.Properties.Name -contains 'scan') { if ($response.scan.id) { $scanId = $response.scan.id } }
            elseif ($response.PSObject.Properties.Name -contains 'id') { $scanId = $response.id }
        }
    } catch {
        Write-Debug "Error extracting scanId from response: $_"
    }

    if ($scanId) {
        Write-Host "ScanId: $scanId" -ForegroundColor Green
    } else {
        Write-Warning "No scanId found in scan response."
    }

    # If requested, poll the scan status until Completed or Canceled
    if ($WaitFor) {
        if (-not $scanId) {
            Write-Error "Cannot wait for scan status because no scanId was returned from scan."
        } else {
            $pollUrl = "$ApiUrl/api/v3/releases/$RelId/scans/$scanId/polling-summary"
            Write-Verbose "Polling scan status at $pollUrl every $PollingInterval seconds..."
            # Attempt to update a single static table row in-place.
            # Strategy:
            # 1) Prefer .NET Console cursor positioning when supported.
            # 2) If that fails, fall back to ANSI escape sequences (widely supported by modern terminals,
            #    including VS Code integrated terminal and Windows Terminal).
            # 3) Otherwise fall back to printing the table each poll.
            $useConsoleUpdate = $false
            $useAnsi = $false
            try {
                if ($Host -and $Host.UI -and $Host.UI.RawUI) {
                    try {
                        # quick probe for .NET Console cursor APIs
                        $savedLeft = [Console]::CursorLeft
                        $savedTop = [Console]::CursorTop
                        # attempt a harmless reposition and restore
                        [Console]::SetCursorPosition($savedLeft, $savedTop)
                        $useConsoleUpdate = $true
                    } catch {
                        $useConsoleUpdate = $false
                    }
                }
            } catch { $useConsoleUpdate = $false }

            if (-not $useConsoleUpdate) {
                # Heuristic: many modern terminals (VSCode integrated, Windows Terminal, etc.) support ANSI
                # VT100 sequences. Prefer ANSI if available or as a sensible fallback.
                if ($env:WT_SESSION -or $env:TERM -or $env:TERM_PROGRAM -or $env:COLORTERM) { $useAnsi = $true } else { $useAnsi = $true }
            }

            if ($useConsoleUpdate) {
                # Print header once and remember the row to update
                $headerFmt = "{0,-36} {1,-28} {2}"
                $dataFmt = "{0,-36} {1,-28} {2}"
                $header = $headerFmt -f 'ScanId', 'Position in Queue', 'Status'
                Write-Host $header
                # Underline the header for readability (match header length)
                try {
                    $underline = ('-' * $header.Length)
                } catch {
                    $underline = '-' * ($header.ToCharArray().Length)
                }
                Write-Host $underline
                if ($useConsoleUpdate) {
                    $dataRowTop = [Console]::CursorTop
                } else {
                    # Reserve one line for the data row so ANSI updates can overwrite it
                    Write-Host ""
                }

                while ($true) {
                    try { $pollResp = Invoke-FodApi -Method Get -Uri $pollUrl -Headers $headers } catch { Write-Warning "Polling request failed: $_"; break }

                    $queuePos = $null
                    $statusVal = $null
                    try { $queuePos = $pollResp.QueuePositionWithinApplication } catch { }
                    try { $statusVal = $pollResp.AnalysisStatusTypeValue } catch { }

                    $line = $dataFmt -f $scanId, ($queuePos -as [string]), ($statusVal -as [string])
                    if ($useConsoleUpdate) {
                        try {
                            [Console]::SetCursorPosition(0, $dataRowTop)
                            $width = 80
                            try { $width = [Console]::WindowWidth } catch { }
                            if ($line.Length -lt $width) { $line = $line + (' ' * ($width - $line.Length)) }
                            Write-Host $line
                        } catch {
                            # If cursor positioning unexpectedly fails, fallback to table printing
                            $useConsoleUpdate = $false
                            $entry = [PSCustomObject]@{
                                scanId = $scanId
                                QueuePositionWithinApplication = $queuePos
                                AnalysisStatusTypeValue = $statusVal
                            }
                            $entry | Select-Object @{Name='ScanId';Expression={$_.scanId}}, @{Name='Position in Queue';Expression={$_.QueuePositionWithinApplication}}, @{Name='Status';Expression={$_.AnalysisStatusTypeValue}} | Format-Table -AutoSize
                        }
                    } elseif ($useAnsi) {
                        # Move cursor up one line and overwrite it using ANSI CSI (VT100) sequence
                        $esc = [char]27
                        try {
                            # Move up 1 line, carriage return, then write the line and clear to end
                            Write-Host ("$esc[1A`r" + $line + "$esc[K") -NoNewline
                            # Ensure a newline so subsequent non-ANSI-aware hosts still progress correctly
                            Write-Host ""
                        } catch {
                            # ANSI failed; fallback to printing the table
                            $useAnsi = $false
                            $entry = [PSCustomObject]@{
                                scanId = $scanId
                                QueuePositionWithinApplication = $queuePos
                                AnalysisStatusTypeValue = $statusVal
                            }
                            $entry | Select-Object @{Name='ScanId';Expression={$_.scanId}}, @{Name='Position in Queue';Expression={$_.QueuePositionWithinApplication}}, @{Name='Status';Expression={$_.AnalysisStatusTypeValue}} | Format-Table -AutoSize
                        }
                    } else {
                        # Fallback: print the table normally
                        $entry = [PSCustomObject]@{
                            scanId = $scanId
                            QueuePositionWithinApplication = $queuePos
                            AnalysisStatusTypeValue = $statusVal
                        }
                        $entry | Select-Object @{Name='ScanId';Expression={$_.scanId}}, @{Name='Position in Queue';Expression={$_.QueuePositionWithinApplication}}, @{Name='Status';Expression={$_.AnalysisStatusTypeValue}} | Format-Table -AutoSize
                    }

                    if ($statusVal -and ($statusVal -ieq 'Completed' -or $statusVal -ieq 'Canceled')) {
                        Write-Host "Scan $scanId finished with status: $statusVal" -ForegroundColor Green
                        break
                    }

                    Start-Sleep -Seconds $PollingInterval
                }
            } else {
                while ($true) {
                    try { $pollResp = Invoke-FodApi -Method Get -Uri $pollUrl -Headers $headers } catch { Write-Warning "Polling request failed: $_"; break }

                    $queuePos = $null
                    $statusVal = $null
                    try { $queuePos = $pollResp.QueuePositionWithinApplication } catch { }
                    try { $statusVal = $pollResp.AnalysisStatusTypeValue } catch { }

                    $entry = [PSCustomObject]@{
                        scanId = $scanId
                        QueuePositionWithinApplication = $queuePos
                        AnalysisStatusTypeValue = $statusVal
                    }
                    $entry | Select-Object @{Name='ScanId';Expression={$_.scanId}}, @{Name='Position in Queue';Expression={$_.QueuePositionWithinApplication}}, @{Name='Status';Expression={$_.AnalysisStatusTypeValue}} | Format-Table -AutoSize

                    if ($statusVal -and ($statusVal -ieq 'Completed' -or $statusVal -ieq 'Canceled')) {
                        Write-Host "Scan $scanId finished with status: $statusVal" -ForegroundColor Green
                        break
                    }

                    Start-Sleep -Seconds $PollingInterval
                }
            }
        }
    }
} catch {
    Write-Error "DAST scan failed: $_"
    exit 3
}


Write-Host "=== OpenText Core DAST Scan Complete ===" -ForegroundColor Green
