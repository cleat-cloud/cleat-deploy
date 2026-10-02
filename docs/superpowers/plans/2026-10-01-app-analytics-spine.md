# App analytics spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship corte 1 analytics in the panel: Caddy-injected first-party pageviews, a per-VPS SQLite sidecar, dashboard **Visited** next to **Requested**, and a per-app Analytics tab.

**Architecture:** Each app VPS runs `cleat-analytics.service` (CPython 3, loopback `:8799`) that collects `POST /cleat/a`, injects `/cleat/a.js` into HTML, and stores raw hits 7d + daily rollups 90d in `/var/lib/cleat-analytics/analytics.db`. Stock Caddy cannot rewrite bodies, so the public site `reverse_proxy`es through the unit when `apps.analytics_inject` is on, with failover to the app port. WebSockets skip the unit. The panel never writes pageviews; it provisions Caddy/hosts/salt and reads summaries over loopback or SSH `curl`.

**Tech Stack:** Phoenix 1.8 LiveView, Ecto/SQLite (`cleat.db` for the boolean only), Caddy 2.11 from apt, systemd, CPython 3 stdlib (`http.server`, `sqlite3`), Req.

**Spec:** `docs/superpowers/specs/2026-10-01-app-analytics-spine-design.md`

**Clarification vs spec:** Visited ranking is scoped to the dashboard **active server**, same as Requested. Do not merge every tenant VPS.

TDD on every task. Mix commands from `cleat-web`. SQLite tests stay `async: false`. After Elixir changes, files must stay under the 400-line LiveView guard (`test/cleat_deploy_web/module_size_test.exs`). Toggle applies on the **next deploy** (provision rewrites Caddy); do not add a new Oban worker.

---

## File structure

```
priv/analytics/cleat_analytics.py              # sidecar: collect, inject proxy, rollup, read API
priv/analytics/test_cleat_analytics.py         # python3 -m unittest

lib/cleat_deploy/analytics.ex                  # default_inject?/2, port, product LP slugs
lib/cleat_deploy/analytics/hosts.ex            # hosts.json map for a server_id
lib/cleat_deploy/analytics/caddy.ex            # public + loopback Caddy site strings
lib/cleat_deploy/analytics/summary.ex          # local HTTP / remote SSH curl
lib/cleat_deploy/analytics/summary_http.ex     # Req + SSH implementation
lib/cleat_deploy/analytics/summary_stub.ex     # test client
lib/cleat_deploy/deploy/analytics_provision.ex # systemd unit + embed python (Wake pattern)

lib/cleat_deploy/apps/app.ex                   # analytics_inject field + changesets
lib/cleat_deploy/apps.ex                       # set_analytics_inject/3
lib/cleat_deploy/deploy/server_provision.ex    # call Caddy + provision snippets
lib/cleat_deploy/servers/insights.ex           # top_visited
priv/repo/migrations/20261001220000_add_apps_analytics_inject.exs

lib/cleat_deploy_web/components/paas_components/bars.ex   # visited_bars/1
lib/cleat_deploy_web/live/dashboard_live.ex
lib/cleat_deploy_web/live/app_live/layout/tabs.ex
lib/cleat_deploy_web/live/app_live/show.ex
lib/cleat_deploy_web/live/app_live/show/tabs.ex
lib/cleat_deploy_web/live/app_live/show/analytics_tab.ex  # new, keep <400 lines
lib/cleat_deploy_web/live/app_live/show/analytics.ex      # events + load summary

config/config.exs
config/test.exs
```

Do not reuse `log_events` or change `AccessCounts`.

---

### Task 1: `default_inject?/2`

**Files:**
- Create: `lib/cleat_deploy/analytics.ex`
- Create: `test/cleat_deploy/analytics_test.exs`
- Modify: `config/config.exs` (append the two keys below)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CleatDeploy.AnalyticsTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Analytics

  test "runtimes default on" do
    for runtime <- ~w(phoenix golang node rails rust gleam) do
      assert Analytics.default_inject?(runtime, "nfe-facil")
    end
  end

  test "generic static defaults off" do
    refute Analytics.default_inject?("static", "memo-drop")
  end

  test "product LP slugs default on even when static" do
    for slug <- ~w(cleat cleat-paas fagulha) do
      assert Analytics.default_inject?("static", slug)
    end
  end

  test "listen port is 8799" do
    assert Analytics.listen_port() == 8799
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cleat_deploy/analytics_test.exs`
Expected: FAIL compiling — `CleatDeploy.Analytics` missing.

- [ ] **Step 3: Write minimal implementation**

Append to `config/config.exs`:

```elixir
config :cleat_deploy, :analytics_listen_port, 8799
config :cleat_deploy, :analytics_product_lp_slugs, ~w(cleat cleat-paas fagulha)
```

`lib/cleat_deploy/analytics.ex`:

```elixir
defmodule CleatDeploy.Analytics do
  @moduledoc """
  Spine analytics defaults. Collection lives on the VPS sidecar, not in cleat.db.
  """

  @runtimes ~w(phoenix golang node rails rust gleam)

  def listen_port do
    Application.get_env(:cleat_deploy, :analytics_listen_port, 8799)
  end

  def product_lp_slugs do
    Application.get_env(:cleat_deploy, :analytics_product_lp_slugs, [])
  end

  def default_inject?(runtime, slug) when is_binary(runtime) and is_binary(slug) do
    runtime in @runtimes or slug in product_lp_slugs()
  end

  def default_inject?(_, _), do: false
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cleat_deploy/analytics_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add config/config.exs lib/cleat_deploy/analytics.ex test/cleat_deploy/analytics_test.exs
git commit -m "feat: default analytics inject on runtimes and product LPs"
```

---

### Task 2: `apps.analytics_inject` column

**Files:**
- Create: `priv/repo/migrations/20261001220000_add_apps_analytics_inject.exs`
- Modify: `lib/cleat_deploy/apps/app.ex` (`schema`, `changeset/2` cast list, new `analytics_inject_changeset/2`, `put_analytics_inject_default/1`)
- Modify: `lib/cleat_deploy/apps.ex` (add `set_analytics_inject/3`)
- Test: `test/cleat_deploy/apps_test.exs` (new describe block)

- [ ] **Step 1: Write the failing tests** at the bottom of `test/cleat_deploy/apps_test.exs`:

```elixir
  describe "analytics_inject" do
    test "phoenix insert defaults on", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix", slug: "nfe-x"})
      assert app.analytics_inject
    end

    test "static insert defaults off", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", slug: "memo-x"})
      refute app.analytics_inject
    end

    test "static product LP defaults on", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", slug: "cleat"})
      assert app.analytics_inject
    end

    test "explicit false wins on insert", %{scope: scope, server: server} do
      app =
        TenancyFixtures.app_fixture(scope, server, %{
          runtime: "phoenix",
          analytics_inject: false
        })

      refute app.analytics_inject
    end

    test "set_analytics_inject/3 flips the flag", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", slug: "memo-y"})
      refute app.analytics_inject
      assert {:ok, updated} = Apps.set_analytics_inject(scope, app, true)
      assert updated.analytics_inject
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cleat_deploy/apps_test.exs`
Expected: FAIL — field / function missing.

- [ ] **Step 3: Write minimal implementation**

Migration:

```elixir
defmodule CleatDeploy.Repo.Migrations.AddAppsAnalyticsInject do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :analytics_inject, :boolean, null: false, default: false
    end

    execute(
      """
      UPDATE apps
      SET analytics_inject = 1
      WHERE runtime != 'static'
         OR slug IN ('cleat', 'cleat-paas', 'fagulha')
      """,
      """
      UPDATE apps SET analytics_inject = 0
      """
    )
  end
end
```

In `App` schema add `field :analytics_inject, :boolean, default: false`.

Add `:analytics_inject` to `changeset/2` `cast/3` list. At the end of `changeset/2`, pipe `put_analytics_inject_default()`.

```elixir
def analytics_inject_changeset(app, attrs) do
  app
  |> cast(attrs, [:analytics_inject])
  |> validate_required([:analytics_inject])
end

defp put_analytics_inject_default(%Ecto.Changeset{} = changeset) do
  if Map.has_key?(changeset.params || %{}, "analytics_inject") do
    changeset
  else
    runtime = get_field(changeset, :runtime) || "phoenix"
    slug = get_field(changeset, :slug) || ""
    put_change(changeset, :analytics_inject, CleatDeploy.Analytics.default_inject?(runtime, slug))
  end
end
```

In `apps.ex`:

```elixir
def set_analytics_inject(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app, enabled)
    when tenant_id == tenant.id and is_boolean(enabled) do
  app
  |> App.analytics_inject_changeset(%{analytics_inject: enabled})
  |> Repo.update()
end

def set_analytics_inject(%Scope{}, %App{}, _), do: {:error, :unauthorized}
```

- [ ] **Step 4: Run tests**

Run: `mix test test/cleat_deploy/apps_test.exs`
Expected: PASS (existing tests plus the new describe).

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20261001220000_add_apps_analytics_inject.exs lib/cleat_deploy/apps/app.ex lib/cleat_deploy/apps.ex test/cleat_deploy/apps_test.exs
git commit -m "feat: persist apps.analytics_inject with runtime and LP defaults"
```

---

### Task 3: Hosts file payload

**Files:**
- Create: `lib/cleat_deploy/analytics/hosts.ex`
- Create: `test/cleat_deploy/analytics/hosts_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CleatDeploy.Analytics.HostsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Analytics.Hosts
  alias CleatDeploy.TenancyFixtures

  test "includes only inject-on apps on that server" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    other = TenancyFixtures.server_fixture(scope)

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "nfe-facil",
      host: "nfe.gestaobem.com",
      port: 4033,
      runtime: "phoenix"
    })

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "memo",
      host: "memo.sites.gestaobem.com",
      port: 4011,
      runtime: "static"
    })

    TenancyFixtures.app_fixture(scope, other, %{
      slug: "chatwoot",
      host: "chat.example.com",
      port: 3000,
      runtime: "rails"
    })

    payload = Hosts.payload(server.id)

    assert payload["nfe.gestaobem.com"] == %{
             "slug" => "nfe-facil",
             "upstream" => "127.0.0.1:4033"
           }

    refute Map.has_key?(payload, "memo.sites.gestaobem.com")
    refute Map.has_key?(payload, "chat.example.com")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cleat_deploy/analytics/hosts_test.exs`
Expected: FAIL — module missing.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule CleatDeploy.Analytics.Hosts do
  @moduledoc false
  import Ecto.Query
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Repo

  def payload(server_id) when is_integer(server_id) do
    from(a in App,
      where: a.server_id == ^server_id and a.analytics_inject == true,
      select: {a.host, a.slug, a.port}
    )
    |> Repo.all()
    |> Map.new(fn {host, slug, port} ->
      {host, %{"slug" => slug, "upstream" => "127.0.0.1:#{port}"}}
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cleat_deploy/analytics/hosts_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cleat_deploy/analytics/hosts.ex test/cleat_deploy/analytics/hosts_test.exs
git commit -m "feat: build analytics hosts.json from inject-on apps"
```

---

### Task 4: Caddy site strings

**Files:**
- Create: `lib/cleat_deploy/analytics/caddy.ex`
- Create: `test/cleat_deploy/analytics/caddy_test.exs`

Use a plain map (not a DB app) so this test can stay `async: true`:

```elixir
%{
  slug: "nfe-facil",
  host: "nfe.gestaobem.com",
  port: 4033,
  analytics_inject: true,
  idle_shutdown_enabled: false,
  runtime: "phoenix",
  indexable: true
}
```

- [ ] **Step 1: Write the failing tests** covering:
  1. Inject ON runtime: `handle /cleat/a.js`, `handle /cleat/a`, `@cleat_ws`, `Upgrade websocket`, `reverse_proxy 127.0.0.1:8799 127.0.0.1:4033`, `lb_policy first`, `fail_duration 10s`, `dial_timeout 250ms`.
  2. Inject OFF runtime: single `reverse_proxy 127.0.0.1:4033`, no `/cleat/a`, no `:8799`.
  3. Inject ON + wake: `/cleat/a` handle appears **before** `forward_auth`; websocket handle appears **after** `forward_auth`; `uri /wake?unit=phoenix_nfe&port=4033`.
  4. Inject ON static: public block proxies to `:8799` and `:4010`; `loopback_site/1` is `http://127.0.0.1:4010` with `bind 127.0.0.1`, `root *`, `file_server`.
  5. Inject OFF static: `file_server` on the public host, no reverse_proxy pair.

Pass `wake_unit` and `static_root` as opts so `caddy.ex` does not call `ServerProvision` private functions.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cleat_deploy/analytics/caddy_test.exs`
Expected: FAIL — module missing.

- [ ] **Step 3: Write `CleatDeploy.Analytics.Caddy`**

Public API:

```elixir
@spec public_site(map(), keyword()) :: String.t()
@spec loopback_site(map(), keyword()) :: String.t() | nil
```

`loopback_site/2` returns nil unless `runtime == "static"` and `analytics_inject`.

Public runtime ON (no wake) must contain this shape (port/slug interpolated):

```
nfe.gestaobem.com {
  # paas:app=nfe-facil
  log
  encode gzip
  handle /cleat/a.js {
    reverse_proxy 127.0.0.1:8799
  }
  handle /cleat/a {
    reverse_proxy 127.0.0.1:8799
  }
  @cleat_ws {
    header Connection *Upgrade*
    header Upgrade websocket
  }
  handle @cleat_ws {
    reverse_proxy 127.0.0.1:4033
  }
  reverse_proxy 127.0.0.1:8799 127.0.0.1:4033 {
    lb_policy first
    fail_duration 10s
    max_fails 1
    transport http {
      dial_timeout 250ms
    }
  }
}
```

When `opts[:wake_unit]` is a binary, insert `forward_auth 127.0.0.1:#{opts[:wake_port] || 3900} { uri /wake?unit=#{unit}&port=#{port} }` **after** the `/cleat/a*` handles and **before** `@cleat_ws`.

Inject OFF runtime stays:

```
host {
  # paas:app=slug
  log
  encode gzip
  reverse_proxy 127.0.0.1:port
}
```

Inject OFF static stays today’s `root *`, `try_files`, `file_server`, plus `opts[:robots_header]` (string, may be empty).

Use `Analytics.listen_port()` for 8799. Address: if `host` parses as IP, prefix `http://` (copy the logic in `ServerProvision.caddy_site_address/1` into a small `Caddy.address/1`).

- [ ] **Step 4: Run tests**

Run: `mix test test/cleat_deploy/analytics/caddy_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cleat_deploy/analytics/caddy.ex test/cleat_deploy/analytics/caddy_test.exs
git commit -m "feat: render Caddy sites for analytics inject and failover"
```

---

### Task 5: Wire Caddy + unit into provision

**Files:**
- Create: `lib/cleat_deploy/deploy/analytics_provision.ex`
- Modify: `lib/cleat_deploy/deploy/server_provision.ex` (`caddy_provision_script/3` uses `Analytics.Caddy`; append `AnalyticsProvision.install_script/1` when any inject-on app exists on the server **or** this app has inject on)
- Modify: `test/cleat_deploy/deploy/server_provision_test.exs` (phoenix default is now inject ON — assert `/cleat/a` and `:8799`; keep `reverse_proxy 127.0.0.1:4004` as the app upstream)
- Modify: `test/cleat_deploy/deploy/static_test.exs` only if a static fixture accidentally matches a product LP slug

- [ ] **Step 1: Write failing assertions** in `server_provision_test.exs` on the existing phoenix provision test:

```elixir
assert script =~ "handle /cleat/a.js"
assert script =~ "handle /cleat/a"
assert script =~ "127.0.0.1:8799"
assert script =~ "lb_policy first"
assert script =~ "cleat-analytics.service"
assert script =~ "/etc/cleat/analytics-hosts.json"
assert script =~ "/usr/local/lib/cleat/cleat_analytics.py"
```

Add a test that `analytics_inject: false` keeps a single `reverse_proxy 127.0.0.1:4004` and does **not** include `handle /cleat/a`.

Add a wake+inject test: `/cleat/a` byte index `<` `forward_auth` byte index `<` `@cleat_ws`.

Add a static inject-on test: fixture `runtime: "static", slug: "cleat", analytics_inject: true` includes `http://127.0.0.1:` and `bind 127.0.0.1`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cleat_deploy/deploy/server_provision_test.exs`
Expected: FAIL on the new assertions (phoenix script still the old single reverse_proxy).

- [ ] **Step 3: Implement**

`AnalyticsProvision.install_script(app)` (Wake-style heredoc):

1. `sudo mkdir -p /usr/local/lib/cleat /etc/cleat`
2. If `/etc/cleat/analytics.salt` missing: `dd if=/dev/urandom of=/tmp/cleat_analytics.salt bs=32 count=1` then `install -m 0640`.
3. Embed `File.read!(Application.app_dir(:cleat_deploy, "priv/analytics/cleat_analytics.py"))` between `<<'CLEAT_ANALYTICS_PY'` — until Task 6 the file can be a stub `print("ok")` **or** skip embedding until Task 6 and only write the unit file + hosts JSON. Prefer: hosts JSON + unit file now; python embed in Task 6 once the script exists. For this task, embed a 3-line placeholder `cleat_analytics.py` so the heredoc path exists:

```python
#!/usr/bin/env python3
# Placeholder replaced in Task 6.
raise SystemExit("cleat-analytics not implemented")
```

Create `priv/analytics/cleat_analytics.py` with that placeholder so `File.read!` works.

Unit file:

```
[Unit]
Description=Cleat analytics sidecar
After=network.target

[Service]
Type=simple
DynamicUser=yes
StateDirectory=cleat-analytics
Nice=10
CPUQuota=20%
MemoryMax=64M
Restart=always
RestartSec=2
Environment=CLEAT_ANALYTICS_HOSTS=/etc/cleat/analytics-hosts.json
Environment=CLEAT_ANALYTICS_SALT=/etc/cleat/analytics.salt
ExecStart=/usr/bin/python3 /usr/local/lib/cleat/cleat_analytics.py
AmbientCapabilities=
RestrictAddressFamilies=AF_INET AF_UNIX
IPAddressDeny=any
IPAddressAllow=127.0.0.1

[Install]
WantedBy=multi-user.target
```

`StateDirectory=cleat-analytics` makes the db default `/var/lib/cleat-analytics/analytics.db`. DynamicUser cannot read `/etc/cleat/analytics.salt` if mode 640 root:root — install salt as `0644` **or** `chmod 644` the hosts+salt (they are not app secrets beyond the HMAC key). Spec said 640; use `root:root` 0644 for salt and hosts so DynamicUser can read them. HMAC salt is not a password; 0644 on a locked-down VPS is acceptable. Document that in the unit comments.

Hosts JSON: `Jason.encode!(Hosts.payload(app.server_id))` inside `<<'CLEAT_ANALYTICS_HOSTS'`. Preload `app.server_id`. If `app` is a struct without `id` in some tests, `Hosts.payload/1` still works from `server_id`.

`install_script/1` is a no-op (empty string) when `app.analytics_inject` is false **and** `Hosts.payload(app.server_id)` is empty. When this app is off but another on the server is on, still refresh hosts JSON (so a toggle-off deploy removes the host). Always refresh hosts when `server_id` is present.

Wire `caddy_provision_script/3`:

- Compute `robots = robots_header(app)` (keep private helper).
- `wake_unit = if Wake.enabled?(app, manifest), do: config.systemd_unit`.
- `static_root = static_site_root(app)` when runtime is static.
- `block = Analytics.Caddy.public_site(app_map, wake_unit: wake_unit, wake_port: Wake.wake_port(), static_root: static_root, robots_header: robots)`.
- `origin = Analytics.Caddy.loopback_site(app_map, static_root: static_root, robots_header: robots)`.
- Existing `caddy_site_script(address, block, slug)` for the public site.
- If `origin`, a second `caddy_site_script("http://127.0.0.1:#{app.port}", origin, slug <> "-origin")`.
- Append `AnalyticsProvision.install_script(app)`.

Build `app_map` with slug/host/port/runtime/analytics_inject/idle_shutdown_enabled/indexable from the `%App{}`.

Custom `caddy_mode: "replace"`: do not wrap inject (same as wake — leave the custom file alone). `install_script` may still refresh the unit/hosts.

- [ ] **Step 4: Run tests**

Run: `mix test test/cleat_deploy/deploy/server_provision_test.exs test/cleat_deploy/deploy/static_test.exs`
Expected: PASS. Fix any phoenix test that assumed a lone `reverse_proxy 127.0.0.1:4004` line — the substring still matches as the websocket/app upstream.

- [ ] **Step 5: Commit**

```bash
git add priv/analytics/cleat_analytics.py lib/cleat_deploy/deploy/analytics_provision.ex lib/cleat_deploy/deploy/server_provision.ex test/cleat_deploy/deploy/server_provision_test.exs
git commit -m "feat: provision analytics Caddy hop, hosts file and systemd unit"
```

---

### Task 6: Sidecar Python — parse, hash, inject, store

**Files:**
- Replace: `priv/analytics/cleat_analytics.py`
- Create: `priv/analytics/test_cleat_analytics.py`
- Create: `test/cleat_deploy/analytics/sidecar_script_test.exs`

- [ ] **Step 1: Write `priv/analytics/test_cleat_analytics.py`** (unittest, no network):

```python
import hashlib
import hmac
import os
import tempfile
import unittest

import cleat_analytics as ca


class ParseTest(unittest.TestCase):
    def test_path_strips_query_and_slash(self):
        self.assertEqual(ca.normalize_path("https://nfe.gestaobem.com/login/?x=1"), "/login")
        self.assertEqual(ca.normalize_path("https://nfe.gestaobem.com"), "/")

    def test_utm(self):
        u, m, c = ca.utm_from("https://x.com/?utm_source=google&utm_medium=cpc&utm_campaign=a&foo=1")
        self.assertEqual((u, m, c), ("google", "cpc", "a"))

    def test_referrer_empty_when_same_host(self):
        self.assertEqual(ca.normalize_referrer("https://nfe.gestaobem.com/x", "nfe.gestaobem.com"), "")
        self.assertEqual(ca.normalize_referrer("https://google.com/q", "nfe.gestaobem.com"), "google.com")

    def test_visitor_hash_stable(self):
        salt = b"x" * 32
        a = ca.visitor_hash(salt, "1.1.1.1", "ua", "nfe.gestaobem.com", "2026-10-01")
        b = ca.visitor_hash(salt, "1.1.1.1", "ua", "nfe.gestaobem.com", "2026-10-01")
        c = ca.visitor_hash(salt, "1.1.1.1", "ua", "nfe.gestaobem.com", "2026-10-02")
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)
        self.assertEqual(len(a), 64)

    def test_inject_before_body(self):
        html = b"<html><body>hi</body></html>"
        out = ca.inject_html(html)
        self.assertIn(b'<script src="/cleat/a.js" defer></script></body>', out)

    def test_inject_skips_without_body(self):
        raw = b'{"ok":true}'
        self.assertEqual(ca.inject_html(raw), raw)

    def test_unknown_host_dropped(self):
        row = ca.parse_event(
            host="nope.example",
            payload=b'{"n":"pageview","u":"https://nope.example/","r":""}',
            hosts={},
            salt=b"x" * 32,
            ip="1.1.1.1",
            ua="ua",
            day="2026-10-01",
        )
        self.assertIsNone(row)

    def test_store_and_prune(self):
        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        try:
            store = ca.Store(path)
            store.insert_hit(ts=1, host="nfe.gestaobem.com", path="/", referrer="", utm_source="g", utm_medium="", utm_campaign="", visitor_hash="ab", name="pageview")
            store.rollup_and_prune(now_ts=1 + 8 * 86400)
            self.assertEqual(store.count_hits(), 0)
            self.assertGreater(store.count_daily_totals(), 0)
        finally:
            os.remove(path)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run unittest to verify it fails**

Run: `cd priv/analytics && python3 -m unittest test_cleat_analytics.py -v`
Expected: FAIL — `cleat_analytics` missing functions (`raise SystemExit` placeholder).

- [ ] **Step 3: Implement the library part of `cleat_analytics.py`**

Must include:

- `normalize_path`, `utm_from`, `normalize_referrer`, `visitor_hash`, `inject_html`, `parse_event` (returns dict or None; rejects `n != pageview`; max path 512; utm 128).
- `Store` with schema from the spec (`hits`, `daily_totals`, `daily_paths`, `daily_referrers`, `daily_utm`), WAL, `busy_timeout=5000`.
- `rollup_and_prune(now_ts)`: upsert daily aggregates for each UTC date present in hits; delete hits older than 7 days; delete rollups older than 90 days; if file size `> 200 * 1024 * 1024`, delete oldest raw days until `< 150 MiB`.
- HMAC message: `f"{ip}\n{ua}\n{host}\n{day}".encode()`.

Keep HTTP server for Task 7; this task can live as importable functions + Store only.

- [ ] **Step 4: Run unittest**

Run: `cd priv/analytics && python3 -m unittest test_cleat_analytics.py -v`
Expected: PASS.

Add Mix wrapper so CI runs it:

```elixir
defmodule CleatDeploy.Analytics.SidecarScriptTest do
  use ExUnit.Case, async: true

  test "python unittests" do
    dir = Application.app_dir(:cleat_deploy, "priv/analytics")
    {output, status} = System.cmd("python3", ["-m", "unittest", "test_cleat_analytics.py", "-v"], cd: dir, stderr_to_stdout: true)
    assert status == 0, output
  end
end
```

Run: `mix test test/cleat_deploy/analytics/sidecar_script_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/analytics/cleat_analytics.py priv/analytics/test_cleat_analytics.py test/cleat_deploy/analytics/sidecar_script_test.exs
git commit -m "feat: sidecar parse, HMAC uniques, HTML inject and rollup store"
```

---

### Task 7: Sidecar HTTP — collect, script, health, summaries

**Files:**
- Modify: `priv/analytics/cleat_analytics.py` (add `ThreadingHTTPServer` bound to `127.0.0.1:8799`)
- Modify: `priv/analytics/test_cleat_analytics.py` (HTTP cases)

- [ ] **Step 1: Write failing HTTP tests** using a background thread and `urllib.request`:

1. `GET /healthz` → 200.
2. `GET /cleat/a.js` → 200, `application/javascript`, contains `sendBeacon`.
3. `POST /cleat/a` with `Host: nfe.gestaobem.com` and JSON pageview → 204, `count_hits()==1`, no IP in sqlite (`SELECT sql FROM sqlite_master` / row keys).
4. Unknown host → 204, no row.
5. `GET /v1/visited?range=24h` → list with slug/pageviews.
6. `GET /v1/apps/nfe.gestaobem.com?range=24h` → keys `pageviews`, `uniques`, `series`, `paths`, `referrers`, `utm`.
7. Oversized body (>8 KiB) → 204, no row.

Hosts file for the test: temp JSON `{"nfe.gestaobem.com":{"slug":"nfe-facil","upstream":"127.0.0.1:9"}}`. Salt temp file. DB temp file. Env vars `CLEAT_ANALYTICS_*`. Pick a free port via `CLEAT_ANALYTICS_PORT`.

- [ ] **Step 2: Run unittest to verify HTTP tests fail**

Run: `cd priv/analytics && python3 -m unittest test_cleat_analytics.py -v`
Expected: FAIL on HTTP tests.

- [ ] **Step 3: Implement the server**

- Bind `127.0.0.1` only. Port from `CLEAT_ANALYTICS_PORT` or 8799.
- `ThreadingMixIn`.
- `POST /cleat/a` always 204.
- `GET /cleat/a.js` cache 3600, body:

```javascript
(()=>{try{var b=new Blob([JSON.stringify({n:"pageview",u:location.href,r:document.referrer||""})],{type:"text/plain"});navigator.sendBeacon("/cleat/a",b);}catch(e){}})();
```

- Client IP: first `X-Forwarded-For` token else `self.client_address[0]`.
- UA from `User-Agent` header (used only in HMAC, not stored).
- `/v1/visited` and `/v1/apps/{host}` as spec. 24h/7d from `hits`; 90d from rollups. Uniques: `count(distinct visitor_hash)` on raw; 90d `sum(unique_visitors)`.
- Reload hosts JSON every request (or mtime) so provision updates apply without restart.
- Hourly timer thread calls `rollup_and_prune`.
- Proxy of HTML is Task 8. For unknown paths that are not `/cleat/*` or `/v1/*` or `/healthz`, this task may return 502.

- [ ] **Step 4: Run unittest + mix wrapper**

Run: `cd priv/analytics && python3 -m unittest test_cleat_analytics.py -v && cd ../../ && mix test test/cleat_deploy/analytics/sidecar_script_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/analytics/cleat_analytics.py priv/analytics/test_cleat_analytics.py
git commit -m "feat: sidecar HTTP collect, a.js and summary API"
```

---

### Task 8: Sidecar HTML reverse proxy

**Files:**
- Modify: `priv/analytics/cleat_analytics.py`
- Modify: `priv/analytics/test_cleat_analytics.py`

- [ ] **Step 1: Write a failing test** that starts a tiny upstream `HTTPServer` serving `<html><body>hi</body></html>` with `Content-Type: text/html`, then `GET http://127.0.0.1:$PORT/login` with `Host: nfe.gestaobem.com` through the sidecar, and asserts the script tag is present.

Second test: upstream `application/json` body is unchanged.

Third test: upstream down → 502.

- [ ] **Step 2: Run unittest to verify fail**

Expected: FAIL (502/404 on `/login`).

- [ ] **Step 3: Implement proxy**

- Look up `Host` in hosts file → `upstream`.
- Buffer only when `Content-Type` starts with `text/html`, max 1 MiB; `inject_html`.
- Stream other content-types.
- Strip hop-by-hop headers (`Connection`, `Transfer-Encoding`, `Keep-Alive`, `Proxy-Authenticate`, `TE`, `Trailer`, `Upgrade`).
- Do not implement WebSocket (Caddy never sends Upgrade here).

- [ ] **Step 4: Run unittest + mix wrapper** — PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/analytics/cleat_analytics.py priv/analytics/test_cleat_analytics.py
git commit -m "feat: sidecar injects analytics script into proxied HTML"
```

---

### Task 9: Panel summary client

**Files:**
- Create: `lib/cleat_deploy/analytics/summary.ex`
- Create: `lib/cleat_deploy/analytics/summary_http.ex`
- Create: `lib/cleat_deploy/analytics/summary_stub.ex`
- Create: `test/cleat_deploy/analytics/summary_test.exs`
- Modify: `config/config.exs` (`:analytics_client, CleatDeploy.Analytics.SummaryHttp`)
- Modify: `config/test.exs` (`:analytics_client, CleatDeploy.Analytics.SummaryStub`)

- [ ] **Step 1: Write failing tests**

```elixir
test "visited uses the configured client" do
  Application.put_env(:cleat_deploy, :analytics_visited_stub, [
    %{host: "nfe.gestaobem.com", slug: "nfe-facil", pageviews: 42, id: 1, name: "NFe"}
  ])
  assert {:ok, [%{slug: "nfe-facil", pageviews: 42}]} =
           CleatDeploy.Analytics.Summary.visited(%{host_ip: "203.0.113.9"})
after
  Application.delete_env(:cleat_deploy, :analytics_visited_stub)
end
```

Stub reads that env (default `[]`). `:error` tuple on the HTTP module is tested with a Bypass-less fake: `SummaryHttp` is not called in test env.

Also test `Summary.app/3` returns the stub map.

- [ ] **Step 2: Run — FAIL missing module.**

- [ ] **Step 3: Implement**

`Summary.visited(server)` and `Summary.app(server, host, range)` delegate to `Application.fetch_env!(:cleat_deploy, :analytics_client)`.

`SummaryStub.visited/1` returns `{:ok, Application.get_env(:cleat_deploy, :analytics_visited_stub, [])}`.

`SummaryStub.app/3` returns `{:ok, Application.get_env(:cleat_deploy, :analytics_app_stub, %{pageviews: 0, uniques: 0, series: [], paths: [], referrers: [], utm: [], stale: false})}`.

`SummaryHttp.visited(server)`:

- If `HostStats.local?(server)`, `Req.get("http://127.0.0.1:#{port}/v1/visited", params: [range: "24h"], receive_timeout: 3_000)` and map JSON.
- Else SSH: reuse `CleatDeploy.Deploy.Ssh` the same way runtime logs do — `curl --max-time 3 -sS http://127.0.0.1:8799/v1/visited?range=24h`. On error `{:error, reason}`.

Join with `Apps` on host to attach `id` and `name` for bars (do this in `Insights`, not in the sidecar). Sidecar JSON is `{host, slug, pageviews}` only.

ETS cache: `:ets` table `CleatDeploy.Analytics.Summary` created in `Summary.init_cache/0` called from `CleatDeploy.Application` children or `Summary.visited` lazy `create` with `[:named_table, :public]`. Key `{server_id, :visited}`; TTL 60s using `System.monotonic_time(:millisecond)`. On HTTP error, return last cache + `stale: true` if present, else `{:ok, []}`.

Keep cache logic in `Summary` wrapping the client so Stub tests can ignore it (bypass cache when client is Stub): `if client == SummaryStub, do: client.visited(server)`.

- [ ] **Step 4: mix test the new file — PASS.**

- [ ] **Step 5: Commit**

```bash
git add lib/cleat_deploy/analytics/summary.ex lib/cleat_deploy/analytics/summary_http.ex lib/cleat_deploy/analytics/summary_stub.ex test/cleat_deploy/analytics/summary_test.exs config/config.exs config/test.exs lib/cleat_deploy/application.ex
git commit -m "feat: read analytics summaries over loopback or SSH"
```

Only add `application.ex` if you start the ETS table there; lazy create is enough (then do not touch `application.ex`).

---

### Task 10: Dashboard Visited chart

**Files:**
- Modify: `lib/cleat_deploy/servers/insights.ex` (`top_visited` list of `%{id, name, slug, pageviews}`)
- Modify: `lib/cleat_deploy_web/components/paas_components/bars.ex` (add `visited_bars/1`)
- Modify: `lib/cleat_deploy_web/live/dashboard_live.ex` (render next to access bars)
- Modify: `test/cleat_deploy_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Write failing dashboard test** (mirror the access-log test around line 400):

Stub:

```elixir
Application.put_env(:cleat_deploy, :analytics_visited_stub, [
  %{host: "nfe.gestaobem.com", slug: "nfe-facil", pageviews: 10}
])
```

Create the NFe app as the access test does. `live(conn, ~p"/")` then:

```elixir
assert has_element?(view, "#chart-visited", "NFe Fácil")
assert has_element?(view, "#chart-access")
refute has_element?(view, "#chart-visited", "No pageviews yet")
```

Keep the existing access test passing (empty visited stub → empty state copy **No pageviews yet**).

- [ ] **Step 2: Run dashboard_live_test — FAIL missing `#chart-visited`.**

- [ ] **Step 3: Implement**

`Insights.snapshot/2`: when `metrics: true`, call `Summary.visited(server)` for `active_server(scope)` only. Join rows to tenant apps by `slug` or `host`; drop hosts the tenant does not own. Put `top_visited` in the snapshot map (always a list; `visited_stale` boolean).

`visited_bars/1` copies `access_bars/1` with:

- title `Most visited · 24h`
- subtitle `Pageviews on this server`
- empty `No pageviews yet`
- value `row.pageviews`
- tooltip `{pageviews} pageviews`
- `navigate={~p"/apps/#{row.id}?tab=analytics"}`

Dashboard:

```elixir
<.visited_bars id="chart-visited" apps={@insights.top_visited} stale={@insights.visited_stale} />
<.access_bars id="chart-access" apps={@insights.top_apps} />
```

When `stale`, title suffix ` · stale` (spec copy “Visited · stale”).

First paint (`metrics: false`) uses `top_visited: []`, `visited_stale: false` like `top_apps`.

- [ ] **Step 4: `mix test test/cleat_deploy_web/live/dashboard_live_test.exs` — PASS.**

- [ ] **Step 5: Commit**

```bash
git add lib/cleat_deploy/servers/insights.ex lib/cleat_deploy_web/components/paas_components/bars.ex lib/cleat_deploy_web/live/dashboard_live.ex test/cleat_deploy_web/live/dashboard_live_test.exs
git commit -m "feat: show most visited pageviews on the dashboard"
```

---

### Task 11: App Analytics tab and toggle

**Files:**
- Modify: `lib/cleat_deploy_web/live/app_live/layout/tabs.ex` (`detail_tabs` includes `:analytics` after `:logs`; `parse_detail_tab` accepts `"analytics"`)
- Create: `lib/cleat_deploy_web/live/app_live/show/analytics_tab.ex`
- Create: `lib/cleat_deploy_web/live/app_live/show/analytics.ex`
- Modify: `lib/cleat_deploy_web/live/app_live/show.ex` (assign summary, route events)
- Modify: `lib/cleat_deploy_web/live/app_live/show/tabs.ex` (render the tab)
- Create: `test/cleat_deploy_web/live/app_live/analytics_test.exs`

- [ ] **Step 1: Write failing LiveView tests** (`async: false`, ConnCase like `app_live_test.exs`):

```elixir
test "analytics tab shows off state for static", %{conn: conn, scope: scope, server: server} do
  app = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", slug: "memo-z"})
  {:ok, view, html} = live(conn, ~p"/apps/#{app.id}?tab=analytics")
  assert html =~ "Not measuring"
  assert has_element?(view, "#analytics-inject-toggle")
end

test "analytics tab shows stubbed totals when on", %{conn: conn, scope: scope, server: server} do
  app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix", slug: "nfe-z"})
  Application.put_env(:cleat_deploy, :analytics_app_stub, %{
    pageviews: 12,
    uniques: 4,
    series: [],
    paths: [%{path: "/login", pageviews: 8}],
    referrers: [%{referrer: "google.com", pageviews: 3}],
    utm: [%{source: "google", medium: "cpc", campaign: "a", pageviews: 2}],
    stale: false
  })
  {:ok, view, html} = live(conn, ~p"/apps/#{app.id}?tab=analytics")
  assert html =~ "12"
  assert html =~ "/login"
  assert html =~ "hash per UTC day"
  assert has_element?(view, "#analytics-inject-toggle")
after
  Application.delete_env(:cleat_deploy, :analytics_app_stub)
end

test "toggle persists analytics_inject", %{conn: conn, scope: scope, server: server} do
  app = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", slug: "memo-t"})
  {:ok, view, _} = live(conn, ~p"/apps/#{app.id}?tab=analytics")
  view |> element("#analytics-inject-toggle") |> render_click()
  assert Apps.get_app!(scope, app.id).analytics_inject
end
```

- [ ] **Step 2: Run — FAIL tab parses as `:environment` / missing toggle.**

- [ ] **Step 3: Implement**

`detail_tabs/2`: `[:deployments, :logs, :analytics] ++ optional domains ++ [:environment, ...]`.

`parse_detail_tab("analytics")` → `:analytics`.

`AnalyticsTab.render/1`: switch, range links `?tab=analytics&range=24h|7d|90d` (default 24h), metrics, tables. Off copy: **Not measuring**. On: pageviews, uniques + subtitle **hash per UTC day**, paths, referrers, UTM. Note: **Applies on the next deploy.**

`Show.Analytics.handle_event("toggle_analytics_inject", _, socket)` calls `Apps.set_analytics_inject/3`, assigns the updated app, flash “Analytics inject on. Deploy to apply Caddy.”

`handle_params`: when tab is `:analytics`, `assign(:analytics_range, params["range"] || "24h")` and `assign(:analytics_summary, summary_or_nil)`.

`show.ex`: `@analytics_events ~w(toggle_analytics_inject)` before the catch-all.

Do not load summary until the analytics tab is open.

- [ ] **Step 4: Run**

Run: `mix test test/cleat_deploy_web/live/app_live/analytics_test.exs test/cleat_deploy_web/module_size_test.exs`
Expected: PASS. If `tabs.ex` or `show.ex` exceeds 400 lines, extract, do not raise the guard.

- [ ] **Step 5: Commit**

```bash
git add lib/cleat_deploy_web/live/app_live/layout/tabs.ex lib/cleat_deploy_web/live/app_live/show.ex lib/cleat_deploy_web/live/app_live/show/tabs.ex lib/cleat_deploy_web/live/app_live/show/analytics.ex lib/cleat_deploy_web/live/app_live/show/analytics_tab.ex test/cleat_deploy_web/live/app_live/analytics_test.exs
git commit -m "feat: add app Analytics tab with inject toggle"
```

---

### Task 12: Precommit gate

- [ ] **Step 1:** Run `mix precommit` from `cleat-web`.
Expected: compile `--warnings-as-errors`, format, credo, tests green including python unittests via the Mix wrapper.

- [ ] **Step 2:** `mix format` anything the check flags.

- [ ] **Step 3:** Manual smoke (not in CI): on a local Caddyfile snippet, `caddy validate --adapter caddyfile` if `caddy` is installed; if not, skip and rely on the server-side validate already in `provision_script`.

- [ ] **Step 4:** Commit only if format/credo produced diffs.

```bash
git add -u
git commit -m "chore: format analytics spine"
```

---

## Self-review (spec coverage)

| Spec item | Task |
|-----------|------|
| Visited + Requested dashboard | 10 |
| Analytics tab pageviews/uniques/paths/referrers/UTM 24h 7d 90d | 11 |
| Caddy inject, no app repo changes | 4, 5, 8 |
| Sidecar SQLite 7d raw + 90d rollup, not cleat.db | 6, 7 |
| Site up if unit down (`lb_policy first`, dial 250ms) | 4 |
| Runtime default ON, static OFF, LP slugs ON | 1, 2 |
| HMAC daily hash, no cookie, no stored IP | 6, 7 |
| `/cleat/a` + `/cleat/a.js` only | 4, 7 |
| WebSocket bypass | 4 |
| Wake: collect before `forward_auth` | 4, 5 |
| Static loopback file_server | 4, 5 |
| Hosts JSON from inject-on apps | 3, 5 |
| systemd Nice/CPUQuota/DynamicUser | 5 |
| Summary local HTTP / remote SSH, 60s cache, stale | 9, 10 |
| AccessCounts unchanged | (no task touches it) |
| Python unittests on `mix test` | 6 |
| Toggle + next deploy | 11, 5 |
| Unique label “hash per UTC day” | 11 |

Out of scope (do not implement): `cleat.track()`, funnels, geo, cookie, SPA history, status on the Analytics tab, xcaddy, CLI toggle, merging all servers on Visited.
