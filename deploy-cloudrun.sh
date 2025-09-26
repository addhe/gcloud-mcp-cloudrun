#!/usr/bin/env bash
set -euo pipefail

# deploy-cloudrun.sh
# Deploy gcloud-mcp as a Cloud Run service.
# - Builds a Docker image containing @google-cloud/gcloud-mcp and a small HTTP proxy
#   that forwards request bodies to the package's CLI bundle (stdio) and returns
#   the bundle stdout as the HTTP response.
# - Pushes the image to Artifact Registry
# - Deploys to Cloud Run
#
# Usage:
#   ./deploy-cloudrun.sh [GEMINI_API_KEY]
# or set env before:
#   export GEMINI_API_KEY=your_key
#   ./deploy-cloudrun.sh
#
# Optional env overrides:
#   PROJECT_ID (default: gcloud config project)
#   REGION     (default: us-central1)
#   SERVICE    (default: gcloud-mcp)
#   REPO       (default: gcloud-mcp)
#   PLATFORM   (default: linux/amd64)

PROJECT_ID=${PROJECT_ID:-"$(gcloud config get-value project 2>/dev/null || true)"}
REGION=${REGION:-us-central1}
SERVICE=${SERVICE:-gcloud-mcp}
REPO=${REPO:-gcloud-mcp}
PLATFORM=${PLATFORM:-linux/amd64}

SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-}
GEMINI_KEY_FROM_ARG=${1:-${GEMINI_API_KEY:-}}

IMAGE_PATH="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE}:latest"

if [[ -z "$PROJECT_ID" ]]; then
  echo "No gcloud project configured. Set PROJECT_ID env or run: gcloud config set project PROJECT_ID"
  exit 1
fi

echo "[INFO] Project: ${PROJECT_ID}"
echo "[INFO] Region:  ${REGION}"
echo "[INFO] Service: ${SERVICE}"
echo "[INFO] Image:   ${IMAGE_PATH}"

echo "[STEP] Configuring gcloud project"
gcloud config set project "${PROJECT_ID}" >/dev/null

echo "[STEP] Enabling required services (idempotent)"
gcloud services enable artifactregistry.googleapis.com run.googleapis.com >/dev/null

echo "[STEP] Ensuring Artifact Registry repo exists (idempotent)"
if ! gcloud artifacts repositories describe "${REPO}" --location="${REGION}" >/dev/null 2>&1; then
  gcloud artifacts repositories create "${REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="gcloud-mcp images"
fi

echo "[STEP] Configuring Docker auth for Artifact Registry"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" -q >/dev/null

echo "[STEP] Building image (platform: ${PLATFORM})"
docker build --platform="${PLATFORM}" -t "${IMAGE_PATH}" .

echo "[STEP] Pushing image"
docker push "${IMAGE_PATH}"

# Secret Manager setup (optional): GEMINI API key used by some MCP integrations
echo "[STEP] Preparing Secret Manager: gemini-api-key"
set +e
gcloud secrets describe gemini-api-key >/dev/null 2>&1
SECRET_EXISTS=$?
set -e
if [[ ${SECRET_EXISTS} -ne 0 ]]; then
  echo "[INFO] Secret gemini-api-key not found. Creating..."
  gcloud secrets create gemini-api-key --replication-policy="automatic"
fi

if [[ -n "${GEMINI_KEY_FROM_ARG}" ]]; then
  echo "[STEP] Adding new secret version from provided key"
  printf '%s' "${GEMINI_KEY_FROM_ARG}" | gcloud secrets versions add gemini-api-key --data-file=- >/dev/null
else
  echo "[INFO] No key provided via arg/env. Reusing latest secret version if present."
fi

echo "[STEP] Checking for enabled secret versions"
set +e
ENABLED_SECRET_VERSION=$(gcloud secrets versions list gemini-api-key \
  --filter="state=ENABLED" \
  --format="value(name)" \
  --limit=1 2>/dev/null)
set -e
if [[ -n "${ENABLED_SECRET_VERSION}" ]]; then
  echo "[INFO] Found enabled secret version: ${ENABLED_SECRET_VERSION}"
  USE_SECRET_FLAG=1
else
  echo "[WARN] No enabled secret versions found for gemini-api-key. Will deploy with empty GEMINI_API_KEY env var."
  USE_SECRET_FLAG=0
fi

# Determine service account used by Cloud Run revision (idempotent)
echo "[STEP] Determining Cloud Run service account"
SA_EMAIL=$(gcloud run services describe "${SERVICE}" --region="${REGION}" --format='value(spec.template.spec.serviceAccountName)' 2>/dev/null || true)
if [[ -z "${SA_EMAIL}" ]]; then
  PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
  SA_EMAIL="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
fi
echo "[INFO] Using service account: ${SA_EMAIL}"

echo "[STEP] Granting Secret Manager access to service account (idempotent)"
gcloud secrets add-iam-policy-binding gemini-api-key \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" >/dev/null || true

echo "[STEP] Deploying to Cloud Run"
DEPLOY_ARGS=(
  "${SERVICE}"
  --image "${IMAGE_PATH}"
  --platform managed
  --region "${REGION}"
  --allow-unauthenticated
  --port=8080
  --memory=1Gi
  --timeout=300s
)
if [[ ${USE_SECRET_FLAG} -eq 1 ]]; then
  DEPLOY_ARGS+=(--set-secrets=GEMINI_API_KEY=gemini-api-key:latest)
else
  DEPLOY_ARGS+=(--set-env-vars=GEMINI_API_KEY=)
fi

# If SERVICE_ACCOUNT not provided, create/use one via deploy-service-account.sh
if [[ -z "${SERVICE_ACCOUNT:-}" ]]; then
  echo "[INFO] No SERVICE_ACCOUNT provided; creating/ensuring one via deploy-service-account.sh"
  # pass PROJECT_ID to the helper; allow overriding SA_NAME via env if desired
  TMP_OUT=$(mktemp)
  if ! ./deploy-service-account.sh PROJECT_ID="$PROJECT_ID" > "$TMP_OUT" 2>&1; then
    echo "[ERROR] deploy-service-account.sh failed. Output:" >&2
    sed -n '1,200p' "$TMP_OUT" >&2 || true
    rm -f "$TMP_OUT"
    exit 1
  fi
  # Expect the helper to print a line like: SA_EMAIL=...
  SERVICE_ACCOUNT=$(grep -m1 '^SA_EMAIL=' "$TMP_OUT" | cut -d'=' -f2- || true)
  rm -f "$TMP_OUT"
  if [[ -z "$SERVICE_ACCOUNT" ]]; then
    echo "[ERROR] Could not determine SA_EMAIL from deploy-service-account.sh output" >&2
    exit 1
  fi
  echo "[INFO] Using service account: $SERVICE_ACCOUNT"
fi

# Apply service account
DEPLOY_ARGS+=(--service-account="${SERVICE_ACCOUNT}")

set +e
gcloud run deploy "${DEPLOY_ARGS[@]}"
DEPLOY_EXIT=$?
set -e

if [[ ${DEPLOY_EXIT} -ne 0 ]]; then
  echo "[WARN] Deploy command reported a failure (code=${DEPLOY_EXIT})."
fi

echo "[DONE] Deployment finished. Fetching recent logs (last 50 lines)"
if ! gcloud beta --help >/dev/null 2>&1; then
  echo "[INFO] Installing gcloud beta components"
  yes | gcloud components install beta >/dev/null || true
fi

gcloud beta run services logs read "${SERVICE}" --region="${REGION}" --limit=50 || true

echo "[INFO] Latest revisions:"
gcloud run revisions list --region="${REGION}" --service="${SERVICE}" --limit=5 || true

echo "[TIP] To update only the env var later without rebuilding:"
echo "  gcloud run services update ${SERVICE} --region=${REGION} --update-env-vars=GEMINI_API_KEY=NEW_KEY"
