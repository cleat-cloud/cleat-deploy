#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
BUCKET="${CATALOGO_S3_BUCKET:-loja-gestaobem-prod-840298254452}"
PUBLIC_BASE="${CATALOGO_S3_PUBLIC_URL_BASE:-}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command aws

echo "==> AWS identity"
aws sts get-caller-identity

if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "==> Creating bucket $BUCKET in $REGION"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
else
  echo "==> Bucket $BUCKET already exists"
fi

if [[ -n "$PUBLIC_BASE" ]]; then
  echo "==> Bucket ready. Catalog will use custom public base: ${PUBLIC_BASE}"
else
  echo "==> Bucket ready. Catalog will use direct S3 URLs after public-read is enabled."
fi

if [[ -n "${SYNC_PAAS_ENV:-}" ]]; then
  : "${DEPLOY_IP:?Set DEPLOY_IP to sync env vars to the panel}"
  : "${DEPLOY_SSH_KEY:?Set DEPLOY_SSH_KEY}"

  echo "==> Syncing catalog S3 env vars to panel and redeploying"
  PANEL_BIN="${PANEL_BIN:-/opt/cleat_deploy/current/bin/cleat_deploy}"

  ssh -i "$DEPLOY_SSH_KEY" -o StrictHostKeyChecking=no "ubuntu@${DEPLOY_IP}" \
    "CATALOGO_S3_BUCKET='${BUCKET}' \
     CATALOGO_AWS_REGION='${REGION}' \
     CATALOGO_S3_PUBLIC_URL_BASE='${PUBLIC_BASE}' \
     CATALOGO_AWS_ACCESS_KEY_ID='${CATALOGO_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}' \
     CATALOGO_AWS_SECRET_ACCESS_KEY='${CATALOGO_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}' \
     ${PANEL_BIN} rpc \"Code.eval_file('priv/scripts/setup_catalogo.exs')\""

  echo "==> Panel env updated. Deploy catalogo from paas.gestaobem.com if needed."
fi

echo "Done."