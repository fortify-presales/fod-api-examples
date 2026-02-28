#!/usr/bin/env python3
"""
authenticate.py

An example of authenticating with Fortify on Demand and executing API calls.

Retrieves a bearer token (client_credentials or password grant) and calls
the /api/v3/applications endpoint. Outputs JSON to stdout.

- Supports client_credentials or password grant
- Pages /api/v3/applications using limit (50) and offset
- Prints progress dots when not run with --verbose
- Outputs combined JSON array to stdout
"""

import argparse
import json
import sys
import requests
from typing import Any, Dict, List


def normalize_url(u: str) -> str:
    u = u.strip()
    if u.endswith('/'):
        u = u[:-1]
    return u


def get_page_items(resp_json: Any) -> List[Any]:
    if resp_json is None:
        return []
    if isinstance(resp_json, list):
        return resp_json
    if isinstance(resp_json, dict):
        for key in ("items", "data", "content", "results"):
            if key in resp_json and isinstance(resp_json[key], (list,)):
                return resp_json[key]
    return []


def main():
    p = argparse.ArgumentParser(description='Authenticate to Fortify on Demand and page /api/v3/applications')
    p.add_argument('--fod-url', default='https://api.ams.fortify.com', help='Base FoD API URL')
    p.add_argument('--fod-client-id', help='Client ID for client_credentials flow')
    p.add_argument('--fod-client-secret', help='Client secret for client_credentials flow')
    p.add_argument('--fod-username', help='Username for password grant')
    p.add_argument('--fod-password', help='Password for password grant')
    p.add_argument('--fod-tenant', help='Tenant code for password grant')
    p.add_argument('--verbose', action='store_true', help='Enable verbose logging')

    args = p.parse_args()

    fod_url = normalize_url(args.fod_url)

    # validate credentials
    use_client = bool(args.fod_client_id and args.fod_client_secret)
    use_password = bool(args.fod_username and args.fod_password and args.fod_tenant)
    if not (use_client or use_password):
        p.error('Provide either --fod-client-id and --fod-client-secret OR --fod-tenant, --fod-username and --fod-password')

    session = requests.Session()

    token_url = f"{fod_url}/oauth/token"
    if args.verbose:
        print(f"Requesting token at {token_url}")
    # show a dot for the token request if not verbose
    if not args.verbose:
        print('Fetching applications ', end='', flush=True)

    if use_client:
        form = {
            'scope': 'api-tenant',
            'grant_type': 'client_credentials',
            'client_id': args.fod_client_id,
            'client_secret': args.fod_client_secret,
        }
    else:
        qualified_user = f"{args.fod_tenant}\\{args.fod_username}"
        form = {
            'scope': 'api-tenant',
            'grant_type': 'password',
            'username': qualified_user,
            'password': args.fod_password,
        }

    try:
        # requests will encode form data
        if not args.verbose:
            print('.', end='', flush=True)
        r = session.post(token_url, data=form, headers={'Accept': 'application/json'})
        r.raise_for_status()
        token_resp = r.json()
    except requests.RequestException as e:
        print(f"Failed to get token: {e}", file=sys.stderr)
        sys.exit(1)

    access_token = token_resp.get('access_token')
    if not access_token:
        print('Token response did not contain an access_token', file=sys.stderr)
        sys.exit(1)

    headers = {'Authorization': f"Bearer {access_token}", 'Accept': 'application/json'}

    base_uri = f"{fod_url}/api/v3/applications"
    limit = 50
    offset = 0
    all_items: List[Any] = []

    try:
        # first page
        first_url = f"{base_uri}?limit={limit}&offset={offset}"
        if args.verbose:
            print(f"Requesting {first_url}")
        if not args.verbose:
            print('.', end='', flush=True)
        r = session.get(first_url, headers=headers)
        r.raise_for_status()
        first_json = r.json()
        page_items = get_page_items(first_json)
        all_items.extend(page_items)

        total_count = None
        if isinstance(first_json, dict) and 'totalCount' in first_json:
            try:
                total_count = int(first_json['totalCount'])
            except Exception:
                total_count = None

        # page using totalCount if available
        if total_count is not None:
            while len(all_items) < total_count:
                offset = len(all_items)
                page_url = f"{base_uri}?limit={limit}&offset={offset}"
                if args.verbose:
                    print(f"Requesting {page_url}")
                if not args.verbose:
                    print('.', end='', flush=True)
                r = session.get(page_url, headers=headers)
                r.raise_for_status()
                page_json = r.json()
                page_items = get_page_items(page_json)
                if not page_items:
                    break
                all_items.extend(page_items)
        else:
            # unknown totalCount: continue until no more items
            while page_items:
                offset = len(all_items)
                page_url = f"{base_uri}?limit={limit}&offset={offset}"
                if args.verbose:
                    print(f"Requesting {page_url}")
                if not args.verbose:
                    print('.', end='', flush=True)
                r = session.get(page_url, headers=headers)
                r.raise_for_status()
                page_json = r.json()
                page_items = get_page_items(page_json)
                if not page_items:
                    break
                all_items.extend(page_items)

    except requests.RequestException as e:
        print(f"Request failed: {e}", file=sys.stderr)
        sys.exit(1)

    if not args.verbose:
        print('')

    # output combined JSON
    json.dump(all_items, sys.stdout, indent=2)


if __name__ == '__main__':
    main()
