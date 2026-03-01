# Tenant Summary (Python)

This Python script fetches the Fortify on Demand tenant summary and can output JSON/CSV/table/Excel data and generate a PNG stacked chart using Matplotlib.

### Files
- `tenant_summary.py` — main script
- `requirements.txt` — Python dependencies

## Prerequisites
- Python 3.8+
- Install dependencies (recommended inside a virtual environment):

Windows PowerShell:
```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

macOS / Linux:
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Usage

Client Credentials grant:

```
python tenant_summary.py --fod-client-id YOUR_ID --fod-client-secret YOUR_SECRET --format json
```

Password grant:
```bash
python tenant_summary.py --fod-username USER --fod-password PASS --fod-tenant TENANT --format table
```

Custom buckets example:
```bash
python tenant_summary.py --fod-client-id ID --fod-client-secret SECRET --combo-graph --buckets 30,60,90 --graph-outfile custom-combo.png
```

Output formats

- `--format json|csv|table|excel` — choose output format when not graphing. For `excel` provide `--outfile` (requires `openpyxl`).

### Graphing

- `--graph` — single-period PNG chart. Uses `--days-from` (default 90) as the period for the single chart. Example:
```bash
python tenant_summary.py --fod-client-id ID --fod-client-secret SECRET --graph --graph-outfile tenant-summary.png
```

- `--combo-graph` — multi-period chart across predefined buckets. The script performs multiple `/api/v3/tenant-summary` calls (ascending daysFrom values) and computes non-overlapping per-period counts; it also attempts an extra fetch to compute an extended final bucket. Example:
```bash
python tenant_summary.py --fod-client-id ID --fod-client-secret SECRET --combo-graph --graph-outfile tenant-summary-combo.png
```

### Flags

- `--days-from N` — used by `--graph` and for the initial fetch when not graphing (default: 90).
- `--sdlc-status` — filter by SDLC status; one of `Production, QA, Development, Retired`.
- `--graph-outfile` — path to write PNG chart(s).
- `--ignore-fields` — comma-separated fields to omit from table/CSV/JSON output (matches PowerShell defaults).
 - `--buckets` — comma-separated daysFrom values for multi-period combo charts, e.g. `90,180,270,360`.

## Behavior notes

- When no graph option is provided the script performs a single `/tenant-summary` call using `--days-from` and prints the filtered results; it prints a status line like `Retrieving data from last 90 days` so you know what query ran.
- `--graph` runs one `/tenant-summary` call for `--days-from` and renders a single stacked chart.
- `--combo-graph` runs multiple `/tenant-summary` calls for the buckets (default buckets: 90,180,270,360 days) in ascending order, computes per-period (non-overlapping) counts (bucket0 = cum(90), bucket1 = cum(180)-cum(90), ...), attempts an extra fetch at `next = max + (max - prev)` to compute the final bucket as `cum(next) - cum(max)`, and renders one bar/point per bucket.
- X-axis labels for combo charts use the mathematical form, e.g. `days < 90`, `90 < days < 180`, `180 < days < 270`, `270 < days < 360` and charts include `CY <year>` as the axis title.
- Legends do not include per-series counts; numeric labels are shown on bar segments and line markers instead.

## Quick examples

Single-period table/JSON:
```bash
python tenant_summary.py --fod-client-id ID --fod-client-secret SECRET --format json
```

Single-period PNG chart:
```bash
python tenant_summary.py --fod-client-id ID --fod-client-secret SECRET --graph --graph-outfile tenant-summary.png
```

Multi-period combo chart:
```bash
python tenant_summary.py --fod-client-id ID --fod-client-secret SECRET --combo-graph --graph-outfile tenant-summary-combo.png
```

## Questions or improvements?
Open an issue or request additional features (CLI flags, different chart styles, custom buckets).
