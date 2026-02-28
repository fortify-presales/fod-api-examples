authenticate.py
=================

Description
-----------
An example Python that performs OAuth2 authentication to Fortify on Demand (FoD) using either:
  - Client credentials (`client_credentials` grant) with `--fod-client-id` and `--fod-client-secret`, or
  - Password grant (`password` grant) with `--fod-tenant`, `--fod-username`, and `--fod-password` (username is tenant-qualified as `Tenant\\Username`).
- Pages the `/api/v3/applications` endpoint using `limit` (50) and `offset` query parameters and combines all pages into a single JSON array.
- Prints short progress dots when not run with `--verbose`, and prints full request URIs when `--verbose` is used.

Requirements
------------
- Python 3.8+
- `requests` library (see `requirements.txt` in this directory)

Installation
------------
Install dependencies with pip:

```bash
pip install -r python/authenticate/requirements.txt
```

Usage
-----
Password grant example:

```bash
python python/authenticate/authenticate.py --fod-url https://api.emea.fortify.com --fod-username klee2 --fod-password 'YourPassword' --fod-tenant yourTenant
```

Client credentials example:

```bash
python python/authenticate/authenticate.py --fod-url https://api.emea.fortify.com --fod-client-id 'client-id' --fod-client-secret 'client-secret'
```

Verbose logging (prints request URIs instead of dots):

```bash
python python/authenticate/authenticate.py ... --verbose
```

Save output to file:

```bash
python python/authenticate/authenticate.py ... > applications.json
```

Behavior notes
--------------
- The script requests a token from `<FodURL>/oauth/token`, then requests the first page of `/api/v3/applications?limit=50&offset=0`.
- If the first response includes `totalCount`, the script uses it to determine how many additional pages to request.
- If `totalCount` is missing, the script keeps requesting subsequent pages until it receives an empty page.
- The script heuristically extracts arrays from common response shapes (`items`, `data`, `content`, `results`) and also supports a plain JSON array response.