Authenticate.ps1
=================

Description
-----------
An example PowerShell script that authenticates to Fortify on Demand (FoD) using either the OAuth2 `password` grant (tenant-qualified username) or `client_credentials` grant, then calls the FoD REST API. The script includes an example of paging the `/api/v3/applications` endpoint (uses `limit`/`offset`) and prints combined JSON results.

Requirements
------------
- PowerShell 7+ recommended (works with Windows PowerShell where `Invoke-RestMethod` supports HTTPS)
- Network access to your FoD API endpoint

What it does
------------
- Obtains an access token from `<FodURL>/oauth/token` using either:
  - Client credentials: `-FodClientId` and `-FodClientSecret`
  - Password grant: `-FodTenant`, `-FodUsername`, and `-FodPassword` (username is qualified as `Tenant\Username`)
- Calls `/api/v3/applications` with `limit` and `offset` to page results (max `limit` is 50).
- Collects pages until `totalCount` items are retrieved (if `totalCount` is present) or until a page returns no items.
- Outputs the combined collection as JSON to stdout.

Progress and output
-------------------
- Without `-Verbose`, the script prints a short "Fetching applications " header and a dot (`.`) for each API call (token + each page) so progress is visible.
- With `-Verbose`, the script prints detailed request URIs and does not print dot progress.
- The final combined results are printed as JSON. Use PowerShell redirection to save the output, e.g. `> applications.json`.

Parameters
----------
- `-FodURL` (string) : Base FoD API URL. Defaults to `https://api.ams.fortify.com`.
- `-FodClientId` (string) : Client ID (for client_credentials flow).
- `-FodClientSecret` (string) : Client secret (for client_credentials flow).
- `-FodUsername` (string) : Username (for password flow).
- `-FodPassword` (string) : Password (for password flow).
- `-FodTenant` (string) : Tenant code (required for password flow).
- `-Verbose` : Enable verbose logging (prints full request URIs and disables dot-progress).

Examples
--------
Password grant (tenant-qualified username):

```powershell
.\Authenticate.ps1 -FodURL https://api.emea.fortify.com -FodUsername klee2 -FodPassword 'YourPassword' -FodTenant yourTenant
```

Client credentials grant:

```powershell
.\Authenticate.ps1 -FodURL https://api.emea.fortify.com -FodClientId 'client-id' -FodClientSecret 'client-secret'
```

Save output to a file:

```powershell
.\Authenticate.ps1 -FodURL https://api.emea.fortify.com -FodUsername klee2 -FodPassword 'YourPassword' -FodTenant yourTenant > applications.json
```

Notes
-----
- The paging example uses `limit=50` and `offset` query parameters. The first page's response includes `totalCount` when available, which the script uses to determine how many additional pages to request.
- If the API returns results under a different property name, the script heuristically checks for common names (`items`, `data`, `content`, `results`) and also handles a plain JSON array response.
- If you want CSV output, pipe the JSON into `ConvertFrom-Json` and then `Export-Csv` with the desired properties.

