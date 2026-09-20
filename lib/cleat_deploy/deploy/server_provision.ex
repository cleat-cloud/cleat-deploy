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

  def provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    data_dir = "/var/lib/#{Path.basename(config.release_path)}"
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
    data_dir = "#{config.release_path}/data"
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
    Environment=NODE_ENV=production
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
    log "Provisioning Node host #{app.host} on port #{app.port}"
    sudo mkdir -p #{shell_escape(env_dir)}
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

  defp append_caddy_site(address, caddy_site) do
    """
    if ! sudo grep -Fq '#{address} {' /etc/caddy/Caddyfile; then
      log "Adding Caddy site #{address}"
      sudo tee -a /etc/caddy/Caddyfile > /dev/null <<'PAAS_CADDY_SITE'
    #{String.trim_leading(caddy_site)}
    PAAS_CADDY_SITE
    fi
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

  defp escape_unit_description(name) when is_binary(name) do
    name |> String.replace(~r/[\r\n]/, " ") |> String.trim()
  end

  defp shell_escape(path) when is_binary(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end
