#!/bin/bash

FOD_URL="https://api.ams.fortify.com"
FOD_CLIENT_ID=$FCLI_DEFAULT_FOD_CLIENT_ID
FOD_CLIENT_SECRET=$FCLI_DEFAULT_FOD_CLIENT_SECRET
FOD_RELEASE_ID=$FCLI_DEFAULT_RELEASE_ID
SBOM_FILE="CycloneDX-BOM-SampleApp.json"
SBOM_FILE_1="CycloneDX-BOM-SampleApp.json.part1"
SBOM_FILE_2="CycloneDX-BOM-SampleApp.json.part2"

echo "Authenticating..."
FOD_ACCESS_TOKEN=$(curl -s --request POST "${FOD_URL}/oauth/token" \
	--header 'Content-Type: application/x-www-form-urlencoded' \
	--data-urlencode 'scope=api-tenant' \
	--data-urlencode 'grant_type=client_credentials' \
	--data-urlencode "client_id=${FOD_CLIENT_ID}" \
	--data-urlencode "client_secret=${FOD_CLIENT_SECRET}" | jq --raw-output .access_token)
#echo $FOD_ACCESS_TOKEN
#
echo "Retrieving Import Session Id..."
IMPORT_SESSION_ID=$(curl -s --request GET "${FOD_URL}/api/v3/releases/${FOD_RELEASE_ID}/import-scan-session-id" \
	--header "Authorization: Bearer ${FOD_ACCESS_TOKEN}" | jq --raw-output .importScanSessionId)
#echo $IMPORT_SESSION_ID

#
# THIS WORKS
#

#echo "Uploading SBOM ${SBOM_FILE}..."
#curl -T "${SBOM_FILE}" \
#       	"${FOD_URL}/api/v3/releases/${FOD_RELEASE_ID}/open-source-scans/import-cyclonedx-sbom?importScanSessionId=${IMPORT_SESSION_ID}&releaseId=${FOD_RELEASE_ID}&fragNo=-1&offset=0" \
#	--header "Authorization: Bearer ${FOD_ACCESS_TOKEN}"

#
# THIS DOESN'T
#

echo "Uploading SBOM ${SBOM_FILE_1}..."
curl -T "${SBOM_FILE_1}" \
       	"${FOD_URL}/api/v3/releases/${FOD_RELEASE_ID}/open-source-scans/import-cyclonedx-sbom?importScanSessionId=${IMPORT_SESSION_ID}&releaseId=${FOD_RELEASE_ID}&fragNo=0&offset=0" \
	--header "Authorization: Bearer ${FOD_ACCESS_TOKEN}"

echo "Uploading SBOM ${SBOM_FILE_2}..."
curl -T "${SBOM_FILE_1}" \
       	"${FOD_URL}/api/v3/releases/${FOD_RELEASE_ID}/open-source-scans/import-cyclonedx-sbom?importScanSessionId=${IMPORT_SESSION_ID}&releaseId=${FOD_RELEASE_ID}&fragNo=-1&offset=2048" \
	--header "Authorization: Bearer ${FOD_ACCESS_TOKEN}"
