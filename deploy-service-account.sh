#!/usr/bin/env bash
set -euo pipefail

# deploy-service-account.sh
# Create a service account for Cloud Run and grant minimal roles.
# Usage:
#   PROJECT_ID=... SA_NAME=... ./deploy-service-account.sh
# Defaults:
PROJECT_ID=${PROJECT_ID:-"$(gcloud config get-value project 2>/dev/null || true)"}
SA_NAME=${SA_NAME:-gcloud-mcp-sa}
SA_DISPLAY_NAME=${SA_DISPLAY_NAME:-"gcloud-mcp service account"}
EXTRA_ROLES=${EXTRA_ROLES:-}

if [[ -z "$PROJECT_ID" ]]; then
  echo "No GCP project configured. Set PROJECT_ID or run: gcloud config set project PROJECT_ID"
  exit 1
fi

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "[INFO] Project: ${PROJECT_ID}"
echo "[INFO] Service Account: ${SA_EMAIL}"

# Create service account if it doesn't exist
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "[STEP] Creating service account $SA_NAME"
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="$SA_DISPLAY_NAME" \
    --project="$PROJECT_ID"
else
  echo "[INFO] Service account $SA_EMAIL already exists"
fi

# Roles to bind by default (adjust as needed)
DEFAULT_ROLES=(
  roles/viewer
  roles/logging.viewer
)

# If EXTRA_ROLES provided (comma-separated), append them
if [[ -n "$EXTRA_ROLES" ]]; then
  # split on comma
  IFS=',' read -ra _EXTRA <<< "$EXTRA_ROLES"
  for r in "${_EXTRA[@]}"; do
    # trim spaces
    role=$(echo "$r" | sed -e 's/^\s*//' -e 's/\s*$//')
    if [[ -n "$role" ]]; then
      DEFAULT_ROLES+=("$role")
    fi
  done
fi

for role in "${DEFAULT_ROLES[@]}"; do
  echo "[STEP] Adding role $role to $SA_EMAIL (idempotent)"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$role" || true
done

# If secret exists, grant secret accessor
set +e
SECRET_EXISTS=0
gcloud secrets describe gemini-api-key --project="$PROJECT_ID" >/dev/null 2>&1 && SECRET_EXISTS=1 || SECRET_EXISTS=0
set -e
if [[ $SECRET_EXISTS -eq 1 ]]; then
  echo "[STEP] Granting secretmanager.secretAccessor for gemini-api-key to $SA_EMAIL"
  gcloud secrets add-iam-policy-binding gemini-api-key \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" || true
else
  echo "[INFO] Secret gemini-api-key not found; skipping secret binding."
fi

# Output the SA email for use in deploy
cat <<EOF
[DONE] Service account ready.
SA_EMAIL=${SA_EMAIL}
Use this value with: --service-account=${SA_EMAIL} when running gcloud run deploy
EOF
