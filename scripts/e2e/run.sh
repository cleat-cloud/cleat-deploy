#!/usr/bin/env bash
# Disposable-server deploy smoke test (see docs/deploy-e2e.md).
#
# Creates a Hetzner Cloud server, registers it in a throwaway panel database,
# runs a static reference app through the real SSH deploy path (initial deploy,
# update, build failure and optional release failure) and destroys every cloud
# resource on the way out — including on failure.
#
# Required:
#   HCLOUD_TOKEN              Hetzner Cloud API token (dedicated e2e project)
#   E2E_SSH_PRIVATE_KEY       Contents of the dedicated e2e SSH private key
#   E2E_REPO                  Public reference repo (owner/repo)
#
# Optional:
#   E2E_REF                   Reference branch (default: main)
#   E2E_UPDATE_REF            Branch for the update deploy (default: E2E_REF)
#   E2E_FAIL_BUILD_REF        Ref expected to fail the deploy (default: cleat-e2e-missing-ref)
#   E2E_FAIL_RELEASE_REF      Ref with a failing release_command (empty: skipped)
#   E2E_EXPECT_BODY           Substring expected in the HTTP response
#   E2E_SERVER_TYPE           Hetzner type (default: cx22)
#   E2E_LOCATION              Hetzner location (default: fsn1)
#   E2E_HTTP_TIMEOUT_S        Seconds to wait for HTTP (default: 300)
#   E2E_HARNESS_TIMEOUT_S     Hard cap for the Elixir harness (default: 1800)
#   E2E_SUMMARY_PATH          Where to write the JSON summary (default: e2e-summary.json)
#   E2E_KEEP_SERVER=1         Skip destruction (debugging; billing keeps running)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

API="https://api.hetzner.cloud/v1"
RUN_ID="${GITHUB_RUN_ID:-local-$(date +%s)}"
NAME="cleat-e2e-$RUN_ID"
TYPE="${E2E_SERVER_TYPE:-cx22}"
LOCATION="${E2E_LOCATION:-fsn1}"
IMAGE="${E2E_IMAGE:-ubuntu-24.04}"
SUMMARY_PATH="${E2E_SUMMARY_PATH:-e2e-summary.json}"
HARNESS_TIMEOUT="${E2E_HARNESS_TIMEOUT_S:-1800}"

SERVER_ID=""
FIREWALL_ID=""
KEY_ID=""
KEY_FILE=""
WORK_DIR=""

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  local status=$?
  set +e
  [[ -n "$WORK_DIR" ]] || return $status

  if [[ "${E2E_KEEP_SERVER:-0}" == "1" ]]; then
    log "E2E_KEEP_SERVER=1: keeping server $SERVER_ID ($NAME); destroy it manually"
    return $status
  fi

  if [[ -n "$SERVER_ID" ]]; then
    log "destroying server $SERVER_ID ($NAME)"
    api DELETE "/servers/$SERVER_ID" >/dev/null 2>&1 || log "warning: could not delete server $SERVER_ID"
  fi
  if [[ -n "$FIREWALL_ID" ]]; then
    api DELETE "/firewalls/$FIREWALL_ID" >/dev/null 2>&1 || log "warning: could not delete firewall $FIREWALL_ID"
  fi
  if [[ -n "$KEY_ID" ]]; then
    api DELETE "/ssh_keys/$KEY_ID" >/dev/null 2>&1 || log "warning: could not delete ssh key $KEY_ID"
  fi
  if [[ -n "$KEY_FILE" ]]; then
    rm -f "$KEY_FILE"
  fi

  return $status
}

api() {
  local method="$1" path="$2"
  shift 2
  curl -fsS --retry 3 --retry-delay 2 -X "$method" "$API$path" \
    -H "Authorization: Bearer $HCLOUD_TOKEN" \
    -H "Content-Type: application/json" \
    "$@"
}

json_field() {
  python3 -c 'import json,sys
data = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    data = data[key]
print(data)' "$1"
}

write_ssh_key() {
  WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cleat-e2e-XXXXXX")"
  KEY_FILE="$WORK_DIR/e2e-key"

  if [[ -n "${E2E_SSH_PRIVATE_KEY_PATH:-}" ]]; then
    cp "$E2E_SSH_PRIVATE_KEY_PATH" "$KEY_FILE"
  else
    [[ -n "${E2E_SSH_PRIVATE_KEY:-}" ]] || die "set E2E_SSH_PRIVATE_KEY (key contents) or E2E_SSH_PRIVATE_KEY_PATH"
    printf '%s\n' "$E2E_SSH_PRIVATE_KEY" > "$KEY_FILE"
  fi

  chmod 600 "$KEY_FILE"
  ssh-keygen -y -f "$KEY_FILE" > "$WORK_DIR/e2e-key.pub"
}

create_ssh_key() {
  local pubkey body
  pubkey="$(cat "$WORK_DIR/e2e-key.pub")"
  body="$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "public_key": sys.argv[2]}))' "$NAME" "$pubkey")"
  KEY_ID="$(api POST "/ssh_keys" -d "$body" | json_field ssh_key.id)"
}

create_firewall() {
  local body
  body="$(python3 -c 'import json,sys
name = sys.argv[1]
print(json.dumps({
  "name": name,
  "rules": [
    {"direction": "in", "protocol": "tcp", "port": "22", "source_ips": ["0.0.0.0/0", "::/0"]},
    {"direction": "in", "protocol": "tcp", "port": "80", "source_ips": ["0.0.0.0/0", "::/0"]}
  ]
}))' "$NAME")"
  FIREWALL_ID="$(api POST "/firewalls" -d "$body" | json_field firewall.id)"
}

create_server() {
  local user_data body ip status
  user_data="$(cat <<'YAML'
#cloud-config
package_update: true
packages:
  - curl
  - git
  - ca-certificates
  - gnupg
  - apt-transport-https
YAML
)"

  body="$(python3 -c 'import json,sys
name, server_type, image, location = sys.argv[1:5]
key_id, firewall_id = int(sys.argv[5]), int(sys.argv[6])
print(json.dumps({
  "name": name,
  "server_type": server_type,
  "image": image,
  "location": location,
  "ssh_keys": [key_id],
  "firewalls": [{"firewall": firewall_id}],
  "user_data": sys.stdin.read(),
  "labels": {"purpose": "cleat-e2e"}
}))' "$NAME" "$TYPE" "$IMAGE" "$LOCATION" "$KEY_ID" "$FIREWALL_ID" <<<"$user_data")"

  log "creating $TYPE server $NAME in $LOCATION"
  SERVER_ID="$(api POST "/servers" -d "$body" | json_field server.id)"

  for _ in $(seq 1 60); do
    status="$(api GET "/servers/$SERVER_ID" | json_field server.status)"
    ip="$(api GET "/servers/$SERVER_ID" | json_field server.public_net.ipv4.ip)"

    if [[ "$status" == "running" && -n "$ip" ]]; then
      E2E_SERVER_IP="$ip"
      export E2E_SERVER_IP
      log "server $SERVER_ID is running at $E2E_SERVER_IP"
      return 0
    fi

    sleep 5
  done

  die "timed out waiting for server $SERVER_ID to become running"
}

wait_for_ssh() {
  log "waiting for SSH on $E2E_SERVER_IP"

  for _ in $(seq 1 60); do
    if ssh -i "$KEY_FILE" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=5 \
      "ubuntu@$E2E_SERVER_IP" true 2>/dev/null; then
      log "SSH is up"
      return 0
    fi

    sleep 5
  done

  die "timed out waiting for SSH on $E2E_SERVER_IP"
}

run_harness() {
  log "running the deploy smoke harness (static runtime)"

  E2E_SSH_PRIVATE_KEY_PATH="$KEY_FILE" \
  E2E_SUMMARY_PATH="$SUMMARY_PATH" \
  MIX_ENV=dev \
  timeout "$HARNESS_TIMEOUT" mix run --no-start scripts/e2e/deploy_smoke.exs
}

[[ -n "${HCLOUD_TOKEN:-}" ]] || die "set HCLOUD_TOKEN"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

write_ssh_key
create_ssh_key
create_firewall
create_server
wait_for_ssh
run_harness

log "summary written to $SUMMARY_PATH"
