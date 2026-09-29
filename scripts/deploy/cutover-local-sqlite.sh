#!/usr/bin/env bash
# Export the panel DB from Turso, place it as a local SQLite file on the
# panel host, point DATABASE_PATH at it, and start Litestream.
#
# Requires a working Turso export (reads must be unblocked). Collector stays
# off. Rollback: comment DATABASE_PATH, uncomment TURSO_* , restart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DEPLOY_IP="${DEPLOY_IP:-}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/lightsail-default-key-us-east-1.pem}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
TURSO_DB="${TURSO_DB:-phoenix-paas-prod}"
REMOTE_DB_PATH="${REMOTE_DB_PATH:-/var/lib/cleat_deploy/cleat.db}"
LITESTREAM_VERSION="${LITESTREAM_VERSION:-0.5.17}"

if [[ -f "$ROOT/scripts/deploy/deploy.local.env" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/deploy/deploy.local.env"
fi

log() { printf '→ %s\n' "$*" >&2; }
die() { echo "Error: $*" >&2; exit 1; }

[[ -n "$DEPLOY_IP" ]] || die "Set DEPLOY_IP"
[[ -f "$DEPLOY_SSH_KEY" ]] || die "SSH key not found: $DEPLOY_SSH_KEY"
command -v turso >/dev/null 2>&1 || die "turso CLI is required for the export"

ssh_cmd() {
  ssh -i "$DEPLOY_SSH_KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    "${DEPLOY_USER}@${DEPLOY_IP}" "$@"
}

LOCAL_DB="$(mktemp /tmp/cleat-panel-XXXXXX.db)"
trap 'rm -f "$LOCAL_DB" "${LOCAL_DB}-wal" "${LOCAL_DB}-shm"' EXIT

log "Exporting Turso database ${TURSO_DB}"
turso db export "$TURSO_DB" --output-file "$LOCAL_DB" --overwrite

[[ -s "$LOCAL_DB" ]] || die "export produced an empty file"

if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$LOCAL_DB" "PRAGMA journal_mode=WAL; PRAGMA integrity_check;" | grep -q ok \
    || die "integrity_check failed on exported database"
fi

log "Installing sqlite3 + Litestream on the panel host"
ssh_cmd bash -s <<REMOTE
set -euo pipefail
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y sqlite3
if ! command -v litestream >/dev/null 2>&1; then
  tmp=\$(mktemp -d)
  curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-x86_64.deb" -o "\$tmp/litestream.deb"
  sudo dpkg -i "\$tmp/litestream.deb"
  rm -rf "\$tmp"
fi
litestream version
sudo mkdir -p /var/lib/cleat_deploy /var/backups/cleat_deploy/litestream /etc/cleat_deploy
REMOTE

log "Stopping panel"
ssh_cmd "sudo systemctl stop cleat_deploy"

log "Uploading SQLite file to ${REMOTE_DB_PATH}"
scp -i "$DEPLOY_SSH_KEY" -o StrictHostKeyChecking=accept-new \
  "$LOCAL_DB" "${DEPLOY_USER}@${DEPLOY_IP}:/tmp/cleat.db"
if [[ -f "${LOCAL_DB}-wal" ]]; then
  scp -i "$DEPLOY_SSH_KEY" -o StrictHostKeyChecking=accept-new \
    "${LOCAL_DB}-wal" "${DEPLOY_USER}@${DEPLOY_IP}:/tmp/cleat.db-wal"
fi

scp -i "$DEPLOY_SSH_KEY" -o StrictHostKeyChecking=accept-new \
  "$ROOT/deploy/litestream.yml.example" \
  "${DEPLOY_USER}@${DEPLOY_IP}:/tmp/litestream.yml"
scp -i "$DEPLOY_SSH_KEY" -o StrictHostKeyChecking=accept-new \
  "$ROOT/deploy/cleat-litestream.service" \
  "${DEPLOY_USER}@${DEPLOY_IP}:/tmp/cleat-litestream.service"
scp -i "$DEPLOY_SSH_KEY" -o StrictHostKeyChecking=accept-new \
  "$ROOT/scripts/deploy/cutover-local-sqlite-env.py" \
  "${DEPLOY_USER}@${DEPLOY_IP}:/tmp/cutover-local-sqlite-env.py"

log "Switching env to DATABASE_PATH and starting Litestream"
ssh_cmd bash -s <<REMOTE
set -euo pipefail
sudo mv /tmp/cleat.db ${REMOTE_DB_PATH}
if [[ -f /tmp/cleat.db-wal ]]; then
  sudo mv /tmp/cleat.db-wal ${REMOTE_DB_PATH}-wal
fi
sudo chown root:root ${REMOTE_DB_PATH} ${REMOTE_DB_PATH}-wal 2>/dev/null || sudo chown root:root ${REMOTE_DB_PATH}
sudo chmod 600 ${REMOTE_DB_PATH}
sudo sqlite3 ${REMOTE_DB_PATH} "PRAGMA journal_mode=WAL;"
sudo sqlite3 ${REMOTE_DB_PATH} "PRAGMA integrity_check;" | grep -q ok
sudo python3 /tmp/cutover-local-sqlite-env.py ${REMOTE_DB_PATH}
sudo mv /tmp/litestream.yml /etc/cleat_deploy/litestream.yml
sudo chmod 600 /etc/cleat_deploy/litestream.yml
sudo mv /tmp/cleat-litestream.service /etc/systemd/system/cleat-litestream.service
sudo systemctl daemon-reload
sudo systemctl enable --now cleat-litestream
sudo systemctl restart cleat_deploy
sleep 3
sudo systemctl is-active cleat_deploy
sudo systemctl is-active cleat-litestream
REMOTE

log "Panel is on local SQLite + Litestream at ${REMOTE_DB_PATH}"
