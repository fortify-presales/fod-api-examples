<#
.SYNOPSIS
    An example of authenticating with Fortify on Demand and executing API calls.
.DESCRIPTION
    Retrieves a bearer token (client_credentials or password grant) and calls
    the /api/v3/applications endpoint. Outputs JSON to stdout.
.PARAMETER FodURL
    Base FoD API URL (defaults to https://api.ams.fortify.com)
.PARAMETER FodClientId
    Client ID for client_credentials token flow.
.PARAMETER FodClientSecret
    Client Secret for client_credentials token flow.
.PARAMETER FodUsername
    Username for password grant.
.PARAMETER FodPassword
    Password for password grant.
.PARAMETER FodTenant
    Tenant code (required for password grant; username is qualified as Tenant\Username)
#>

[CmdletBinding(DefaultParameterSetName='Auto')]
param(
    [string]$FodURL = 'https://api.ams.fortify.com',
    [string]$FodClientId,
    [string]$FodClientSecret,
    [string]$FodUsername,
    [string]$FodPassword,
    [string]$FodTenant
)

# Normalize and validate FodURL early to avoid malformed URIs (trim whitespace and trailing slash)
$FodURL = $FodURL.Trim()
if ($FodURL.EndsWith('/')) { $FodURL = $FodURL.TrimEnd('/') }
try { [void]([Uri]$FodURL) } catch { Write-Error "FodURL '$FodURL' is not a valid URI: $($_.Exception.Message)"; exit 1 }

# Detect whether -Verbose was provided; used to suppress dot-progress when verbose
$VerboseRequested = $PSBoundParameters.ContainsKey('Verbose')

# Print a single dot without newline when not verbose
function Show-Dot {
    if (-not $VerboseRequested) { Write-Host -NoNewline '.' }
}

function Convert-FormHashToString {
    param(
        [hashtable]$Form
    )
    $pairs = @()
    foreach ($k in $Form.Keys) {
        $v = $Form[$k]
        $enc = [System.Net.WebUtility]::UrlEncode([string]$v)
        $pairs += "$k=$enc"
    }
    return ($pairs -join '&')
}

try {
    if ($FodClientId -and $FodClientSecret) {
        Write-Verbose 'Using client_credentials token flow.'
        $form = @{ 
            scope = 'api-tenant'
            grant_type = 'client_credentials'
            client_id = $FodClientId
            client_secret = $FodClientSecret
        }
        $body = Convert-FormHashToString -Form $form
        $tokenUri = "$FodURL/oauth/token"
        Write-Verbose "Requesting token at $tokenUri"
        $tokenResp = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } elseif ($FodUsername -and $FodPassword -and $FodTenant) {
        Write-Verbose 'Using password token flow (username/password).' 
        $qualifiedUser = "$FodTenant\$FodUsername"
        $form = @{
            scope = 'api-tenant'
            grant_type = 'password'
            username = $qualifiedUser
            password = $FodPassword
        }
        $body = Convert-FormHashToString -Form $form
        $tokenUri = "$FodURL/oauth/token"
        Write-Verbose "Requesting token at $tokenUri"
        $tokenResp = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } else {
        throw 'Please supply either (FodClientId and FodClientSecret) OR (FodTenant, FodUsername and FodPassword).'
    }

    if (-not $tokenResp.access_token) {
        throw 'Token response did not contain an access_token.'
    }
    $accessToken = $tokenResp.access_token

    $headers = @{ 'Authorization' = "Bearer $accessToken"; 'Accept' = 'application/json' }
    # Start paging at the first page using limit and offset (avoid calling the base URI without params)
    $uri = "$FodURL/api/v3/applications"

    # Example: paging through /api/v3/applications
    # The API supports a `limit` (max 50) and `offset` query parameters.
    # The first response includes `totalCount` which can be used to page until all records are retrieved.
    $limit = 50
    $offset = 0
    $allItems = @()

    # helper to extract the collection from a page response (handles a few common shapes)
    function Get-PageItems {
        param($resp)
        if ($null -eq $resp) { return @() }
        if ($resp -is [System.Collections.IEnumerable] -and -not ($resp -is [string])) { return ,$resp }
        $names = $resp.PSObject.Properties.Name
        if ($names -contains 'items') { return $resp.items }
        if ($names -contains 'data') { return $resp.data }
        if ($names -contains 'content') { return $resp.content }
        if ($names -contains 'results') { return $resp.results }
        return @()
    }

    # Get first page
    if (-not $VerboseRequested) { Write-Host "Fetching applications " -NoNewline }
    $firstUri = "$($uri)?limit=$limit&offset=$offset"
    Write-Verbose "Requesting $firstUri"
    Show-Dot
    $firstResp = Invoke-RestMethod -Uri $firstUri -Headers $headers -Method Get -ErrorAction Stop
    $pageItems = Get-PageItems -resp $firstResp
    $allItems += $pageItems

    $totalCount = $null
    if ($firstResp -and ($firstResp.PSObject.Properties.Name -contains 'totalCount')) {
        $totalCount = [int]$firstResp.totalCount
    }

    if ($totalCount) {
        while ($allItems.Count -lt $totalCount) {
            $offset = $allItems.Count
            $pageUri = "$($uri)?limit=$limit&offset=$offset"
            Write-Verbose "Requesting $pageUri"
            Show-Dot
            $resp = Invoke-RestMethod -Uri $pageUri -Headers $headers -Method Get -ErrorAction Stop
            $pageItems = Get-PageItems -resp $resp
            if (-not $pageItems -or $pageItems.Count -eq 0) { break }
            $allItems += $pageItems
        }
    } else {
        # If totalCount isn't provided, keep paging until an empty page is returned
        while ($pageItems -and $pageItems.Count -gt 0) {
            $offset = $allItems.Count
            $pageUri = "$($uri)?limit=$limit&offset=$offset"
            Write-Verbose "Requesting $pageUri"
            Show-Dot
            $resp = Invoke-RestMethod -Uri $pageUri -Headers $headers -Method Get -ErrorAction Stop
            $pageItems = Get-PageItems -resp $resp
            if (-not $pageItems -or $pageItems.Count -eq 0) { break }
            $allItems += $pageItems
        }
    }

    # Output combined results (adjust depth if objects are nested)
    if (-not $VerboseRequested) { Write-Host '' }
    $allItems | ConvertTo-Json -Depth 5

} catch {
    # TODO: handle rate limit errors (HTTP 429) by parsing the response and waiting the required time before retrying

    Write-Error "Failed: $($_.Exception.Message)"
    try { Write-Error ($_.Exception | Format-List * -Force | Out-String) } catch {}
    if ($_.Exception.Response) {
        try {
            $body = $_.Exception.Response | Select-Object -ExpandProperty Content -ErrorAction Stop
            Write-Error "Response: $body"
        } catch { }
    }
    exit 1
}
