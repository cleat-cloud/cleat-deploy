#!/usr/bin/env bash
set -euo pipefail

# Rolls the panel back to a previous release built by build-on-panel-server.sh.
#
#   ./scripts/deploy/rollback-panel.sh              # previous release
#   ./scripts/deploy/rollback-panel.sh 20260919050500
#   DRY_RUN=true ./scripts/deploy/rollback-panel.sh # only print the target
#
# Migrations are NOT rolled back; roll forward with a new deploy instead.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DEPLOY_IP="${DEPLOY_IP:-}"
DEPLOY_HOST="${DEPLOY_HOST:-paas.gestaobem.com}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/lightsail-default-key-us-east-1.pem}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DRY_RUN="${DRY_RUN:-false}"
TARGET="${1:-}"

if [[ -f "$ROOT/scripts/deploy/deploy.local.env" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/deploy/deploy.local.env"
fi

log() {
  printf '→ %s\n' "$*" >&2
}

die() {
  echo "Error: $*" >&2
  exit 1
}

main() {
  [[ -n "$DEPLOY_IP" ]] || die "Set DEPLOY_IP to the panel public IP"
  [[ -f "$DEPLOY_SSH_KEY" ]] || die "SSH key not found: $DEPLOY_SSH_KEY"
  chmod 600 "$DEPLOY_SSH_KEY"

  log "Selecting rollback target on ${DEPLOY_IP}"
  ssh -i "$DEPLOY_SSH_KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    "${DEPLOY_USER}@${DEPLOY_IP}" bash -s -- "$TARGET" "$DRY_RUN" <<'REMOTE'
set -euo pipefail

TARGET="${1:-}"
DRY_RUN="${2:-false}"
RELEASE_ROOT="/opt/cleat_deploy/releases"
CURRENT="$(readlink -f /opt/cleat_deploy/current 2>/dev/null || true)"

mapfile -t releases < <(ls -1dt "$RELEASE_ROOT"/*/ 2>/dev/null | sed 's:/*$::')

if [[ -z "$TARGET" ]]; then
  for release in "${releases[@]}"; do
    if [[ "$release" != "$CURRENT" ]]; then
      TARGET="$release"
      break
    fi
  done
fi

if [[ -z "$TARGET" || ! -d "$TARGET" ]]; then
  echo "No rollback target found in $RELEASE_ROOT" >&2
  exit 1
fi

echo "Current: $CURRENT"
echo "Target:  $TARGET"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run — not switching"
  exit 0
fi

sudo ln -sfn "$TARGET" /opt/cleat_deploy/current.rollback
sudo mv -Tf /opt/cleat_deploy/current.rollback /opt/cleat_deploy/current
sudo systemctl restart cleat_deploy
sleep 3
sudo systemctl is-active cleat_deploy
REMOTE

  log "Rollback complete — https://${DEPLOY_HOST}"
}

main "$@"
