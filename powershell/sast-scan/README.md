FoDSASTScan (FoD SAST Upload & Scan)
====================================

Overview
--------
`FoDSASTScan.ps1` uploads a ScanCentral package (or other supported package) to Fortify on Demand (FoD) and can optionally trigger and monitor a SAST analysis for a specific release.

Key features
------------
- Authenticate to FoD using either:
  - OAuth `client_credentials` (use `FodClientId` + `FodClientSecret`), or
  - Password grant (use `FodTenant`, `FodUsername`, `FodPassword`).
- Resolve a target release by `ReleaseId` or by `ApplicationName` + `ReleaseName`.
- Upload the specified package in configurable chunk sizes (default 1 MiB) to the release `static-scans` endpoint.
- Optionally trigger a scan and poll the scan status until Completed or Canceled.
- Configuration precedence: Parameter > Environment Variable > `fortify.config` INI file.

Requirements
------------
- PowerShell (Windows PowerShell or PowerShell Core / pwsh)
- Network access to your FoD API endpoint

Configuration sources
---------------------
- Command-line parameters to the script.
- Environment variables (examples: `FOD_API_URL`, `FOD_USERNAME`, `FOD_PASSWORD`, `PACKAGE_FILE`, `FOD_CLIENT_ID`, `FOD_CLIENT_SECRET`, etc.).
- `fortify.config` INI file (the script checks the current directory and the script directory for a `fortify.config` file and reads the `[fod]` section).

Important parameters
--------------------
- `FodApiUrl` — Base FoD API URL (required). Example: `https://api.emea.fortify.com`.
- `FodUsername`, `FodPassword`, `FodTenant` — user/password authentication (tenant-qualified username `Tenant\Username`).
- `FodClientId`, `FodClientSecret` — client credentials authentication.
- `PackageName` — path to the package file to upload.
- `ApplicationName`, `ReleaseName` — used to resolve `ReleaseId` when `ReleaseId` is not provided.
- `ReleaseId` — numeric release id to target directly.
- `WaitFor` — when present, the script will poll the scan status after upload until completion.
- `PollingInterval` — seconds between poll attempts (default: 30).
- `ChunkSize` — upload chunk size in bytes (default: 1 MiB).
- `WhatIfConfig` — print the effective configuration (sources and masked secrets) and exit.

Examples
--------
Upload using client credentials:

```powershell
.\FoDSASTScan.ps1 -FodApiUrl https://api.example.com -FodClientId abc -FodClientSecret def -PackageName .\scan.zip -ReleaseId 12345 -Verbose
```

Upload by resolving application + release, then wait for scan completion:

```powershell
.\FoDSASTScan.ps1 -FodApiUrl https://api.example.com -FodUsername user -FodPassword pass -FodTenant tenant \
  -PackageName .\scan.zip -ApplicationName MyApp -ReleaseName "2025.1" -WaitFor -PollingInterval 15
```

Troubleshooting & notes
-----------------------
- Use `-WhatIfConfig` to preview which configuration values will be used and their sources; secret fields are masked unless `-Debug` is provided.
- The script logs requests and responses when `-Debug` is used.
- If uploads or API calls fail, the script prints errors and exits with a non-zero status.
