# TenantSummary

This folder contains `TenantSummary.ps1`, a PowerShell script that retrieves a Fortify on Demand (FoD) tenant summary and optionally writes CSV/Excel output and a stacked chart PNG summarizing issue severities.

## What it does
- Fetches tenant summary data from the FoD REST API (`/api/v3/tenant-summary`).
- Outputs results in one of: table (default), JSON, CSV, or Excel.
- Optionally generates a stacked chart PNG showing issue counts by severity (Critical, High, Medium, Low).

## Prerequisites
- Windows PowerShell / PowerShell Core with .NET charting/System.Drawing available.
- Network access to your FoD API endpoint.
- For Excel export: `ImportExcel` PowerShell module is preferred; if absent the script falls back to COM automation (Excel must be installed).

## Usage
Run the script from this directory or provide paths for outputs. Examples:

Password grant example:

```powershell
.\\TenantSummary.ps1 \
  -FodURL https://api.emea.fortify.com \
  -FodUsername <username> \
  -FodPassword <password> \
  -FodTenant <tenant> \
  -Graph -OutFile tenant-summary.csv -GraphOutFile tenant-summary.png -Verbose
```

Client credentials example:

```powershell
.\\TenantSummary.ps1 \
  -FodURL https://api.emea.fortify.com \
  -FodClientId <id> -FodClientSecret <secret> \
  -Graph -OutFile tenant-summary.csv -GraphOutFile tenant-summary.png -Verbose
```

## Parameters (high level)
- `-FodURL` (string): Base FoD API URL (default: https://api.ams.fortify.com).
- `-FodClientId`, `-FodClientSecret` (strings): Use client_credentials flow.
- `-FodUsername`, `-FodPassword`, `-FodTenant` (strings): Use password flow.
- `-Format` (table|json|csv|excel): Output format (default: table).
- `-OutFile`: Path for textual or CSV/Excel output.
- `-Graph` (switch): Generate stacked chart PNG.
- `-GraphOutFile`: PNG output path (defaults to `tenant-summary.png`).

## Chart behavior
- The PNG shows issue severities stacked (Critical, High, Medium, Low) with colors: Critical=Red, High=Orange, Medium=Yellow, Low=Gray.
- Series ordering is by total count (ascending) by default. You can change the stack order in the script if needed.
- Zero-value segments are hidden and segment labels show series name.

## Troubleshooting
- If chart creation fails due to missing assemblies, ensure `System.Drawing` and `System.Windows.Forms.DataVisualization` are available in your PowerShell runtime.
- For Excel COM export, Excel must be installed and accessible to the current user.
- Use `-Verbose` to get detailed execution logs.
