# `.cleat_deploy/deploy.json`

Optional manifest read from the repository on **every deploy** (after the clone
and before the build). Everything here overrides what the panel detected: app
registration values, `mix.exs`/`go.mod`/framework detection, and the built-in
defaults.

```json
{
  "runtime": "rails",
  "processes": {
    "web": "bundle exec rails server -b 0.0.0.0 -p $PORT",
    "worker": "bundle exec sidekiq -C config/sidekiq.yml"
  },
  "release_command": "bundle exec rails db:chatwoot_prepare",
  "release_timeout_s": 600,
  "addons": ["postgres:pgvector", "redis"]
}
```

A malformed file is ignored silently (the deploy falls back to detection).
Values that are wrong in a way the build cannot recover from fail **before** the
deploy touches the server, with the reason in the deploy log.

## Build and publish

| key | type | default | what it does |
|---|---|---|---|
| `runtime` | `"phoenix" \| "golang" \| "node" \| "rails" \| "rust" \| "gleam" \| "static"` | detected, else `phoenix` | Chooses the build/run pipeline. |
| `build_dir` | string | auto-detected | Subdirectory holding the project (monorepos). |
| `build_command` | string | runtime default | Overrides the build step (e.g. `npm run build:prod`). |
| `start_command` | string | runtime default | Command the app's `web` process runs. |
| `node_version` | string | `engines.node` → `22` | Node major installed for the build (node runtime and Rails asset pipeline). |
| `ruby_version` | string | `.ruby-version` → Gemfile → `3.3.6` | Ruby version installed through mise. |
| `gleam_version` | string | `1.18.1` | Gleam version installed through mise (Erlang is pinned to the panel's `28.4.1`). |
| `binaries` | list | `["server"]` | Go runtime only: one systemd unit per binary (`server` owns the base unit, others get `<unit>-<name>`). |

## Hosting

| key | type | default | what it does |
|---|---|---|---|
| `memory_max_mb` | int | `400` (`256` for Go) | `MemoryMax` of every unit of the app. |
| `systemd_unit` | string | from the slug | Base unit name. Overrides the panel value. |
| `release_path` | string | `/opt/<slug>` (`/var/www/<slug>` for static) | Where releases, `current` and the data dir live. |
| `release_name` | string | from the slug / `mix.exs` | OTP release name (Phoenix). |
| `caddy_mode` | `"append"` \| `"replace"` | `"append"` | `replace` copies the repo's own Caddyfile instead of managing the site block. |
| `caddyfile` | string | — | Path (in the repo) of the Caddyfile used with `caddy_mode: "replace"`. |
| `caddy_listen_port` | int | app port | Port Caddy proxies to (the app must bind it too). |
| `solo_server` | bool | `false` | The app requires a dedicated server; deploys to a shared server are rejected. |

## Release phase

| key | type | default | what it does |
|---|---|---|---|
| `release_command` | string \| list of strings | — | Runs after the release is published in `current/` and **before** the service restarts. |
| `release_timeout_s` | int ≥ 30 | `300` | Timeout for each release command. |

Semantics:

- Runs as root with the app env file sourced (`/etc/<app>/env`), `CLEAT_DATA_DIR`
  set and the working directory in `<release_path>/current`, so it sees exactly
  the environment the service will.
- Output goes into the deploy log; a non-zero exit **aborts the deploy** and the
  service is not restarted (the previous process keeps serving).
- A `release_command` **replaces** the runtime's default migration step
  (`rails db:prepare`, Phoenix `bin/migrate`), which is what you want for apps
  with their own task (`rails db:chatwoot_prepare`) or for `mix ecto.migrate`.
- Impossible for `static` (there is no service to restart).

## Processes (multi-process apps)

| key | type | default | what it does |
|---|---|---|---|
| `processes` | object `name → command` | single process | One systemd unit per entry. |

Rules:

- The **`web` process is required** and owns the base unit (`<systemd_unit>`); it
  is the only one that gets `PORT`/`HOST` and the only target of the Caddy
  reverse proxy.
- Every other process becomes `<systemd_unit>-<name>` (e.g. `rails-foo-worker`)
  and gets **no `PORT`** — a worker must never bind the app port.
- All units share the env file, `CLEAT_DATA_DIR`, `Restart=always`,
  `KillMode=control-group` and `MemoryMax`.
- Deploys restart every unit, `web` first.
- **Sleep/wake applies to the HTTP process only**: the wake agent, the idle
  sweeper and the Hibernate/Wake up buttons act on the base unit, so a sleeping
  app keeps its workers running (queues do not stop).

Runtimes: `rails`, `node` and `rust`. A single-process app omits `processes` and
behaves exactly as before.

## Addons

| key | type | default | what it does |
|---|---|---|---|
| `addons` | list | `[]` | Managed datastores provisioned on the server and injected as env vars. |

Known addons:

- **`postgres:pgvector`** (alias `postgres`) — installs PostgreSQL on the server,
  creates a role + database for the app (`cleat_<slug>`) and enables the
  `vector` and `pg_stat_statements` extensions. Injects
  `DATABASE_URL=postgres://cleat_<slug>:<password>@127.0.0.1:5432/cleat_<slug>`.
- **`redis`** — installs Redis and creates a per-app ACL user
  (`cleat_<slug>`). Injects
  `REDIS_URL=redis://cleat_<slug>:<password>@127.0.0.1:6379/<db>`.

Notes:

- Credentials are generated by the panel, stored with the app's env vars
  (encrypted at rest) and can be rotated from the app page (a redeploy is
  required to pick up the new password).
- Data lives in the distro's service directories (`/var/lib/postgresql/…`,
  `/var/lib/redis`), outside `release_path`, so it survives deploys.
- One service per server, one credential/database per app. Without `addons` in
  the manifest nothing changes: Cleat touches no datastore, and you can point
  `DATABASE_URL`/`REDIS_URL` at your own service through the app's env vars.

## Example: Rails with a worker (Chatwoot-like)

```json
{
  "runtime": "rails",
  "solo_server": true,
  "memory_max_mb": 2048,
  "node_version": "20",
  "processes": {
    "web": "bundle exec rails server -b 0.0.0.0 -p $PORT",
    "worker": "bundle exec sidekiq -C config/sidekiq.yml"
  },
  "release_command": ["bundle exec rails db:chatwoot_prepare"],
  "release_timeout_s": 900,
  "addons": ["postgres:pgvector", "redis"]
}
```

Deploy order: clone → Ruby/Node → `bundle install` → assets (Vite cache reused
across deploys) → publish to `releases/build` and point `current` at it →
provision units + addons → release command (migrations) → restart `web` then
`worker` → reload Caddy.
