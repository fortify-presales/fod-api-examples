#!/usr/bin/env bash
# authenticate.sh
# An example of authenticating with Fortify on Demand and executing API calls.
#
# Retrieves a bearer token (client_credentials or password grant) and calls
# the /api/v3/applications endpoint. Outputs JSON to stdout.

# - Requires: curl, jq
# - Supports client_credentials or password grant
# - Pages /api/v3/applications with limit=50 and offset
# - Prints progress dots when not run with --verbose

set -euo pipefail

FOD_URL="https://api.ams.fortify.com"
FOD_CLIENT_ID=""
FOD_CLIENT_SECRET=""
FOD_USERNAME=""
FOD_PASSWORD=""
FOD_TENANT=""
VERBOSE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --fod-url URL            Base FoD API URL (default: https://api.ams.fortify.com)
  --fod-client-id ID       Client ID (client_credentials flow)
  --fod-client-secret SEC  Client secret (client_credentials flow)
  --fod-username USER      Username (password grant)
  --fod-password PASS      Password (password grant)
  --fod-tenant TENANT      Tenant code (required for password grant)
  --verbose                Enable verbose logging
  -h, --help               Show this help

Example:
  $(basename "$0") --fod-url https://api.emea.fortify.com --fod-username klee2 \
    --fod-password 'YourPassword' --fod-tenant emeademo24
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fod-url) FOD_URL="$2"; shift 2;;
    --fod-client-id) FOD_CLIENT_ID="$2"; shift 2;;
    --fod-client-secret) FOD_CLIENT_SECRET="$2"; shift 2;;
    --fod-username) FOD_USERNAME="$2"; shift 2;;
    --fod-password) FOD_PASSWORD="$2"; shift 2;;
    --fod-tenant) FOD_TENANT="$2"; shift 2;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

# dependencies
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (install with 'apt install jq' or 'brew install jq')" >&2
  exit 1
fi

# normalize URL (trim trailing slash)
FOD_URL="${FOD_URL%/}"

# determine grant
USE_CLIENT=0
USE_PASSWORD=0
if [[ -n "$FOD_CLIENT_ID" && -n "$FOD_CLIENT_SECRET" ]]; then
  USE_CLIENT=1
fi
if [[ -n "$FOD_USERNAME" && -n "$FOD_PASSWORD" && -n "$FOD_TENANT" ]]; then
  USE_PASSWORD=1
fi
if [[ $USE_CLIENT -eq 0 && $USE_PASSWORD -eq 0 ]]; then
  echo "Provide either client credentials or tenant+username+password" >&2
  usage
  exit 2
fi

# helper: print dot when not verbose
show_dot() {
  if [[ $VERBOSE -eq 0 ]]; then
    printf '.'
  fi
}

# request token
TOKEN_URL="$FOD_URL/oauth/token"
if [[ $VERBOSE -eq 1 ]]; then
  echo "Requesting token at $TOKEN_URL"
else
  printf 'Fetching applications '
fi

if [[ $USE_CLIENT -eq 1 ]]; then
  DATA="scope=api-tenant&grant_type=client_credentials&client_id=$(printf '%s' "$FOD_CLIENT_ID" | jq -s -R -r @uri)&client_secret=$(printf '%s' "$FOD_CLIENT_SECRET" | jq -s -R -r @uri)"
else
  QUALIFIED_USER="$FOD_TENANT\\$FOD_USERNAME"
  DATA="scope=api-tenant&grant_type=password&username=$(printf '%s' "$QUALIFIED_USER" | jq -s -R -r @uri)&password=$(printf '%s' "$FOD_PASSWORD" | jq -s -R -r @uri)"
fi

show_dot
TOKEN_RESP=$(curl -sS -X POST "$TOKEN_URL" -H 'Content-Type: application/x-www-form-urlencoded' -d "$DATA") || { echo "\nFailed to get token" >&2; exit 1; }
ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESP" | jq -r '.access_token // empty')
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "\nToken response did not contain access_token" >&2
  printf '%s\n' "$TOKEN_RESP" >&2
  exit 1
fi

AUTH_HEADER=("Authorization: Bearer $ACCESS_TOKEN" "Accept: application/json")

BASE_URI="$FOD_URL/api/v3/applications"
LIMIT=50
OFFSET=0
TMPFILES=()

cleanup() {
  for f in "${TMPFILES[@]}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

# first page
FIRST_URL="$BASE_URI?limit=$LIMIT&offset=$OFFSET"
if [[ $VERBOSE -eq 1 ]]; then
  echo "Requesting $FIRST_URL"
else
  show_dot
fi
FIRST_TMP=$(mktemp)
TMPFILES+=("$FIRST_TMP")
curl -sS -H "${AUTH_HEADER[0]}" -H "${AUTH_HEADER[1]}" "$FIRST_URL" -o "$FIRST_TMP" || { echo "\nRequest failed" >&2; exit 1; }

# extract items into a page array file
page_to_array() {
  local src=$1
  local dst=$2
  jq 'if type=="array" then . elif has("items") then .items elif has("data") then .data elif has("content") then .content elif has("results") then .results else [] end' "$src" > "$dst"
}

FIRST_ITEMS_TMP=$(mktemp)
TMPFILES+=("$FIRST_ITEMS_TMP")
page_to_array "$FIRST_TMP" "$FIRST_ITEMS_TMP"

TOTAL_COUNT=$(jq -r '.totalCount // empty' "$FIRST_TMP" ) || TOTAL_COUNT=""
if [[ -n "$TOTAL_COUNT" && "$TOTAL_COUNT" != "null" ]]; then
  TOTAL_COUNT_INT=$(printf '%s' "$TOTAL_COUNT" | awk '{print int($0)}')
else
  TOTAL_COUNT_INT=""
fi

# accumulate
ALL_COUNT=$(jq 'length' "$FIRST_ITEMS_TMP")
PAGE_ITEMS_COUNT=$(jq 'length' "$FIRST_ITEMS_TMP")

if [[ -n "$TOTAL_COUNT_INT" ]]; then
  while [[ $ALL_COUNT -lt $TOTAL_COUNT_INT ]]; do
    OFFSET=$ALL_COUNT
    PAGE_URL="$BASE_URI?limit=$LIMIT&offset=$OFFSET"
    if [[ $VERBOSE -eq 1 ]]; then
      echo "Requesting $PAGE_URL"
    else
      show_dot
    fi
    PAGE_TMP=$(mktemp)
    TMPFILES+=("$PAGE_TMP")
    curl -sS -H "${AUTH_HEADER[0]}" -H "${AUTH_HEADER[1]}" "$PAGE_URL" -o "$PAGE_TMP" || { echo "\nRequest failed" >&2; exit 1; }
    PAGE_ITEMS_TMP=$(mktemp)
    TMPFILES+=("$PAGE_ITEMS_TMP")
    page_to_array "$PAGE_TMP" "$PAGE_ITEMS_TMP"
    PAGE_ITEMS_COUNT=$(jq 'length' "$PAGE_ITEMS_TMP")
    if [[ $PAGE_ITEMS_COUNT -eq 0 ]]; then
      break
    fi
    ALL_COUNT=$((ALL_COUNT + PAGE_ITEMS_COUNT))
  done
else
  # unknown totalCount: keep requesting until a page has zero items
  while [[ $PAGE_ITEMS_COUNT -gt 0 ]]; do
    OFFSET=$ALL_COUNT
    PAGE_URL="$BASE_URI?limit=$LIMIT&offset=$OFFSET"
    if [[ $VERBOSE -eq 1 ]]; then
      echo "Requesting $PAGE_URL"
    else
      show_dot
    fi
    PAGE_TMP=$(mktemp)
    TMPFILES+=("$PAGE_TMP")
    curl -sS -H "${AUTH_HEADER[0]}" -H "${AUTH_HEADER[1]}" "$PAGE_URL" -o "$PAGE_TMP" || { echo "\nRequest failed" >&2; exit 1; }
    PAGE_ITEMS_TMP=$(mktemp)
    TMPFILES+=("$PAGE_ITEMS_TMP")
    page_to_array "$PAGE_TMP" "$PAGE_ITEMS_TMP"
    PAGE_ITEMS_COUNT=$(jq 'length' "$PAGE_ITEMS_TMP")
    if [[ $PAGE_ITEMS_COUNT -eq 0 ]]; then
      break
    fi
    ALL_COUNT=$((ALL_COUNT + PAGE_ITEMS_COUNT))
  done
fi

# combine all page item files (they are the ones matching tmp pattern and contain arrays). Use jq -s 'add' to merge arrays.
# Find temp files that contain arrays (we created them in TMPFILES);
ARRAY_FILES=()
for f in "${TMPFILES[@]}"; do
  # skip original raw page files which may be objects; take ones that are created by page_to_array (they are also listed in TMPFILES but that's fine)
  if [[ -f "$f" ]]; then
    # ensure it's a JSON array
    if jq -e 'type=="array"' "$f" >/dev/null 2>&1; then
      ARRAY_FILES+=("$f")
    fi
  fi
done

if [[ ${#ARRAY_FILES[@]} -eq 0 ]]; then
  echo "[]"
  exit 0
fi

# print newline if not verbose (to end the dots)
if [[ $VERBOSE -eq 0 ]]; then
  printf '\n'
fi

# combine and output
jq -s 'add' "${ARRAY_FILES[@]}"

# cleanup handled by trap

