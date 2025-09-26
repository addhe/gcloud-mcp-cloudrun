#!/usr/bin/env bash
set -euo pipefail

# test.sh
# Quick smoke test to verify a Cloud Run deployment for gcloud-mcp.
# - Finds the service URL via gcloud
# - Attempts an unauthenticated GET
# - If unauthenticated fails, attempts an authenticated GET using identity token
# - Attempts a POST with an empty JSON body and prints output
# - Fetches recent logs for quick diagnostics

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

echo "[STEP] Resolving service URL"
URL=$(gcloud run services describe "$SERVICE" --project="$PROJECT_ID" --region="$REGION" --format="value(status.url)" 2>/dev/null || true)

if [[ -z "$URL" ]]; then
  echo "[ERROR] Could not find service '$SERVICE' in project '$PROJECT_ID' region '$REGION'."
  echo "Run: gcloud run services list --project=$PROJECT_ID --region=$REGION"
  exit 3
fi

echo "[INFO] Service URL: $URL"

# Helper to try a curl and return HTTP code and body
try_curl() {
  local method=${1:-GET}
  local auth_header=${2:-}
  local data=${3:-}

  if [[ -n "$auth_header" ]]; then
    http_code=$(curl -sS -o /tmp/gcloud_mcp_test_body -w "%{http_code}" -X "$method" -H "$auth_header" -H "Content-Type: application/json" ${data:+-d "$data"} "$URL" ) || true
  else
    http_code=$(curl -sS -o /tmp/gcloud_mcp_test_body -w "%{http_code}" -X "$method" -H "Content-Type: application/json" ${data:+-d "$data"} "$URL" ) || true
  fi
  body=$(cat /tmp/gcloud_mcp_test_body || true)
  printf "%s\n" "$http_code"
  printf "%s\n" "$body"
}

# 1) Try unauthenticated GET
echo "[STEP] Trying unauthenticated GET"
read -r code body <<<"$(try_curl GET)"
if [[ "$code" =~ ^2 ]]; then
  echo "[PASS] Unauthenticated GET returned $code"
  echo "Response:"; echo "$body"
  exit 0
fi

# 2) If 401/403, try authenticated
if [[ "$code" == "401" || "$code" == "403" || "$code" == "404" ]]; then
  echo "[INFO] Unauthenticated access returned $code. Trying authenticated request using identity token."
  IDTOKEN=$(gcloud auth print-identity-token 2>/dev/null || true)
  if [[ -z "$IDTOKEN" ]]; then
    echo "[WARN] Could not obtain identity token (not logged in). Try: gcloud auth login && gcloud auth print-identity-token"
  else
    read -r code body <<<"$(try_curl GET "Authorization: Bearer $IDTOKEN")"
    if [[ "$code" =~ ^2 ]]; then
      echo "[PASS] Authenticated GET returned $code"
      echo "Response:"; echo "$body"
      exit 0
    fi
  fi
fi

# 3) Try POST with empty JSON body
echo "[STEP] Trying POST with '{}' body (unauthenticated)"
read -r code body <<<"$(try_curl POST '' '{}')"
if [[ "$code" =~ ^2 ]]; then
  echo "[PASS] POST returned $code"
  echo "Response:"; echo "$body"
  exit 0
fi

# 4) Try POST authenticated if needed
if [[ -n "${IDTOKEN:-}" ]]; then
  echo "[STEP] Trying POST with '{}' body (authenticated)"
  read -r code body <<<"$(try_curl POST "Authorization: Bearer $IDTOKEN" '{}')"
  if [[ "$code" =~ ^2 ]]; then
    echo "[PASS] Authenticated POST returned $code"
    echo "Response:"; echo "$body"
    exit 0
  fi
fi

# 5) All attempts failed: print diagnostics
echo "[FAIL] All HTTP checks failed. Last HTTP code: $code"
echo "Last response body:"; echo "$body"

echo "[STEP] Fetching recent logs (last 50 lines) for service '$SERVICE'"
if ! gcloud beta --help >/dev/null 2>&1; then
  echo "[INFO] Installing gcloud beta components (may require confirmation)"
  yes | gcloud components install beta >/dev/null || true
fi

gcloud beta run services logs read "$SERVICE" --project="$PROJECT_ID" --region="$REGION" --limit=50 || true

exit 4
