#!/usr/bin/env python3
"""
tenant_summary.py - Port of TenantSummary.ps1 (basic features)

Usage examples:
  python tenant_summary.py --fod-client-id ID --fod-client-secret SECRET --format json
  python tenant_summary.py --fod-username user --fod-password pass --fod-tenant TENANT --graph --graph-outfile out.png

This script requires `requests` and `matplotlib`.
"""
import argparse
import sys
import requests
import json
import csv
import os
from typing import List, Dict
from datetime import datetime


DEFAULT_IGNORE = (
    'staticAnalysisDVIdx,dynamicAnalysisDVIdx,mobileAnalysisDVIdx,criticalUrl,highUrl,mediumUrl,lowUrl,'
    'oneStarRatingDVIdx,twoStarRatingDVIdx,threeStarRatingDVIdx,fourStarRatingDVIdx,fiveStarRatingDVIdx'
)


def get_token(fod_url: str, client_id: str, client_secret: str, username: str, password: str, tenant: str):
    token_url = fod_url.rstrip('/') + '/oauth/token'
    if client_id and client_secret:
        data = {
            'scope': 'api-tenant',
            'grant_type': 'client_credentials',
            'client_id': client_id,
            'client_secret': client_secret,
        }
    elif username and password and tenant:
        data = {
            'scope': 'api-tenant',
            'grant_type': 'password',
            'username': f"{tenant}\\{username}",
            'password': password,
        }
    else:
        raise SystemExit('Please supply either (client id and client secret) OR (tenant, username and password)')

    resp = requests.post(token_url, data=data, headers={'Content-Type': 'application/x-www-form-urlencoded'})
    try:
        resp.raise_for_status()
    except requests.HTTPError as e:
        print('Token request failed:', resp.text, file=sys.stderr)
        raise SystemExit(1)
    tk = resp.json()
    if 'access_token' not in tk:
        print('Token response missing access_token', file=sys.stderr)
        raise SystemExit(1)
    return tk['access_token']


def fetch_summary(fod_url: str, token: str, days_from: int = None, sdlc_status: str = None):
    url = fod_url.rstrip('/') + '/api/v3/tenant-summary'
    headers = {'Authorization': f'Bearer {token}', 'Accept': 'application/json'}
    params = {}
    if days_from is not None:
        params['daysFrom'] = str(days_from)
    if sdlc_status:
        params['sdlcStatus'] = sdlc_status
    resp = requests.get(url, headers=headers, params=params if params else None)
    try:
        resp.raise_for_status()
    except requests.HTTPError:
        print('API request failed:', resp.text, file=sys.stderr)
        raise SystemExit(1)
    return resp.json()


def filter_rows(rows: List[Dict], ignore_fields: List[str]) -> List[Dict]:
    out = []
    for r in rows:
        nr = {k: v for k, v in r.items() if k not in ignore_fields}
        out.append(nr)
    return out


def write_json(obj, out_file: str = None):
    s = json.dumps(obj, indent=2)
    if out_file:
        with open(out_file, 'w', encoding='utf-8') as f:
            f.write(s)
    else:
        print(s)


def write_csv(rows: List[Dict], out_file: str = None):
    if not rows:
        print('No rows to write')
        return
    fieldnames = list({k for r in rows for k in r.keys()})
    if out_file:
        fh = open(out_file, 'w', newline='', encoding='utf-8')
    else:
        fh = sys.stdout
    writer = csv.DictWriter(fh, fieldnames=fieldnames)
    writer.writeheader()
    for r in rows:
        writer.writerow({k: ('' if r.get(k) is None else r.get(k)) for k in fieldnames})
    if out_file:
        fh.close()


def print_table(rows: List[Dict]):
    if not rows:
        print('No rows')
        return
    # simple columnar print
    keys = list({k for r in rows for k in r.keys()})
    widths = {k: max(len(str(k)), *(len(str(r.get(k,''))) for r in rows)) for k in keys}
    sep = ' | '
    hdr = sep.join(k.ljust(widths[k]) for k in keys)
    print(hdr)
    print('-' * len(hdr))
    for r in rows:
        print(sep.join(str(r.get(k,'')).ljust(widths[k]) for k in keys))


def build_chart_data(first_orig: Dict):
    # gather counts with safe defaults
    static = int(first_orig.get('staticAnalysisCount') or 0)
    dynamic = int(first_orig.get('dynamicAnalysisCount') or 0)
    mobile = int(first_orig.get('mobileAnalysisCount') or 0)
    critical = int(first_orig.get('criticalCount') or 0)
    high = int(first_orig.get('highCount') or 0)
    medium = int(first_orig.get('mediumCount') or 0)
    low = int(first_orig.get('lowCount') or 0)
    # Create four group categories and repeat the same values for each group
    categories = ['< 360 days', '< 270 days', '< 180 days', '< 90 days']
    def rep(v):
        return [v] * len(categories)

    series = {
        'Static': rep(static),
        'Dynamic': rep(dynamic),
        'Mobile': rep(mobile),
        'Critical': rep(critical),
        'High': rep(high),
        'Medium': rep(medium),
        'Low': rep(low),
    }
    return categories, series


def collect_counts_from_summary(summary: Dict) -> Dict[str, int]:
    # summary may be a dict with items or a single object; mimic PowerShell's Select-Object -First 1 behavior
    rows = summary.get('items') if isinstance(summary, dict) and 'items' in summary else [summary]
    first = rows[0] if rows else {}
    def val(k):
        try:
            return int(first.get(k) or 0)
        except Exception:
            return 0

    return {
        'Static': val('staticAnalysisCount'),
        'Dynamic': val('dynamicAnalysisCount'),
        'Mobile': val('mobileAnalysisCount'),
        'Critical': val('criticalCount'),
        'High': val('highCount'),
        'Medium': val('mediumCount'),
        'Low': val('lowCount'),
    }


def gather_series_for_days(fod_url: str, token: str, days_list: List[int], sdlc_status: str = None):
    # Ensure days_list is in ascending order so we can compute per-period (non-overlapping) counts
    days_sorted = sorted(days_list)
    cum_counts_list = []
    metrics = ['Static', 'Dynamic', 'Mobile', 'Critical', 'High', 'Medium', 'Low']
    for d in days_sorted:
        print(f'Fetching tenant-summary daysFrom={d}...')
        summ = fetch_summary(fod_url, token, days_from=d, sdlc_status=sdlc_status)
        counts = collect_counts_from_summary(summ)
        cum_counts_list.append(counts)

    # Compute per-period counts: first bucket = cum[0], subsequent = cum[i] - cum[i-1]
    # For the final bucket, optionally fetch an extra cumulative at next_d and use (next_cum - cum_last)
    per_series = {m: [] for m in metrics}
    extra_counts = None
    if len(days_sorted) >= 2:
        # derive next upper bound as max + (max - prev)
        max_d = days_sorted[-1]
        prev_d = days_sorted[-2]
        next_d = max_d + (max_d - prev_d)
        try:
            print(f'Fetching tenant-summary daysFrom={next_d} for extended last-bucket calculation...')
            extra_summary = fetch_summary(fod_url, token, days_from=next_d, sdlc_status=sdlc_status)
            extra_counts = collect_counts_from_summary(extra_summary)
        except Exception:
            extra_counts = None

    for i, d in enumerate(days_sorted):
        for m in metrics:
            cur = cum_counts_list[i].get(m, 0)
            prev = cum_counts_list[i-1].get(m, 0) if i > 0 else 0
            if i == len(days_sorted) - 1 and extra_counts is not None:
                # last bucket: use extra_counts - cur (counts between max_d and next_d)
                val = max(0, extra_counts.get(m, 0) - cur)
            else:
                val = max(0, cur - prev)
            per_series[m].append(val)

    # Build descriptive category labels for each non-overlapping bucket
    categories = []
    for i, d in enumerate(days_sorted):
        if i == 0:
            categories.append(f"days < {d}")
        else:
            categories.append(f"{days_sorted[i-1]} < days < {d}")

    return categories, per_series


def render_chart(categories, series, out_file, width=9, height=6):
    try:
        import matplotlib
        import matplotlib.pyplot as plt
    except Exception as e:
        print('matplotlib is required to render charts:', e, file=sys.stderr)
        raise SystemExit(1)

    labels = categories
    x = list(range(len(labels)))

    # colors roughly matching the PowerShell palette
    color_map = {
        'Critical': '#E64C3C',
        'High': '#F1A92C',
        'Medium': '#F4D03A',
        'Low': '#7f8c8d',
        'Static': '#52A0D0',
        'Dynamic': '#9B59B6',
        'Mobile': '#2ECC71',
    }

    fig, ax = plt.subplots(figsize=(width, height))
    bottom = [0] * len(labels)
    # compute totals for thresholding label placement
    totals = [0] * len(labels)
    for name in series:
        for i, v in enumerate(series[name]):
            totals[i] += v
    max_total = max(totals) if totals else 1
    label_threshold = max_total * 0.05
    for name, vals in series.items():
        bars = ax.bar(x, vals, bottom=bottom, label=f"{name}", color=color_map.get(name))
        # add value labels on each segment
        for rect, v in zip(bars, vals):
            if v == 0:
                continue
            height = rect.get_height()
            y = rect.get_y() + height / 2
            # if segment is large enough, put white label inside, else black above
            if height >= label_threshold:
                ax.text(rect.get_x() + rect.get_width() / 2, y, str(v), ha='center', va='center', color='white', fontsize=8)
            else:
                ax.text(rect.get_x() + rect.get_width() / 2, rect.get_y() + height + max_total * 0.01, str(v), ha='center', va='bottom', color='black', fontsize=8)
        bottom = [b + v for b, v in zip(bottom, vals)]

    ax.set_xticks(x)
    ax.set_xticklabels(labels)

    ax.set_ylabel('Count')
    ax.set_title('Tenant Summary')
    ax.legend()
    plt.tight_layout()
    out_dir = os.path.dirname(out_file)
    if out_dir and not os.path.exists(out_dir):
        os.makedirs(out_dir, exist_ok=True)
    fig.savefig(out_file)
    plt.close(fig)


def render_combo_chart(categories, series, out_file, width=10, height=6):
    try:
        import matplotlib.pyplot as plt
    except Exception as e:
        print('matplotlib is required to render charts:', e, file=sys.stderr)
        raise SystemExit(1)

    # Define which series are issues (stacked bars) and which are analyses (lines plotted on secondary axis)
    issue_names = ['Critical', 'High', 'Medium', 'Low']
    analysis_names = ['Static', 'Dynamic', 'Mobile']

    fig, ax = plt.subplots(figsize=(width, height))

    # colors for segments
    color_map = {
        'Critical': '#E64C3C',
        'High': '#F1A92C',
        'Medium': '#F4D03A',
        'Low': '#7f8c8d',
        'Static': '#52A0D0',
        'Dynamic': '#9B59B6',
        'Mobile': '#2ECC71',
    }

    # Use numeric x positions for precise label placement
    x = list(range(len(categories)))
    # Stack issues as bars (bottom)
    bottom = [0] * len(categories)
    totals = [0] * len(categories)
    for name in issue_names + analysis_names:
        for i, v in enumerate(series.get(name, [0] * len(categories))):
            totals[i] += v
    max_total = max(totals) if totals else 1
    label_threshold = max_total * 0.05
    for name in issue_names:
        vals = series.get(name, [0] * len(categories))
        col = color_map.get(name)
        bars = ax.bar(x, vals, bottom=bottom, label=f"{name}", color=col, zorder=2)
        # add labels for each bar segment
        for rect, v in zip(bars, vals):
            if v == 0:
                continue
            height = rect.get_height()
            y = rect.get_y() + height / 2
            if height >= label_threshold:
                ax.text(rect.get_x() + rect.get_width() / 2, y, str(v), ha='center', va='center', color='white', fontsize=8, zorder=4)
            else:
                ax.text(rect.get_x() + rect.get_width() / 2, rect.get_y() + height + max_total * 0.01, str(v), ha='center', va='bottom', color='black', fontsize=8, zorder=4)
        bottom = [b + v for b, v in zip(bottom, vals)]

    ax.set_ylabel('Issue Count')
    ax.set_title('Tenant Summary — Issues (stacked) + Analysis Types (lines)')
    ax.set_xlabel(f'CY {datetime.now().year}')
    # restore category labels on x-axis
    ax.set_xticks(x)
    ax.set_xticklabels(categories)

    # Secondary axis for analyses (scan types) - plot as lines on top
    ax2 = ax.twinx()
    for name in analysis_names:
        vals = series.get(name, [0] * len(categories))
        col = color_map.get(name)
        # plot using numeric x so we can place labels
        ax2.plot(x, vals, marker='o', label=f"{name}", color=col, linewidth=2, zorder=5)
        ax2.scatter(x, vals, color=col, zorder=6)
        # label each marker with its value
        for xi, v in zip(x, vals):
            if v == 0:
                continue
            ax2.text(xi, v, str(v), ha='center', va='bottom', color=col, fontsize=8, zorder=7)

    ax2.set_ylabel('Analysis Count')

    # Slightly reduce bar alpha so lines are clearly visible
    for patch in ax.patches:
        patch.set_alpha(0.95)

    # Combine legends from both axes (without counts)
    handles1, labels1 = ax.get_legend_handles_labels()
    handles2, labels2 = ax2.get_legend_handles_labels()
    ax.legend(handles1 + handles2, labels1 + labels2, loc='upper right')

    plt.tight_layout()
    out_dir = os.path.dirname(out_file)
    if out_dir and not os.path.exists(out_dir):
        os.makedirs(out_dir, exist_ok=True)
    fig.savefig(out_file)
    plt.close(fig)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--fod-url', default='https://api.ams.fortify.com')
    p.add_argument('--fod-client-id')
    p.add_argument('--fod-client-secret')
    p.add_argument('--fod-username')
    p.add_argument('--fod-password')
    p.add_argument('--fod-tenant')
    p.add_argument('--format', choices=['table', 'json', 'csv', 'excel'], default='table')
    p.add_argument('--outfile')
    p.add_argument('--graph', action='store_true')
    p.add_argument('--combo-graph', action='store_true', help='Create combined stacked-issues bar chart and scan-type line chart with secondary axis')
    p.add_argument('--graph-outfile')
    p.add_argument('--buckets', help='Comma-separated daysFrom values for multi-period charts, e.g. 90,180,270,360')
    p.add_argument('--days-from', type=int, default=90, help='Days back to look (default: 90)')
    p.add_argument('--sdlc-status', choices=['Production','QA','Development','Retired'], help='SDLC Status to filter (no default)')
    p.add_argument('--ignore-fields', default=DEFAULT_IGNORE)
    args = p.parse_args()

    token = get_token(args.fod_url, args.fod_client_id, args.fod_client_secret, args.fod_username, args.fod_password, args.fod_tenant)
    summary = fetch_summary(args.fod_url, token, days_from=args.days_from, sdlc_status=args.sdlc_status)

    rows = summary.get('items') if isinstance(summary, dict) and 'items' in summary else [summary]
    ignore = [s.strip() for s in args.ignore_fields.split(',')] if args.ignore_fields else []
    filtered = filter_rows(rows, ignore)

    # Normalize outfile paths to absolute
    outpath = None
    if args.outfile:
        outpath = os.path.abspath(args.outfile)

    # If not graphing, inform user and output the filtered summary in the requested format
    if not args.graph and not args.combo_graph:
        sdlc_note = f" (SDLC: {args.sdlc_status})" if args.sdlc_status else ''
        print(f"Retrieving data from last {args.days_from} days{sdlc_note}")
        if args.format == 'json':
            print(f'Outputting json summary with {len(filtered)} rows, ignoring fields: {ignore}')
            if isinstance(summary, dict) and 'items' in summary:
                out_summary = dict(summary)
                out_summary['items'] = filtered
                write_json(out_summary, outpath)
            else:
                write_json(filtered, outpath)
        elif args.format == 'csv':
            print(f'Outputting CSV summary with {len(filtered)} rows, ignoring fields: {ignore}')
            write_csv(filtered, outpath)
        elif args.format == 'excel':
            if not outpath:
                raise SystemExit('Excel output requires --outfile to be specified')
            try:
                from openpyxl import Workbook
            except Exception:
                raise SystemExit('openpyxl is required for excel output')
            print(f'Outputting Excel summary with {len(filtered)} rows, ignoring fields: {ignore}')
            wb = Workbook()
            ws = wb.active
            if filtered:
                cols = list({k for r in filtered for k in r.keys()})
                ws.append(cols)
                for r in filtered:
                    ws.append([r.get(c, '') for c in cols])
            wb.save(outpath)
        else:
            print_table(filtered)

    # Graph handling
    if args.graph or args.combo_graph:
        print(f'Generating graph(s) for tenant summary with SDLC status filter: {args.sdlc_status or "None"}')
        # parse buckets if provided (use ascending order inside gather)
        buckets = None
        if args.buckets:
            try:
                buckets = [int(x.strip()) for x in args.buckets.split(',') if x.strip()]
                if not buckets:
                    buckets = None
            except Exception:
                print('Invalid --buckets value; must be comma-separated integers, e.g. 90,180,270,360', file=sys.stderr)
                raise SystemExit(2)

        # If combo_graph requested, perform multi-period collection
        if args.combo_graph:
            days_list = buckets if buckets is not None else [90, 180, 270, 360]
            categories, series = gather_series_for_days(args.fod_url, token, days_list, sdlc_status=args.sdlc_status)
            gout_combo = os.path.abspath(args.graph_outfile) if args.graph_outfile else os.path.abspath('tenant-summary-combo.png')
            render_combo_chart(categories, series, gout_combo)
            print(f'Wrote combo graph to {gout_combo}')
            # if user also asked for --graph, render the simple stacked-chart view over the same collected buckets
            if args.graph:
                gout = os.path.abspath(args.graph_outfile) if args.graph_outfile else os.path.abspath('tenant-summary.png')
                render_chart(categories, series, gout)
                print(f'Wrote graph to {gout}')
        else:
            # Only --graph requested: single-period chart using --days-from or first bucket if provided
            if buckets is not None:
                use_days = buckets[0]
            else:
                use_days = args.days_from
            print(f'Fetching tenant-summary for daysFrom={use_days}...')
            single_summary = fetch_summary(args.fod_url, token, days_from=use_days, sdlc_status=args.sdlc_status)
            rows_single = single_summary.get('items') if isinstance(single_summary, dict) and 'items' in single_summary else [single_summary]
            first_orig = rows_single[0] if rows_single else {}
            categories, series = build_chart_data(first_orig)
            gout = os.path.abspath(args.graph_outfile) if args.graph_outfile else os.path.abspath('tenant-summary.png')
            render_chart(categories, series, gout)
            print(f'Wrote graph to {gout}')


if __name__ == '__main__':
    main()
