authenticate.sh
=================

Description
-----------
An example Bash script that authenticates to Fortify on Demand (FoD) using either the OAuth2 `password` grant (tenant-qualified username) or `client_credentials` grant, then calls the FoD REST API. The script includes an example of paging the `/api/v3/applications` endpoint (uses `limit`/`offset`) and prints combined JSON results.

- Authenticates to Fortify on Demand (FoD) using either the OAuth2 `client_credentials` grant or the `password` grant (tenant-qualified username).
- Pages the `/api/v3/applications` endpoint using `limit=50` and `offset` and combines pages into a single JSON array printed to stdout.
- Prints short progress dots when not run with `--verbose` and prints full request URIs when `--verbose` is used.

Requirements
------------
- bash (POSIX-compatible shell)
- `curl` (for HTTP requests)
- `jq` (for JSON parsing)

Usage
-----
Basic (password grant):

```bash
bash bash/authenticate/authenticate.sh \
  --fod-url https://api.emea.fortify.com \
  --fod-username klee2 \
  --fod-password 'YourPassword' \
  --fod-tenant emeademo24
```

Client credentials grant:

```bash
bash bash/authenticate/authenticate.sh \
  --fod-url https://api.emea.fortify.com \
  --fod-client-id 'client-id' \
  --fod-client-secret 'client-secret'
```

Verbose logging (show full request URIs):

```bash
bash bash/authenticate/authenticate.sh ... --verbose
```

Save output to file:

```bash
bash bash/authenticate/authenticate.sh ... > applications.json
```

Behavior notes
--------------
- The script requests a token from `<FodURL>/oauth/token` then requests the first page at `/api/v3/applications?limit=50&offset=0`.
- If the first page includes `totalCount`, the script uses it to determine how many additional pages are required; otherwise it keeps paging until a page returns no items.
- The script looks for arrays under common response keys (`items`, `data`, `content`, `results`) and supports a plain JSON array response.

Troubleshooting
---------------
- Ensure `curl` and `jq` are installed and on `PATH`.
- If the script appears to hang, run with `--verbose` to see full request URIs and responses.