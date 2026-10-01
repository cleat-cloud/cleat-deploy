#!/usr/bin/env bash
# Create a Hetzner CX33 (4 vCPU, 8 GB, 80 GB) and print its public IPv4.
#
# Required:
#   export HCLOUD_TOKEN=...   # or HETZNER_API_TOKEN
#
# Optional:
#   HETZNER_SERVER_NAME=gestaobem-cx33
#   HETZNER_LOCATION=fsn1          # CX33 is not offered in Ashburn
#   HETZNER_SERVER_TYPE=cx33
#   HETZNER_SSH_PUBKEY=$HOME/.ssh/id_ed25519.pub
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/scripts/deploy/deploy.local.env" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/deploy/deploy.local.env"
fi

TOKEN="${HCLOUD_TOKEN:-${HETZNER_API_TOKEN:-}}"
NAME="${HETZNER_SERVER_NAME:-gestaobem-cx33}"
TYPE="${HETZNER_SERVER_TYPE:-cx33}"
LOCATION="${HETZNER_LOCATION:-fsn1}"
IMAGE="${HETZNER_IMAGE:-ubuntu-24.04}"
API="https://api.hetzner.cloud/v1"
LIGHTSAIL_PEM="${DEPLOY_SSH_KEY:-$HOME/.ssh/lightsail-default-key-us-east-1.pem}"
ED25519_PUB="${HETZNER_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"

log() { printf '→ %s\n' "$*" >&2; }
die() { echo "Error: $*" >&2; exit 1; }

[[ -n "$TOKEN" ]] || die "Set HCLOUD_TOKEN (or HETZNER_API_TOKEN) to a Hetzner Cloud API token with read/write"

api() {
  local method="$1" path="$2"
  shift 2
  curl -fsS -X "$method" "$API$path" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$@"
}

ensure_ssh_key() {
  local name="$1" pubkey="$2"
  [[ -n "$pubkey" ]] || return 0

  local existing
  existing="$(api GET "/ssh_keys?name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$name")" || true)"
  local id
  id="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ssh_keys"][0]["id"] if d.get("ssh_keys") else "")' <<<"$existing")"
  if [[ -n "$id" ]]; then
    echo "$id"
    return 0
  fi

  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "public_key": sys.argv[2]}))' "$name" "$pubkey")"
  api POST "/ssh_keys" -d "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ssh_key"]["id"])'
}

ensure_firewall() {
  local name="gestaobem-web"
  local existing
  existing="$(api GET "/firewalls?name=$name" || true)"
  local id
  id="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["firewalls"][0]["id"] if d.get("firewalls") else "")' <<<"$existing")"
  if [[ -n "$id" ]]; then
    echo "$id"
    return 0
  fi

  local body
  body="$(cat <<'JSON'
{
  "name": "gestaobem-web",
  "rules": [
    {"direction": "in", "protocol": "tcp", "port": "22", "source_ips": ["0.0.0.0/0", "::/0"]},
    {"direction": "in", "protocol": "tcp", "port": "80", "source_ips": ["0.0.0.0/0", "::/0"]},
    {"direction": "in", "protocol": "tcp", "port": "443", "source_ips": ["0.0.0.0/0", "::/0"]}
  ]
}
JSON
)"
  api POST "/firewalls" -d "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["firewall"]["id"])'
}

collect_pubkeys() {
  PUBKEYS=()
  if [[ -f "$ED25519_PUB" ]]; then
    PUBKEYS+=("$(cat "$ED25519_PUB")")
  fi
  if [[ -f "$LIGHTSAIL_PEM" ]]; then
    PUBKEYS+=("$(ssh-keygen -y -f "$LIGHTSAIL_PEM")")
  fi
  [[ ${#PUBKEYS[@]} -gt 0 ]] || die "No SSH public keys found (expected $ED25519_PUB or $LIGHTSAIL_PEM)"
}

existing_server() {
  api GET "/servers?name=$NAME" | python3 -c 'import json,sys
d=json.load(sys.stdin)
s=d.get("servers") or []
if s:
    print(s[0]["id"], s[0].get("public_net",{}).get("ipv4",{}).get("ip",""))
'
}

main() {
  collect_pubkeys

  local existing
  existing="$(existing_server || true)"
  if [[ -n "$existing" ]]; then
    log "Server $NAME already exists: $existing"
    echo "$existing" | awk '{print $2}'
    return 0
  fi

  local key_ids=() firewall_id
  if [[ -f "$ED25519_PUB" ]]; then
    key_ids+=("$(ensure_ssh_key "${NAME}-ed25519" "$(cat "$ED25519_PUB")")")
  fi
  if [[ -f "$LIGHTSAIL_PEM" ]]; then
    key_ids+=("$(ensure_ssh_key "${NAME}-lightsail" "$(ssh-keygen -y -f "$LIGHTSAIL_PEM")")")
  fi
  firewall_id="$(ensure_firewall)"

  local user_data
  user_data="$(
    python3 -c '
import sys
keys = sys.stdin.read().strip().splitlines()
print("#cloud-config")
print("users:")
print("  - name: ubuntu")
print("    sudo: ALL=(ALL) NOPASSWD:ALL")
print("    groups: sudo")
print("    shell: /bin/bash")
print("    ssh_authorized_keys:")
for k in keys:
    print(f"      - {k}")
print("ssh_pwauth: false")
print("disable_root: true")
print("package_update: true")
print("packages:")
print("  - curl")
print("  - git")
print("  - build-essential")
print("  - ufw")
print("  - fail2ban")
print("write_files:")
print("  - path: /etc/ssh/sshd_config.d/99-cleat-hardening.conf")
print("    permissions: \"0644\"")
print("    content: |")
print("      PasswordAuthentication no")
print("      KbdInteractiveAuthentication no")
print("      PermitRootLogin no")
print("      MaxAuthTries 3")
print("      AllowUsers ubuntu")
print("      PubkeyAuthentication yes")
print("  - path: /etc/fail2ban/jail.d/cleat-sshd.local")
print("    permissions: \"0644\"")
print("    content: |")
print("      [DEFAULT]")
print("      bantime.increment = true")
print("      bantime.factor = 2")
print("      bantime.maxtime = 1w")
print("")
print("      [sshd]")
print("      enabled = true")
print("      backend = systemd")
print("      journalmatch = _COMM=sshd")
print("      maxretry = 3")
print("      findtime = 10m")
print("      bantime = 1h")
print("runcmd:")
print("  - [ufw, allow, OpenSSH]")
print("  - [ufw, allow, 80/tcp]")
print("  - [ufw, allow, 443/tcp]")
print("  - [ufw, allow, 443/udp]")
print("  - [ufw, --force, enable]")
q = chr(39)
print("  - bash -lc " + q + "printf \"[DEFAULT]\\nignoreip = 127.0.0.1/8 ::1 %s\\n\" \"$(hostname -I)\" > /etc/fail2ban/jail.d/cleat-ignore.local" + q)
print("  - [systemctl, reload, ssh]")
print("  - [systemctl, enable, --now, fail2ban]")
' <<<"$(printf '%s\n' "${PUBKEYS[@]}")"
  )"

  local body
  body="$(python3 -c '
import json, sys
name, typ, image, location, firewall = sys.argv[1:6]
ssh_ids = [int(x) for x in sys.argv[6:] if x]
user_data = sys.stdin.read()
print(json.dumps({
  "name": name,
  "server_type": typ,
  "image": image,
  "location": location,
  "ssh_keys": ssh_ids,
  "firewalls": [{"firewall": int(firewall)}],
  "user_data": user_data,
  "labels": {"role": "paas", "plan": "cx33"}
}))
' "$NAME" "$TYPE" "$IMAGE" "$LOCATION" "$firewall_id" "${key_ids[@]}" <<<"$user_data")"

  log "Creating $NAME ($TYPE) in $LOCATION"
  local created
  created="$(api POST "/servers" -d "$body")"
  local server_id ip
  server_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["id"])' <<<"$created")"

  log "Waiting for server $server_id to become running"
  for _ in $(seq 1 60); do
    local info
    info="$(api GET "/servers/$server_id")"
    local status
    status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["status"])' <<<"$info")"
    ip="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["public_net"]["ipv4"]["ip"])' <<<"$info")"
    if [[ "$status" == "running" && -n "$ip" ]]; then
      log "CX33 is running at $ip"
      echo "$ip"
      return 0
    fi
    sleep 5
  done

  die "Timed out waiting for $NAME to become running"
}

main "$@"
