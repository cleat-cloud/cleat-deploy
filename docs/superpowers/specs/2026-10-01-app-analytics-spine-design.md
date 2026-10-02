# App analytics spine (Cleat panel)

**Date:** 2026-10-01  
**Status:** Proposed — awaiting approval  
**Repo:** `cleat-cloud/cleat-deploy` (`cleat-web`)  
**Destination:** GA-like analytics in a later set of cortes. This spec is corte 1 (spine) only.

## Problem

The panel can list apps and show HTTP volume from Caddy (`AccessCounts` / “Most requested · 24h”). It cannot answer product questions: which pages humans opened, which referrers and UTM tags brought them, how that compares across apps. Operators currently SSH into tenant SQLite or guess from access logs.

Caddy access logs mix bots, health checks, APIs, and assets. The panel SQLite already failed under high-volume `log_events`; raw pageviews must not land in `cleat.db`.

## Goals

1. **Visited ranking** on the dashboard (JS pageviews, 24h) next to the existing **Requested** ranking (Caddy HTTP hits).
2. **Per-app Analytics tab:** pageviews, daily uniques, time series, top paths, top referrers, top UTM. Windows: 24h, 7d, 90d.
3. **Zero app-repo changes:** Caddy + a loopback unit inject a first-party script into HTML.
4. **Sidecar store** per VPS: raw hits 7 days, daily rollups 90 days, never in `cleat.db`.
5. **Site stays up if analytics dies:** Caddy fails over to the app port.

## Non-goals (later cortes)

| Corte | Later | Not in this spec |
|-------|--------|------------------|
| 2 Eventos | `cleat.track()`, bounce, funnels | custom events |
| 3 Contexto | geo, device, realtime | UA parsing, GeoIP |
| 4 Identidade | first-party cookie, sessions | `_cleat` cookie, consent banner |
| — | SPA client-side navigations | history API pageviews |
| — | HTTP status on the Analytics tab | 2xx/5xx (Requested already covers HTTP) |
| — | ClickHouse / Tinybird | external store |
| — | Caddy `replace-response` / xcaddy | leaving the apt Caddy package |
| — | CLI/MCP toggle | panel UI + provision is enough |

Generic static drops (`cleat drop` memos, `*.sites` noise) stay unmeasured until someone flips the toggle.

## Decisions

| Topic | Choice |
|-------|--------|
| Surfaces | Dashboard visited + requested; app Analytics tab |
| Collector | First-party JS, Caddy-injected, `sendBeacon('/cleat/a')` on load |
| Who is measured | Runtimes default ON; static default OFF; product LPs default ON |
| Product LP slugs | `config :cleat_deploy, :analytics_product_lp_slugs, ~w(cleat cleat-paas fagulha)` |
| Identity | HMAC-SHA256 of `ip + ua + host + UTC date` with a server salt. No cookie. No stored IP/UA |
| Store | SQLite sidecar `/var/lib/cleat-analytics/analytics.db` |
| Retention | Raw 7d; daily rollups 90d; size cap then oldest raw deleted |
| Ingest | `cleat-analytics.service` on each app VPS, loopback only |
| Implementation of the unit | CPython 3 stdlib (`http.server` + `sqlite3`) shipped from `priv/analytics`. No compile on the VPS, no Go in panel CI |
| Panel reads | `GET 127.0.0.1:8799/v1/…` local; SSH `curl` on remote servers; 60s ETS cache |
| Requested chart | Unchanged `AccessCounts` / `access.log` |

Purple Stock marketing LP is not in the slug list until its static app slug is added to that config (or toggled in the UI). The inventory runtime (`purplestock`) is a runtime, so it defaults ON.

## Architecture

One process per VPS, many hosts.

```
browser
  GET /login
    → Caddy (public host)
        handle /cleat/a.js, /cleat/a  → 127.0.0.1:8799   (no wake)
        @websocket (Connection Upgrade) → 127.0.0.1:<app.port>  (skip the unit)
        other → reverse_proxy 127.0.0.1:8799, 127.0.0.1:<app.port>
                lb_policy first, dial_timeout 250ms
    → cleat-analytics (when up)
        HTML text/html with </body>  → inject <script src="/cleat/a.js" defer></script>
        JSON / files                 → pass through
        POST /cleat/a                → sidecar SQLite
    → app or loopback file_server
```

WebSockets (Phoenix LiveView, ActionCable, Chatwoot) never enter the Python unit. Caddy matches `header Connection *Upgrade*` + `header Upgrade websocket` and proxies straight to the app port.

Stock Caddy from apt cannot rewrite HTML bodies. The unit is therefore the injecting reverse proxy, not a Caddy plugin.

The panel never writes pageviews. It only:

- stores `apps.analytics_inject`
- provisions Caddy, the unit, `/etc/cleat/analytics-hosts.json`, and the salt
- queries summaries for LiveView

### Inject ON vs OFF

**ON (runtime):** public site `reverse_proxy` first hop is `:8799`, second is `127.0.0.1:<app.port>`, `lb_policy first`, `dial_timeout 250ms`, passive health `max_fails 1`, `fail_duration 10s`. `/cleat/a.js` and `POST /cleat/a` always go to `:8799` and do not use the app-port fallback (a 502 on collect is fine).

**ON (static):** public site is the same proxy pair. A **loopback** Caddy site `http://127.0.0.1:<app.port>` serves the existing `file_server` root (static apps already have a unique `apps.port` that nothing binds today). Public Caddy stops using `file_server` on the public address while inject is on.

**OFF:** Caddy matches today’s provision (runtime `reverse_proxy` to the app port, static `file_server` on the public address). No extra hop.

**Wake:** `handle` for `/cleat/a` and `/cleat/a.js` is **before** `forward_auth`. Beacons do not start idle units. Document requests still go through `forward_auth` then the proxy pair. WebSocket handles sit with the other app traffic (after wake), because an idle LiveView must be woken.

**Gzip:** `encode gzip` stays on the public site. The unit sees uncompressed localhost responses and must not gzip.

## Ingest unit

### Process

- Binary/script: `priv/analytics/cleat_analytics.py` installed to `/usr/local/lib/cleat/cleat_analytics.py`
- systemd `cleat-analytics.service`: `DynamicUser=yes`, `StateDirectory=cleat-analytics`, `Nice=10`, `CPUQuota=20%`, `MemoryMax=64M`, `Restart=always`, `RestartSec=2`
- Bind `127.0.0.1:8799` only
- Threaded HTTP: collect and proxy must not share one worker (a slow HTML inject cannot block `POST /cleat/a`)
- Env: `CLEAT_ANALYTICS_DB` (default state dir), `CLEAT_ANALYTICS_HOSTS=/etc/cleat/analytics-hosts.json`, `CLEAT_ANALYTICS_SALT=/etc/cleat/analytics.salt`
- Provision is idempotent. Install/refresh the unit when any app on the server has `analytics_inject = true`. When every app is off, leave the unit installed (it is idle on loopback) and write Caddy without the extra hop. Do not uninstall on toggle.

### Hosts file

`/etc/cleat/analytics-hosts.json`, mode 644, rewritten from the panel as the set of apps on that server with `analytics_inject = true`:

```json
{
  "nfe.gestaobem.com": {"slug": "nfe-facil", "upstream": "127.0.0.1:4033"},
  "cleat.sites.gestaobem.com": {"slug": "cleat", "upstream": "127.0.0.1:4010"}
}
```

Unknown `Host` → collect returns 204 and drops. Proxy uses `upstream` from this file (SNI/Host of the incoming request).

### Salt

`/etc/cleat/analytics.salt`: 32 random bytes, created once (`install -m 640` if missing). HMAC key. Rotating it resets uniques from that UTC day forward; provision must not rotate on every deploy.

### Collect API (first-party)

`POST /cleat/a`

- Max body 8 KiB
- Content-Type `application/json` or `text/plain` (sendBeacon)
- Response **always 204** (including errors)
- Accepted JSON: `{ "n": "pageview", "u": "<full URL>", "r": "<document.referrer or empty>" }`
- Any `n` other than `pageview` is dropped (corte 2 will use the same path)
- Client IP: last hop is Caddy on loopback; use `X-Forwarded-For` first IP if present else peer
- Persist only:

  | Column | Rule |
  |--------|------|
  | `ts` | server UTC unix |
  | `host` | request Host, must be in hosts file |
  | `path` | pathname of `u`, max 512 chars, no query; `/foo/` → `/foo`; empty → `/` |
  | `referrer` | host of `r`; empty if missing or same as `host` |
  | `utm_source`, `utm_medium`, `utm_campaign` | from query of `u` only; max 128 chars; else empty |
  | `visitor_hash` | hex HMAC-SHA256(salt, `ip \\n ua \\n host \\n YYYY-MM-DD`) |
  | `name` | `pageview` |

Do not store IP, User-Agent, full URL, or raw query.

### Script

`GET /cleat/a.js` — `Cache-Control: public, max-age=3600`, `Content-Type: application/javascript`. Body is a few lines: read `location.href` and `document.referrer`, `navigator.sendBeacon('/cleat/a', blob)`. No cookie, no `track()`, no fingerprint besides what the server hashes.

### Proxy

For non-`/cleat/*` requests the unit reverse-proxies to `upstream`:

- Hop-by-hop headers stripped
- Unknown `Content-Type` streamed, not buffered (Caddy already diverted WebSockets)
- Buffer `text/html` (and `text/html; charset=*`) up to 1 MiB; if `</body>` / `</BODY>` present, insert the script tag immediately before the last occurrence; otherwise pass through
- If upstream dial fails, return 502 (Caddy then tries the app port)

### Read API (loopback, panel only)

No auth (loopback). Used by the panel via HTTP local or SSH `curl --max-time 3`.

- `GET /healthz` → 200
- `GET /v1/visited?range=24h` → `[{host, slug, pageviews}, …]` sorted desc, max 20
- `GET /v1/apps/{host}?range=24h|7d|90d` → totals, uniques, series, top paths/referrers/utm (top 20 each)

`24h` and `7d` read raw `hits`. `90d` reads rollup tables (daily buckets).

**Unique display rule:**

- 24h: `count(distinct visitor_hash)` over raw hits in the window (one UTC day-ish; hashes already rotate at UTC midnight, so this is “distinct hashes in the window”).
- 7d: `count(distinct visitor_hash)` over raw (still one hash per person per UTC day, so this is an upper bound, not true 7-day uniques). Label in the UI: **Uniques** with subtitle **hash per UTC day**.
- 90d: `sum(unique_visitors)` from `daily_totals`. Same label. Do not pretend this is GA users.

### Rollup and prune

Hourly (same process, timer thread):

1. For each UTC date with raw hits, upsert rollups:
   - `daily_totals(day, host, pageviews, unique_visitors)`
   - `daily_paths(day, host, path, pageviews)`
   - `daily_referrers(day, host, referrer, pageviews)`
   - `daily_utm(day, host, utm_source, utm_medium, utm_campaign, pageviews)`
2. Delete `hits` with `ts` older than 7 days
3. Delete rollup rows older than 90 days
4. If `analytics.db` file size `> 200 MiB`, delete oldest raw days until under 150 MiB

WAL mode, `busy_timeout=5000`, `synchronous=NORMAL`.

## Sidecar schema

```sql
CREATE TABLE hits (
  ts INTEGER NOT NULL,
  host TEXT NOT NULL,
  path TEXT NOT NULL,
  referrer TEXT NOT NULL DEFAULT '',
  utm_source TEXT NOT NULL DEFAULT '',
  utm_medium TEXT NOT NULL DEFAULT '',
  utm_campaign TEXT NOT NULL DEFAULT '',
  visitor_hash TEXT NOT NULL,
  name TEXT NOT NULL
);
CREATE INDEX hits_host_ts ON hits(host, ts);

CREATE TABLE daily_totals (
  day TEXT NOT NULL,
  host TEXT NOT NULL,
  pageviews INTEGER NOT NULL,
  unique_visitors INTEGER NOT NULL,
  PRIMARY KEY (day, host)
);
-- daily_paths / daily_referrers / daily_utm similarly, PRIMARY KEY includes the dimension.
```

## Panel

### `apps.analytics_inject`

Boolean, not null.

Default on insert (`CleatDeploy.Analytics.default_inject?/1`):

- `true` when `runtime` is not `"static"`
- `true` when `slug` is in `:analytics_product_lp_slugs`
- `false` otherwise

Migration backfill uses the same rule. Toggle on the app settings (Environment or a one-line switch on the Analytics tab) calls provision/reload so Caddy and the hosts file update.

### Dashboard

Keep `#chart-access` / “Most requested · 24h”.

Add `#chart-visited` / “Most visited · 24h” using `PaasComponents.Bars` the same way. Empty state: “No pageviews yet”. Clicking a bar/name goes to that app’s Analytics tab.

Do not merge the two series. An API-only app can lead Requested and be absent from Visited.

`Insights` grows a `top_visited` list. Fetch via `CleatDeploy.Analytics.Summary.visited(server)` (local HTTP or SSH) **per tenant server**, merge by host, take top 20. Timeout 3s per server; on error keep last ETS value and set `visited_stale: true` (copy: “Visited · stale”).

### App tab

New tab **Analytics** in `AppLive.Layout.Tabs` (own show module, keep files under the LiveView size guard). Visible for every app (so a static drop can be turned on). If inject is off, the tab shows the toggle and “Not measuring”. If on, range picker 24h / 7d / 90d and the numbers above.

### Names

| UI | Unit | Source |
|----|------|--------|
| Most visited | pageviews | sidecar |
| Most requested | HTTP requests | `/var/log/caddy/access.log` |
| Uniques | daily HMAC hashes | sidecar |

Reserved paths on every measured host: `/cleat/a` and `/cleat/a.js` only (not the whole `/cleat/` tree). Document next to other reserved paths. Apps that already serve those two paths must be called out in implementation; none are known in prod.

## Failure modes

| Failure | Behaviour |
|---------|-----------|
| Unit down | Caddy dial to `:8799` fails in 250ms, traffic hits app port. No script, no collect. Site up |
| Unit hung after accept | Passive health (`max_fails 1`, `fail_duration 10s`) skips `:8799` once a proxy request fails; collect handle may 502 until the unit recovers |
| Unit up, SQLite busy/disk | POST still 204; drop row; journal the unit |
| Body > 8 KiB / bad JSON / unknown host | 204, drop |
| HTML without `</body>` | no inject, body unchanged |
| Remote summary timeout | dashboard Requested still live; Visited shows last cache or empty + stale |
| Toggle OFF | next provision writes the old Caddy shape; hosts file omits the host |
| Panel down | collect continues (unit is independent) |
| Salt missing | unit refuses to start (healthz fail) so Caddy failovers; provision creates the salt |

## Testing (TDD)

Write failing tests first.

- `Analytics.default_inject?/1` for runtime, static, and product LP slugs
- Caddy site generation: inject ON runtime (handles `/cleat/a` + `/cleat/a.js`, websocket matcher to the app port, two upstreams, `lb_policy first`, `dial_timeout`); inject ON + wake (`/cleat/a*` before `forward_auth`, websocket after wake); inject ON static (loopback file_server + public proxy); inject OFF equals today’s snippet
- Hosts file JSON from a server’s measured apps
- Dashboard LiveView renders `#chart-visited` and keeps `#chart-access`
- App Analytics tab: off state, on state with stubbed summary
- Sidecar script: a Mix test runs `python3 -m unittest` in `priv/analytics` (HMAC, UTM/path/referrer sanitise, unknown host drop, prune windows, HTML inject before `</body>`, skip non-HTML). No extra CI job.
- SQLite DataCase/ConnCase stay `async: false`

Do not hit a real VPS in `mix test`. Stub SSH/HTTP like `HostStats`.

## Likely files

- `priv/analytics/cleat_analytics.py` + `priv/analytics/test_cleat_analytics.py`
- `lib/cleat_deploy/analytics.ex`, `analytics/summary.ex`, `deploy/analytics_provision.ex`
- `lib/cleat_deploy/deploy/server_provision.ex` (Caddy snippets)
- `lib/cleat_deploy/apps/app.ex` + migration
- `lib/cleat_deploy/servers/insights.ex`, dashboard LiveView + `paas_components/bars.ex` as needed
- `lib/cleat_deploy_web/live/app_live/layout/tabs.ex` + new Analytics show module
- Tests next to each

`AccessCounts` stays the Requested path. Do not reuse `log_events`.

## Success

On gestaobem-cx33, with inject on for NFe (runtime) and `cleat` (LP):

1. View-source of the app HTML contains `/cleat/a.js`
2. Loading the page inserts a row in `analytics.db`
3. Dashboard Visited lists those hosts; Requested still lists HTTP-heavy APIs
4. App Analytics tab shows path `/` (or the real path), referrer empty or an external host, UTM when the URL had `utm_source`
5. `systemctl stop cleat-analytics` leaves the app on HTTPS; script disappears until the unit returns
