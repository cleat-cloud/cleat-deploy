# Cleat

Self-hosted PaaS control panel. Deploy **Phoenix/Elixir**, **Go**, **Node (Next.js / TanStack Start)**, **Ruby on Rails**, **Rust (Loco)** and **static sites** to **Hetzner Cloud** (CX33) or AWS Lightsail over SSH, with GitHub push-to-deploy.

Formerly Phoenix PaaS. OTP app: `cleat_deploy`.

Register VMs, link GitHub repos, trigger manual deploys or push-to-deploy, and watch builds in a live terminal. Pair it with the [`cleat` CLI](https://github.com/cleat-cloud/cleat-cli).

![Cleat dashboard — Trip Planner deployed on Lightsail](docs/images/dashboard.jpg)

## Features

- **Servers** — register Hetzner Cloud or Lightsail VMs (IP, location, SSH user)
- **Runtimes** — Phoenix OTP releases, Go/Cais binaries, Node servers (Next.js / TanStack Start), Rails/Puma, Rust/Loco binaries, and static sites. Auto-detected from the repo or set via `runtime` in `.cleat_deploy/deploy.json` ([manifest reference](docs/deploy-json.md))
- **Release phase** — `release_command` runs after publishing and before the restart; a failure keeps the previous release serving
- **Multi-process apps** — `processes` (web + worker) as one systemd unit each; only `web` binds the port and goes to sleep when idle
- **Managed addons** — `addons: ["postgres:pgvector", "redis"]` provisions the datastores on the server and injects `DATABASE_URL`/`REDIS_URL`
- **Deployments** — queued → running → success/failed, with build logs and paginated history
- **GitHub webhooks** — HMAC-verified `POST /webhooks/github`
- **Oban queue** — background deploy worker with Mox-tested runner behaviour
- **SSH deploys** — clone, build on the VM, migrate, restart systemd
- **CLI** — [`cleat`](https://github.com/cleat-cloud/cleat-cli) for servers, apps, env vars, deploys and log streaming

## Requirements

- Elixir 1.15+ / OTP 26+
- SQLite (dev/test) — no external DB needed to get started

## Quick start

```bash
git clone https://github.com/cleat-cloud/cleat-deploy.git
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
Plain HTML/CSS/JS folders need no build and work as-is. They can also be
published without git via `cleat drop`, which uploads a folder to
`POST /api/v1/apps/:app/drops` and publishes it the same way.

### Node / SSR apps (Next.js, TanStack Start)

Set `runtime: "node"` (or `"runtime": "node"` in `.cleat_deploy/deploy.json`).
The panel installs Node, runs `npm ci` and `npm run build`, publishes the project
to `/opt/<slug>/current`, and keeps it alive with a `node-<slug>` systemd unit
behind the Caddy reverse proxy. Before publishing it shrinks the release so
`node_modules` does not fill the disk: `npm prune --omit=dev` for regular Node
apps, or no `node_modules` at all for TanStack Start / Nitro (the `.output`
bundle is self-contained). The start command is resolved at build time:
`start_command` from the manifest, else `npm run start`, else
`node .output/server/index.mjs` (TanStack Start / Nitro), else
`npm exec -- next start` (Next.js). Override the toolchain with `node_version`
(e.g. `"20"`; defaults to the latest 22.x), `build_command`, and `build_dir` for
monorepos.

### Ruby on Rails apps

Set `runtime: "rails"` (or `"runtime": "rails"` in `.cleat_deploy/deploy.json`).
The panel installs Ruby via mise (version from `ruby_version`, `.ruby-version`
or the Gemfile `ruby` directive), runs `bundle install`, `assets:precompile` and
`db:prepare`, publishes the project to `/opt/<slug>/current`, and keeps Puma
alive with a `rails-<slug>` systemd unit behind the Caddy reverse proxy.
`DATABASE_URL`, `SECRET_KEY_BASE` and `RAILS_MASTER_KEY` are read from the panel
env vars. Start command: `start_command` → `bundle exec puma -C config/puma.rb`
→ `bundle exec puma -b tcp://0.0.0.0:$PORT`.

### Rust / Loco apps

Set `runtime: "rust"` (or put `"runtime": "rust"` in `.cleat_deploy/deploy.json`).
A repo with `Cargo.toml` is detected automatically. The panel installs rustup,
runs `cargo build --release` (the target dir is cached across deploys), copies
the binary as `bin/server` plus `config/`, `assets/` and `frontend/`, and keeps
it alive with a `rust-<slug>` systemd unit behind Caddy.

Loco apps (`loco-rs` in `Cargo.toml` or `config/production.yaml`) start with
`./bin/server start`, run `./bin/server db migrate` before the restart, and
get `LOCO_ENV=production`, `PORT`, `BINDING=127.0.0.1` and
`HOST=https://<app host>`. Set `DATABASE_URL` and `JWT_SECRET` as panel env
vars. A `frontend/package.json` is built with npm. Plain Rust binaries (Axum
and friends) run as `./bin/server`. Override with `build_command` and
`start_command`.

Rails, Node and Rust apps can also declare a **release phase**, **multiple
processes** (web + worker) and **managed addons** (Postgres with pgvector,
Redis) in `.cleat_deploy/deploy.json` — full reference in
[docs/deploy-json.md](docs/deploy-json.md).

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

## License

MIT