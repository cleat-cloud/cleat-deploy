# Cleat

Control panel for deploying **Phoenix/Elixir** and **Go (Cais)** apps to **Hetzner Cloud** (CX33) or AWS Lightsail via GitHub webhooks.

Formerly Phoenix PaaS. OTP app: `cleat_deploy`.

Register VMs, link GitHub repos, trigger manual deploys or push-to-deploy, and watch builds in a live terminal.

![Cleat dashboard — Trip Planner deployed on Lightsail](docs/images/dashboard.jpg)

## Features

- **Servers** — register Hetzner Cloud or Lightsail VMs (IP, location, SSH user)
- **Apps** — Phoenix OTP releases, Go/Cais binaries, and static sites (detected from `mix.exs` / `go.mod` / `index.html`)
- **Deployments** — queued → running → success/failed, with build logs
- **GitHub webhooks** — HMAC-verified `POST /webhooks/github`
- **Oban queue** — background deploy worker with Mox-tested runner behaviour
- **SSH deploys** — clone, build on the VM, migrate, restart systemd

## Requirements

- Elixir 1.15+ / OTP 26+
- SQLite (dev/test) — no external DB needed to get started

## Quick start

```bash
git clone https://github.com/puppe1990/cleat-deploy.git
cd cleat-deploy
mix setup
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

## Hetzner CX33 (shared Phoenix + Go host)

CX33 is 4 shared vCPU / 8 GB RAM / 80 GB NVMe / 20 TB traffic. It is **not** sold in Ashburn; the default location is Falkenstein (`fsn1`).

```bash
export HCLOUD_TOKEN=...          # Hetzner Cloud API token
# optional: reuse the Lightsail PEM so the panel can SSH with the existing key
./scripts/deploy/provision-hetzner-cx33.sh
export HETZNER_SERVER_IP=x.x.x.x
./scripts/deploy/bootstrap-hetzner-server.sh
./scripts/deploy/migrate-lightsail-to-hetzner.sh
```

Then point Hostinger A records at the new IP and register the server in the panel:

```bash
HETZNER_SERVER_IP=x.x.x.x bin/cleat_deploy rpc 'Code.eval_file("priv/scripts/setup_hetzner.exs")'
```

Leave Lightsail running until HTTPS on Hetzner is healthy.

## Real deploys (SSH)

By default dev uses `FakeRunner` (simulated logs). For real deploys:

```bash
export DEPLOY_RUNNER=ssh
export GITHUB_TOKEN=ghp_...   # required for private repos
mix phx.server
```

1. Register a server with its **SSH private key (PEM)**
2. Register an app (Trip Planner defaults: `trip_planner_ia`, `/opt/trip_planner_ia`)
3. Click **Deploy now** — clones repo, builds on the VM, migrates, restarts systemd

### Static sites

Set `runtime: "static"` (or put `"runtime": "static"` in `.cleat_deploy/deploy.json`).
The panel runs an optional `npm ci && npm run build`, then publishes the output
directory (`dist`, `build`, `public`, `_site`, `out`, or `build_dir` from the
manifest; if none exist, the repo root when it has an `index.html`) to
`/var/www/<slug>/current`. Caddy serves it with `file_server` and
an SPA fallback (`try_files {path} /index.html`); there is no systemd unit.
Plain HTML/CSS/JS folders need no build and work as-is.

One-off test script (no UI):

```bash
DEPLOY_RUNNER=ssh mix run --no-start priv/scripts/run_deploy_test.exs
```

Requires `git`, `ssh`, `scp`, and `tar` on the machine running the panel.

## Authentication & multi-tenant

Panel routes require login. Each user belongs to a tenant; servers and apps are isolated by `tenant_id`.

Seed the owner account and Trip Planner deploy test:

```bash
SEED_USER_PASSWORD='your-secure-password' mix run priv/repo/seeds.exs
```

This creates `matheus.puppe@gmail.com` as owner of the **Gestão Bem** tenant with the Trip Planner app pre-linked.

## Environment

| Variable | Description |
|----------|-------------|
| `DEPLOY_RUNNER` | `fake` (default) or `ssh` for real deploys |
| `HCLOUD_TOKEN` / `HETZNER_API_TOKEN` | Hetzner Cloud API token (sync specs / resize) |
| `HETZNER_SERVER_IP` | Public IPv4 of the CX33 |
| `GITHUB_TOKEN` | GitHub PAT for cloning private repos |
| `PHX_SERVER` | Set to start HTTP server (e.g. in production) |
| `PORT` | HTTP port (default `4000`) |
| `SECRET_KEY_BASE` | Required in production |
| `CLOAK_KEY` | 32-byte base64 key for SSH private key encryption (production) |
| `TURSO_DATABASE_URL` | `libsql://...` Turso database URL (production) |
| `TURSO_AUTH_TOKEN` | Turso auth token (production) |
| `DATABASE_PATH` | Fallback SQLite path when Turso URL is not set |
| `SEED_USER_PASSWORD` | Password for the seeded `matheus.puppe@gmail.com` account |
| `SEED_SSH_KEY_PATH` | Optional path to Lightsail PEM for seed server (default: `~/.ssh/lightsail-default-key-us-east-1.pem`) |

## Tests

```bash
mix test
mix precommit
```

## Related

- [paas-example](https://github.com/puppe1990/paas-example) — React UI mock of this panel
- [trip-planner-ia-phx](https://github.com/puppe1990/trip-planner-ia-phx) — first production app ([trip.gestaobem.com](https://trip.gestaobem.com))

## License

MIT