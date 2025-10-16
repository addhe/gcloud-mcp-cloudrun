#!/usr/bin/env bash
set -euo pipefail

# test.sh
# Quick smoke test to verify a Cloud Run deployment for gcloud-mcp.
# - Finds the service URL via gcloud
# - Hits /health and /diag endpoints
# - Exercises direct gcloud path via JSON {tool: run_gcloud_command}
# - Tries unauthenticated first; if fails, tries with identity token
# - Fetches recent logs for quick diagnostics if any step fails

SERVICE=${SERVICE:-gcloud-mcp}
REGION=${REGION:-us-central1}
PROJECT_ID=${PROJECT_ID:-"$(gcloud config get-value project 2>/dev/null || true)"}

if [[ -z "$PROJECT_ID" ]]; then
  echo "No GCP project configured. Set PROJECT_ID or run: gcloud config set project PROJECT_ID"
  exit 2
fi

echo "[INFO] Project: $PROJECT_ID"
echo "[INFO] Region:  $REGION"
echo "[INFO] Service: $SERVICE"

if [[ "$SERVICE" == http* ]]; then
  echo "[INFO] SERVICE variable is a URL, using it directly."
  URL="$SERVICE"
else
  echo "[INFO] SERVICE variable is a service name, resolving URL."
  echo "[STEP] Resolving service URL"
  URL=$(gcloud run services describe "$SERVICE" --project="$PROJECT_ID" --region="$REGION" --format="value(status.url)" 2>/dev/null || true)
fi

if [[ -z "$URL" ]]; then
  echo "[ERROR] Could not resolve URL for service '$SERVICE' in project '$PROJECT_ID' region '$REGION'."
  echo "If you provided a service name, run: gcloud run services list --project=$PROJECT_ID --region=$REGION"
  exit 3
fi

echo "[INFO] Service URL: $URL"

# Helper to try a curl against a specific path and return HTTP code and body
try_curl() {
  local method=${1:-GET}
  local auth_header=${2:-}
  local data=${3:-}
  local path=${4:-/}

  local target="${URL}${path}"
  if [[ -n "$auth_header" ]]; then
    curl -s -w "\n%{http_code}" -X "$method" -H "$auth_header" -H "Content-Type: application/json" ${data:+-d "$data"} "$target"
  else
    curl -s -w "\n%{http_code}" -X "$method" -H "Content-Type: application/json" ${data:+-d "$data"} "$target"
  fi
}

# Prepare identity token (optional)
IDTOKEN=$(gcloud auth print-identity-token 2>/dev/null || true)

FAIL=0

# 1) GET /health
echo "[STEP] GET /health (unauthenticated)"
output=$(try_curl GET '' '' '/health')
code=$(echo "$output" | tail -n1)
body=$(echo "$output" | sed '$d')
echo "HTTP: $code"; echo "Body:"; echo "$body"
if [[ ! "$code" =~ ^2 ]]; then
  echo "[INFO] Unauth GET /health failed with $code. Trying authenticated if token available."
  if [[ -n "$IDTOKEN" ]]; then
    auth_output=$(try_curl GET "Authorization: Bearer $IDTOKEN" '' '/health')
    code=$(echo "$auth_output" | tail -n1)
    body=$(echo "$auth_output" | sed '$d')
    echo "[AUTH] HTTP: $code"; echo "Body:"; echo "$body"
  fi
fi
[[ "$code" =~ ^2 ]] || FAIL=1

# 2) GET /diag
echo "[STEP] GET /diag (unauthenticated)"
output=$(try_curl GET '' '' '/diag')
code=$(echo "$output" | tail -n1)
body=$(echo "$output" | sed '$d')
echo "HTTP: $code"; echo "Body:"; echo "$body"
if [[ ! "$code" =~ ^2 ]]; then
  echo "[INFO] Unauth GET /diag failed with $code. Trying authenticated if token available."
  if [[ -n "$IDTOKEN" ]]; then
    auth_output=$(try_curl GET "Authorization: Bearer $IDTOKEN" '' '/diag')
    code=$(echo "$auth_output" | tail -n1)
    body=$(echo "$auth_output" | sed '$d')
    echo "[AUTH] HTTP: $code"; echo "Body:"; echo "$body"
  fi
fi
[[ "$code" =~ ^2 ]] || FAIL=1

# 3) POST run_gcloud_command: --version (text output)
echo "[STEP] POST run_gcloud_command --version"
output=$(try_curl POST '' '{"tool":"run_gcloud_command","input":{"args":["--version"]}}' '/')
code=$(echo "$output" | tail -n1)
body=$(echo "$output" | sed '$d')
echo "HTTP: $code"; echo "Body:"; echo "$body"
[[ "$code" =~ ^2 ]] || FAIL=1

# 4) POST run_gcloud_command: services list (JSON output)
echo "[STEP] POST run_gcloud_command services list (JSON)"
output=$(try_curl POST '' '{"tool":"run_gcloud_command","input":{"args":["run","services","list","--project='\''"$PROJECT_ID"'\''","--region='\''"$REGION"'\''","--format=json"]}}' '/')
code=$(echo "$output" | tail -n1)
body=$(echo "$output" | sed '$d')
echo "HTTP: $code"; echo "Body:"; echo "$body"
[[ "$code" =~ ^2 ]] || FAIL=1

# 5) POST run_gcloud_command: revisions list for current service (JSON output)
echo "[STEP] POST run_gcloud_command revisions list (JSON)"
output=$(try_curl POST '' '{"tool":"run_gcloud_command","input":{"args":["run","revisions","list","--project='\''"$PROJECT_ID"'\''","--region='\''"$REGION"'\''","--service='\''"$SERVICE"'\''","--format=json"]}}' '/')
code=$(echo "$output" | tail -n1)
body=$(echo "$output" | sed '$d')
echo "HTTP: $code"; echo "Body:"; echo "$body"
[[ "$code" =~ ^2 ]] || FAIL=1

# 6) GET / (unauthenticated)
echo "[STEP] GET / (unauthenticated)"
output=$(try_curl GET '' '' '/')
code=$(echo "$output" | tail -n1)
body=$(echo "$output" | sed '$d')
echo "HTTP: $code"; echo "Body:"; echo "$body"
if [[ ! "$code" =~ ^2 ]]; then
  echo "[INFO] Unauth GET / failed with $code. Trying authenticated if token available."
  if [[ -n "$IDTOKEN" ]]; then
    auth_output=$(try_curl GET "Authorization: Bearer $IDTOKEN" '' '/')
    code=$(echo "$auth_output" | tail -n1)
    body=$(echo "$auth_output" | sed '$d')
    echo "[AUTH] HTTP: $code"; echo "Body:"; echo "$body"
  fi
fi
[[ "$code" =~ ^2 ]] || FAIL=1

# 7) POST run_gcloud_command: functions list (JSON output)
echo "[STEP] POST run_gcloud_command functions list (JSON)"
output=$(try_curl POST '' '{"tool":"run_gcloud_command","input":{"args":["functions","list","--project='\''"$PROJECT_ID"'\''","--regions='\''"$REGION"'\''","--format=json"]}}' '/')
code=$(echo "$output" | tail -n1)
body=$(echo "$output" | sed '$d')
echo "HTTP: $code"; echo "Body:"; echo "$body"
[[ "$code" =~ ^2 ]] || FAIL=1

# 8) POST run_gcloud_command: services list in us-central1
echo "[STEP] POST run_gcloud_command: services list in us-central1"
payload_svcs_us='{"tool":"run_gcloud_command","input":{"args":["run","services","list","--region","us-central1"]}}'
output=$(try_curl POST '' "$payload_svcs_us" '/')
code=$(echo "$output" | tail -n1)
body=$(echo "$output" | sed '$d')
echo "HTTP: $code"; echo "Body:"; echo "$body"
[[ "$code" =~ ^2 ]] || FAIL=1

echo "[SUMMARY] FAIL=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  echo "[STEP] Fetching recent logs (last 50 lines) for service '$SERVICE'"
  if ! gcloud beta --help >/dev/null 2>&1; then
    echo "[INFO] Installing gcloud beta components (may require confirmation)"
    yes | gcloud components install beta >/dev/null || true
  fi
  gcloud beta run services logs read "$SERVICE" --project="$PROJECT_ID" --region="$REGION" --limit=50 || true
  exit 4
fi

exit 0
