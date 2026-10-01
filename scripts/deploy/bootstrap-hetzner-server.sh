#!/usr/bin/env bash
# Bootstrap Caddy, Go, mise/Elixir, and swap on a Hetzner Ubuntu box.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/scripts/deploy/deploy.local.env" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/deploy/deploy.local.env"
fi

DEPLOY_IP="${HETZNER_SERVER_IP:-${DEPLOY_IP:-}}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/lightsail-default-key-us-east-1.pem}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
CADDY_EMAIL="${CADDY_EMAIL:-admin@gestaobem.com}"

log() { printf '→ %s\n' "$*" >&2; }
die() { echo "Error: $*" >&2; exit 1; }

[[ -n "$DEPLOY_IP" ]] || die "Set HETZNER_SERVER_IP (or DEPLOY_IP) to the CX33 public IPv4"
[[ -f "$DEPLOY_SSH_KEY" ]] || die "SSH key not found: $DEPLOY_SSH_KEY"
chmod 600 "$DEPLOY_SSH_KEY"

ssh_cmd() {
  ssh -i "$DEPLOY_SSH_KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=20 \
    "${DEPLOY_USER}@${DEPLOY_IP}" "$@"
}

log "Waiting for SSH on $DEPLOY_USER@$DEPLOY_IP"
for _ in $(seq 1 36); do
  if ssh_cmd "echo ready" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
ssh_cmd "echo ready" >/dev/null || die "SSH not ready on $DEPLOY_IP"

log "Bootstrapping Hetzner host $DEPLOY_IP"
ssh_cmd "CADDY_EMAIL='$CADDY_EMAIL' bash -s" <<'REMOTE'
set -euo pipefail
log() { printf '→ %s\n' "$*" >&2; }

log "Waiting for apt lock"
for _ in $(seq 1 60); do
  if sudo apt-get -qq check >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if ! swapon --show | grep -q /swapfile; then
  log "Creating 4GB swap"
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

log "Installing base packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git openssh-client tar curl ca-certificates build-essential rsync ufw fail2ban

log "Hardening sshd and enabling fail2ban"
sudo mkdir -p /etc/ssh/sshd_config.d /etc/fail2ban/jail.d
sudo tee /etc/ssh/sshd_config.d/99-cleat-hardening.conf >/dev/null <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 3
AllowUsers ubuntu
PubkeyAuthentication yes
SSHD
sudo tee /etc/fail2ban/jail.d/cleat-sshd.local >/dev/null <<'JAIL'
[DEFAULT]
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

[sshd]
enabled = true
backend = systemd
journalmatch = _COMM=sshd
maxretry = 3
findtime = 10m
bantime = 1h
JAIL
printf '[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 %s\n' "$(hostname -I)" | sudo tee /etc/fail2ban/jail.d/cleat-ignore.local >/dev/null
sudo sshd -t
sudo systemctl reload ssh
sudo systemctl enable --now fail2ban

if ! command -v caddy >/dev/null 2>&1; then
  log "Installing Caddy"
  sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y caddy
fi

if ! command -v go >/dev/null 2>&1; then
  log "Installing Go 1.25.1"
  curl -fsSL https://go.dev/dl/go1.25.1.linux-amd64.tar.gz -o /tmp/go.tgz
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf /tmp/go.tgz
  echo 'export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH' | sudo tee /etc/profile.d/go.sh >/dev/null
fi

if ! command -v node >/dev/null 2>&1; then
  log "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
fi

if ! command -v mise >/dev/null 2>&1; then
  log "Installing mise"
  curl -fsSL https://mise.run | sh
fi

export PATH="$HOME/.local/bin:/usr/local/go/bin:$PATH"
eval "$("$HOME/.local/bin/mise" activate bash)"
mise install erlang@28.4.1 elixir@1.19.5-otp-28
mise use -g erlang@28.4.1 elixir@1.19.5-otp-28

sudo mkdir -p /etc/caddy
if [[ ! -f /etc/caddy/Caddyfile ]]; then
  sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDY
{
	email ${CADDY_EMAIL}
}

:80 {
	redir https://{host}{uri} permanent
}
CADDY
fi

sudo systemctl enable --now caddy
log "Bootstrap complete"
REMOTE

log "Hetzner host $DEPLOY_IP is ready"
