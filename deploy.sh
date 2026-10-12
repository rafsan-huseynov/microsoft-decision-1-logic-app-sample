#!/usr/bin/env bash
# Deploys the zucca-fan-mail-radar workflow to an existing Logic App (Standard).
# All environment values come from .env. Nothing environment-specific lives in this repo.
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env and fill in your values." >&2
  exit 1
fi
set -a; source .env; set +a

: "${RESOURCE_GROUP:?RESOURCE_GROUP is not set in .env}"
: "${LOGIC_APP_NAME:?LOGIC_APP_NAME is not set in .env}"
: "${FOUNDRY_ENDPOINT:?FOUNDRY_ENDPOINT is not set in .env}"
: "${DECISION_DEPLOYMENT_NAME:?DECISION_DEPLOYMENT_NAME is not set in .env}"

PROJECT_TAG="zucca-fan-mail-radar"

# Safety check: only deploy to a Logic App tagged for this project, so a typo in .env
# can never overwrite another app on a shared plan.
tag=$(az resource show -g "$RESOURCE_GROUP" -n "$LOGIC_APP_NAME" \
  --resource-type Microsoft.Web/sites --query "tags.project" -o tsv 2>/dev/null || true)
if [[ "$tag" != "$PROJECT_TAG" ]]; then
  echo "Refusing to deploy: Logic App '$LOGIC_APP_NAME' is missing tag project=$PROJECT_TAG." >&2
  exit 1
fi

echo "Setting app settings on $LOGIC_APP_NAME..."
az logicapp config appsettings set -g "$RESOURCE_GROUP" -n "$LOGIC_APP_NAME" \
  --settings "FOUNDRY_ENDPOINT=${FOUNDRY_ENDPOINT%/}" "DECISION_DEPLOYMENT_NAME=$DECISION_DEPLOYMENT_NAME" \
  -o none

# Build the zip outside the repo and remove it afterwards.
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
zip -qr "$build_dir/app.zip" host.json zucca-fan-mail-radar -x '*.DS_Store'

echo "Zip deploying to $LOGIC_APP_NAME..."
az logicapp deployment source config-zip -g "$RESOURCE_GROUP" -n "$LOGIC_APP_NAME" \
  --src "$build_dir/app.zip" -o none

echo "Deployed."
