# Fortify on Demand API Examples

This repository contains example scripts for interacting with the Fortify on Demand (FoD) API using
multiple languages and platforms. Each language directory includes a small README with usage notes.

## Bash

- **Authenticate**: [bash/authenticate/authenticate.sh](bash/authenticate/authenticate.sh) — Authenticate to FoD and page `/api/v3/applications` (prints combined JSON). See [bash/authenticate/README.md](bash/authenticate/README.md).
- **SBOM import**: [bash/sbom-import/fod-sbom-import.sh](bash/sbom-import/fod-sbom-import.sh) — Example script for importing a CycloneDX SBOM. See [bash/sbom-import/README.md](bash/sbom-import/README.md).

## PowerShell

- **Authenticate**: [powershell/authenticate/Authenticate.ps1](powershell/authenticate/Authenticate.ps1) — PowerShell example that obtains an access token and pages `/api/v3/applications`. See [powershell/authenticate/README.md](powershell/authenticate/README.md).
- **Tenant summary**: [powershell/tenant-summary/TenantSummary.ps1](powershell/tenant-summary/TenantSummary.ps1) — Generate tenant-level summaries and optional graphs. See [powershell/tenant-summary/README.md](powershell/tenant-summary/README.md).
- **SAST scan / upload**: [powershell/sast-scan/FoDSASTScan.ps1](powershell/sast-scan/FoDSASTScan.ps1) — Upload a ScanCentral package, trigger SAST, and optionally poll for completion. See [powershell/sast-scan/README.md](powershell/sast-scan/README.md).

## Python

- **Authenticate**: [python/authenticate/authenticate.py](python/authenticate/authenticate.py) — Python equivalent of the PowerShell authenticate script; supports both token flows and paging. See [python/authenticate/README.md](python/authenticate/README.md).

---

Maintainer: kadraman (klee2@opentext.com)