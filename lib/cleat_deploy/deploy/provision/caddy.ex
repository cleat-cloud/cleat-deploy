defmodule CleatDeploy.Deploy.Provision.Caddy do
  @moduledoc false

  alias CleatDeploy.Analytics
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AnalyticsProvision
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Wake
  alias CleatDeploy.Deploy.Provision.Shell
  alias CleatDeploy.Servers.AccessCounts

  def provision_script(
        %App{} = app,
        _config,
        %AppManifest{caddy_mode: "replace", caddyfile: path}
      )
      when is_binary(path) and path != "" do
    """
    #{ensure_script()}

    log "Installing custom Caddyfile (#{path})"
    if [[ ! -f "$BUILD_DIR/#{path}" ]]; then
      echo "Custom Caddyfile not found at $BUILD_DIR/#{path}" >&2
      exit 1
    fi
    sudo cp "$BUILD_DIR/#{path}" /etc/caddy/Caddyfile
    #{AnalyticsProvision.install_script(app)}
    """
  end

  # Site bodies come from Analytics.Caddy. Custom `caddy_mode: replace` above
  # is not wrapped (same as wake). Cache-Control / X-Robots-Tag live on the
  # static origin (inject-off public host, or inject-on loopback).
  def provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    address = Analytics.Caddy.address(app.host)
    robots = robots_header(app)
    wake? = Wake.enabled?(app, manifest)
    wake_unit = if wake?, do: config.systemd_unit
    app_map = app_map(app)
    static_root = if app.runtime == "static", do: static_site_root(app)

    site_opts = [wake_unit: wake_unit, wake_port: Wake.wake_port(), robots_header: robots]

    site_opts =
      if static_root, do: Keyword.put(site_opts, :static_root, static_root), else: site_opts

    # Marker must match awk app= slug-origin so a port change (or inject-off)
    # strips the previous loopback site without touching the public block.
    origin =
      if static_root do
        Analytics.Caddy.loopback_site(%{app_map | slug: "#{app.slug}-origin"},
          static_root: static_root,
          robots_header: robots
        )
      end

    block = Analytics.Caddy.public_site(app_map, site_opts)

    bodies =
      case origin do
        origin when is_binary(origin) and origin != "" ->
          String.trim_trailing(block) <> "\n" <> String.trim_trailing(origin)

        _ ->
          block
      end

    # Always strip the loopback origin: a former static inject-on site (or a
    # toggle-off) would otherwise keep file_server bound on the app port.
    public =
      site_script(address, bodies, app.slug, [
        {"http://127.0.0.1:#{app.port}", app.slug <> "-origin"}
      ])

    arm = if wake?, do: Wake.arm_script(config.systemd_unit), else: ""

    """
    #{public}
    #{arm}
    #{AnalyticsProvision.install_script(app)}
    """
  end

  # Rewrites the managed site block for `address` on every deploy. The upstream
  # (app port) can change after creation, so appending only when the address is
  # new would leave Caddy proxying to the old port. Emitted as a shell function
  # so the caller picks the body and this stays the single implementation of the
  # strip-and-append dance.
  @doc false
  def strip_awk do
    """
    function hosts_of(line,   s, n, i, a, m, j, b) {
      s = line
      sub(/[ \\t]*{[ \\t]*$/, "", s)
      n = split(s, a, ",")
      m = split(site, b, ",")
      for (j = 1; j <= m; j++) {
        gsub(/^[ \\t]+|[ \\t]+$/, "", b[j])
      }
      for (i = 1; i <= n; i++) {
        gsub(/^[ \\t]+|[ \\t]+$/, "", a[i])
        for (j = 1; j <= m; j++) {
          if (a[i] != "" && a[i] == b[j]) return 1
        }
      }
      return 0
    }
    function braces(s,   n, i, c) {
      n = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "{") n++
        if (c == "}") n--
      }
      return n
    }
    function keep_buf(   i) {
      for (i = 1; i <= nbuf; i++) print buf[i]
      nbuf = 0
    }
    depth == 0 && /{/ {
      in_site = 1
      nbuf = 0
      drop = hosts_of($0)
      buf[++nbuf] = $0
      depth += braces($0)
      if (depth <= 0) {
        if (!drop) print $0
        in_site = 0
        nbuf = 0
      }
      next
    }
    in_site {
      buf[++nbuf] = $0
      if (app != "" && $0 ~ ("^[ \\t]*# paas:app=" app "[ \\t]*$")) drop = 1
      depth += braces($0)
      if (depth <= 0) {
        if (!drop) keep_buf()
        in_site = 0
        nbuf = 0
      }
      next
    }
    { print }
    """
    |> String.trim()
  end

  defp app_map(%App{} = app) do
    %{
      slug: app.slug,
      host: app.host,
      port: app.port,
      runtime: app.runtime,
      analytics_inject: app.analytics_inject,
      idle_shutdown_enabled: app.idle_shutdown_enabled,
      indexable: app.indexable
    }
  end

  # A VM created from the panel has nothing installed: the ops bootstrap scripts
  # put Caddy there, but the panel has to be able to provision a fresh server on
  # its own. Idempotent (a `command -v` check), so it can be inlined wherever a
  # Caddyfile is written.
  defp ensure_script do
    """
    if ! command -v caddy >/dev/null 2>&1; then
      log "Installing Caddy"
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
    fi

    sudo systemctl enable caddy > /dev/null 2>&1 || true
    sudo systemctl is-active --quiet caddy || sudo systemctl start caddy
    """
    |> String.trim()
  end

  defp site_script(address, caddy_site, slug, extra_strips) do
    extra_awk =
      Enum.map_join(extra_strips, "\n", fn {site, app} ->
        """
        sudo awk -v site=#{Shell.shell_escape(site)} -v app=#{Shell.shell_escape(app)} '
          #{strip_awk()}
        ' "$TMPFILE" > "$TMPFILE.next"
        mv "$TMPFILE.next" "$TMPFILE"
        """
      end)

    """
    #{ensure_script()}

    write_caddy_site() {
      CADDYFILE="/etc/caddy/Caddyfile"
      sudo touch "$CADDYFILE"
      TMPFILE="$(mktemp)"
      sudo awk -v site=#{Shell.shell_escape(address)} -v app=#{Shell.shell_escape(slug)} '
        #{strip_awk()}
      ' "$CADDYFILE" > "$TMPFILE"
      #{extra_awk}
      cat >> "$TMPFILE"
      if command -v python3 >/dev/null 2>&1; then
        python3 - "$TMPFILE" <<'PAAS_CADDY_ACCESS'
    #{AccessCounts.ensure_python()}
    PAAS_CADDY_ACCESS
      fi
      # Caddy 2.11 FileWriter opens the log during validate. The deploy user
      # cannot create /var/log/caddy/access.log (dir is caddy:caddy 0755).
      sudo mkdir -p /var/log/caddy
      sudo touch /var/log/caddy/access.log
      if id caddy >/dev/null 2>&1; then
        sudo chown caddy:caddy /var/log/caddy /var/log/caddy/access.log || true
      fi
      if ! sudo caddy validate --adapter caddyfile --config "$TMPFILE" >"$TMPFILE.validate" 2>&1; then
        echo "Caddyfile invalid after writing site #{address}; keeping previous file" >&2
        cat "$TMPFILE.validate" >&2
        rm -f "$TMPFILE" "$TMPFILE.validate"
        exit 1
      fi
      sudo install -m 0644 -o root -g root "$TMPFILE" "$CADDYFILE"
      rm -f "$TMPFILE" "$TMPFILE.validate"
      log "Writing Caddy site #{address}"
    }

    write_caddy_site <<'PAAS_CADDY_SITE'
    #{String.trim_trailing(caddy_site)}
    PAAS_CADDY_SITE
    """
  end

  defp static_site_root(%App{} = app) do
    app
    |> App.deploy_config()
    |> Map.fetch!(:release_path)
    |> Kernel.<>("/current")
  end

  defp robots_header(%App{indexable: true}), do: ""
  defp robots_header(_app), do: ~s|header X-Robots-Tag "noindex, nofollow"|
end
