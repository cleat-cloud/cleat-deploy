defmodule CleatDeploy.Deploy.ServerProvision do
  @moduledoc false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest

  @doc false
  def provision_script(%App{} = app, config, %AppManifest{runtime: "golang"} = manifest) do
    golang_provision_script(app, config, manifest)
  end

  def provision_script(%App{} = app, config, %AppManifest{runtime: "static"} = manifest) do
    static_provision_script(app, config, manifest)
  end

  def provision_script(%App{} = app, config, %AppManifest{runtime: "node"} = manifest) do
    node_provision_script(app, config, manifest)
  end

  def provision_script(%App{} = app, config, %AppManifest{runtime: "rails"} = manifest) do
    rails_provision_script(app, config, manifest)
  end

  def provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    data_dir = data_dir_for(manifest, config)
    env_dir = Path.dirname(config.env_file)
    memory_max = manifest.memory_max_mb || 400

    unit = """
    [Unit]
    Description=#{escape_unit_description(app.name)}
    After=network.target

    [Service]
    Type=exec
    User=root
    Group=root
    WorkingDirectory=#{config.release_path}/current
    EnvironmentFile=#{config.env_file}
    Environment=CLEAT_DATA_DIR=#{data_dir}
    ExecStart=#{config.release_path}/current/bin/#{config.release_name} start
    Restart=always
    RestartSec=5
    MemoryMax=#{memory_max}M
    LimitNOFILE=65535

    [Install]
    WantedBy=multi-user.target
    """

    caddy_script = caddy_provision_script(app, manifest)

    """
    log "Provisioning host #{app.host} on port #{app.port}"
    sudo mkdir -p #{shell_escape(env_dir)} #{shell_escape(data_dir)}

    sudo tee /etc/systemd/system/#{config.systemd_unit}.service > /dev/null <<'PAAS_SYSTEMD_UNIT'
    #{String.trim_trailing(unit)}
    PAAS_SYSTEMD_UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable #{config.systemd_unit}

    #{caddy_script}
    """
  end

  defp golang_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    data_dir = data_dir_for(manifest, config)
    env_dir = Path.dirname(config.env_file)
    ssh_user = Map.get(config, :ssh_user, "ubuntu")
    memory_max = manifest.memory_max_mb || 256
    binaries = manifest.binaries || ["server"]

    units =
      Enum.map_join(binaries, "\n", fn bin ->
        unit_name = golang_unit_name(config.systemd_unit, bin)
        exec = "#{config.release_path}/current/bin/#{bin}"
        description = golang_unit_description(app.name, bin)

        unit = """
        [Unit]
        Description=#{escape_unit_description(description)}
        After=network.target

        [Service]
        Type=exec
        User=#{ssh_user}
        Group=#{ssh_user}
        WorkingDirectory=#{config.release_path}/current
        EnvironmentFile=#{config.env_file}
        Environment=CLEAT_DATA_DIR=#{data_dir}
        ExecStart=#{exec}
        Restart=always
        RestartSec=5
        MemoryMax=#{memory_max}M
        LimitNOFILE=65535
        NoNewPrivileges=true
        PrivateTmp=true

        [Install]
        WantedBy=multi-user.target
        """

        """
        sudo tee /etc/systemd/system/#{unit_name}.service > /dev/null <<'PAAS_SYSTEMD_UNIT'
        #{String.trim_trailing(unit)}
        PAAS_SYSTEMD_UNIT

        sudo systemctl enable #{unit_name}
        """
      end)

    caddy_script = caddy_provision_script(app, manifest)

    """
    log "Provisioning host #{app.host} on port #{app.port}"
    sudo mkdir -p #{shell_escape(env_dir)} #{shell_escape(data_dir)}
    id #{ssh_user} >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash #{ssh_user}
    sudo chown -R #{ssh_user}:#{ssh_user} #{shell_escape(config.release_path)}

    #{units}
    sudo systemctl daemon-reload

    #{caddy_script}
    """
  end

  defp golang_unit_name(systemd_unit, "server"), do: systemd_unit
  defp golang_unit_name(systemd_unit, bin), do: "#{systemd_unit}-#{bin}"

  defp golang_unit_description(name, "server"), do: "#{name} (Cais)"
  defp golang_unit_description(name, "worker"), do: "#{name} worker (Cais jobs)"
  defp golang_unit_description(name, bin), do: "#{name} #{bin}"

  defp static_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    caddy_script = caddy_provision_script(app, manifest)

    """
    log "Provisioning static site #{app.host}"
    sudo mkdir -p #{shell_escape(config.release_path)}

    #{caddy_script}
    """
  end

  defp node_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    service_provision_script(app, config, manifest, ["Environment=NODE_ENV=production"], "Node")
  end

  defp rails_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    service_provision_script(app, config, manifest, ["Environment=RAILS_ENV=production"], "Rails")
  end

  # Shared systemd unit for long-lived app servers that start through a
  # generated `current/start.sh` (Node, Rails).
  defp service_provision_script(%App{} = app, config, %AppManifest{} = manifest, env_lines, label) do
    data_dir = data_dir_for(manifest, config)
    env_dir = Path.dirname(config.env_file)
    memory_max = manifest.memory_max_mb || 400
    extra_env = Enum.join(env_lines, "\n    ")

    unit = """
    [Unit]
    Description=#{escape_unit_description(app.name)}
    After=network.target

    [Service]
    Type=exec
    User=root
    Group=root
    WorkingDirectory=#{config.release_path}/current
    EnvironmentFile=#{config.env_file}
    Environment=CLEAT_DATA_DIR=#{data_dir}
    #{extra_env}
    Environment=HOST=127.0.0.1
    Environment=PORT=#{app.port}
    ExecStart=/bin/bash #{config.release_path}/current/start.sh
    Restart=always
    RestartSec=5
    MemoryMax=#{memory_max}M
    LimitNOFILE=65535

    [Install]
    WantedBy=multi-user.target
    """

    caddy_script = caddy_provision_script(app, manifest)

    """
    log "Provisioning #{label} host #{app.host} on port #{app.port}"
    sudo mkdir -p #{shell_escape(env_dir)} #{shell_escape(data_dir)}
    sudo touch #{shell_escape(config.env_file)}
    sudo chmod 600 #{shell_escape(config.env_file)}

    sudo tee /etc/systemd/system/#{config.systemd_unit}.service > /dev/null <<'PAAS_SYSTEMD_UNIT'
    #{String.trim_trailing(unit)}
    PAAS_SYSTEMD_UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable #{config.systemd_unit}

    #{caddy_script}
    """
  end

  @doc """
  Generic launcher written to `current/start.sh` for app servers whose start
  command lives in `current/start.cmd`. Sources the systemd-provided env
  (`PORT`, `HOST`, `NODE_ENV`/`RAILS_ENV`) and execs the command.
  """
  def start_script do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    cd "$(dirname "$0")"
    exec bash -c "$(cat "$(dirname "$0")/start.cmd")"
    """
  end

  defp caddy_provision_script(%App{}, %AppManifest{caddy_mode: "replace", caddyfile: path})
       when is_binary(path) and path != "" do
    """
    log "Installing custom Caddyfile (#{path})"
    if [[ ! -f "$BUILD_DIR/#{path}" ]]; then
      echo "Custom Caddyfile not found at $BUILD_DIR/#{path}" >&2
      exit 1
    fi
    sudo cp "$BUILD_DIR/#{path}" /etc/caddy/Caddyfile
    """
  end

  defp caddy_provision_script(%App{} = app, %AppManifest{runtime: "static"}) do
    address = caddy_site_address(app)

    caddy_site = """

    #{address} {
      encode gzip
      root * #{static_site_root(app)}
      try_files {path} /index.html
      file_server
    }
    """

    append_caddy_site(address, caddy_site)
  end

  defp caddy_provision_script(%App{} = app, %AppManifest{}) do
    address = caddy_site_address(app)

    caddy_site = """

    #{address} {
      encode gzip
      reverse_proxy 127.0.0.1:#{app.port}
    }
    """

    append_caddy_site(address, caddy_site)
  end

  # Rewrites the managed site block for `address` on every deploy. The upstream
  # (app port) can change after creation, so appending only when the address is
  # new would leave Caddy proxying to the old port.
  defp append_caddy_site(address, caddy_site) do
    """
    CADDYFILE="/etc/caddy/Caddyfile"
    sudo touch "$CADDYFILE"
    TMPFILE="$(mktemp)"
    sudo awk -v site=#{shell_escape(address)} '
      $0 == site " {" { inside = 1; next }
      inside && $0 == "}" { inside = 0; next }
      inside { next }
      { print }
    ' "$CADDYFILE" > "$TMPFILE"
    cat >> "$TMPFILE" <<'PAAS_CADDY_SITE'
    #{String.trim_leading(caddy_site)}
    PAAS_CADDY_SITE
    sudo install -m 0644 -o root -g root "$TMPFILE" "$CADDYFILE"
    rm -f "$TMPFILE"
    log "Writing Caddy site #{address}"
    """
  end

  # Caddy would force HTTPS for a bare IP and have no certificate to serve it,
  # so an IP host gets an explicit http:// site (port 80, no redirect).
  defp caddy_site_address(%App{host: host}) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} -> "http://#{host}"
      _ -> host
    end
  end

  defp static_site_root(%App{} = app) do
    app
    |> App.deploy_config()
    |> Map.fetch!(:release_path)
    |> Kernel.<>("/current")
  end

  @doc false
  def migrate_script(config) do
    release_bin = "#{config.release_path}/current/bin/#{config.release_name}"
    otp_app = config.release_name

    """
    if [[ -f #{config.env_file} ]]; then
      if [[ -x #{config.release_path}/current/bin/migrate ]]; then
        log "Running migrations (bin/migrate)"
        sudo bash -c 'set -a; source #{config.env_file}; set +a; #{config.release_path}/current/bin/migrate'
      elif [[ -x #{release_bin} ]]; then
        log "Running migrations (release eval)"
        sudo bash -c 'set -a; source #{config.env_file}; set +a; #{release_bin} eval "#{migration_eval(otp_app)}"'
      else
        log "Skipping migrations (no migrate command)"
      fi
    else
      log "Skipping migrations (env file missing)"
    fi
    """
  end

  @doc false
  def reload_caddy_script do
    """
    log "Reloading Caddy (TLS/DNS catch-up)"
    sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
    """
  end

  defp migration_eval(otp_app) when is_binary(otp_app) do
    """
    Application.load(:#{otp_app}); case Application.get_env(:#{otp_app}, :ecto_repos, []) do [] -> :ok; repos -> for repo <- repos, do: {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true)) end
    """
    |> String.trim()
  end

  # Persistent runtime data, kept outside the release directory so deploys do
  # not wipe it. Mirrors `App.data_dir/1` but honours a manifest release_path.
  defp data_dir_for(%AppManifest{runtime: "static"}, _config), do: nil

  defp data_dir_for(%AppManifest{runtime: "phoenix"}, config),
    do: "/var/lib/#{Path.basename(config.release_path)}"

  defp data_dir_for(_manifest, config), do: "#{config.release_path}/data"

  defp escape_unit_description(name) when is_binary(name) do
    name |> String.replace(~r/[\r\n]/, " ") |> String.trim()
  end

  defp shell_escape(path) when is_binary(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end
