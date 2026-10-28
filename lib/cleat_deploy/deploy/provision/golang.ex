defmodule CleatDeploy.Deploy.Provision.Golang do
  @moduledoc false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Provision.{Caddy, Shell, WakeAgent}

  def provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    data_dir = Shell.data_dir_for(manifest, config)
    env_dir = Path.dirname(config.env_file)
    ssh_user = Map.get(config, :ssh_user, "ubuntu")
    memory_max = manifest.memory_max_mb || 256
    binaries = manifest.binaries || ["server"]

    units =
      Enum.map_join(binaries, "\n", fn bin ->
        unit_name = unit_name(config.systemd_unit, bin)
        exec = "#{config.release_path}/current/bin/#{bin}"
        description = unit_description(app.name, bin)
        # Cais parseListenPort wants PORT=:<port>. Panel env can still override.
        listen_env =
          if bin == "server" do
            "Environment=HOST=127.0.0.1\nEnvironment=PORT=:#{app.port}"
          else
            ""
          end

        unit = """
        [Unit]
        Description=#{Shell.escape_unit_description(description)}
        After=network.target
        StartLimitIntervalSec=60
        StartLimitBurst=5

        [Service]
        Type=exec
        User=#{ssh_user}
        Group=#{ssh_user}
        WorkingDirectory=#{config.release_path}/current
        EnvironmentFile=#{config.env_file}
        Environment=CLEAT_DATA_DIR=#{data_dir}
        #{listen_env}
        ExecStart=#{exec}
        Restart=always
        RestartSec=5
        KillMode=control-group
        TimeoutStopSec=15
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

    caddy_script = Caddy.provision_script(app, config, manifest)
    wake_script = WakeAgent.script(app, config, manifest)

    """
    log "Provisioning host #{app.host} on port #{app.port}"
    sudo mkdir -p #{Shell.shell_escape(env_dir)} #{Shell.shell_escape(data_dir)}
    id #{ssh_user} >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash #{ssh_user}
    sudo chown -R #{ssh_user}:#{ssh_user} #{Shell.shell_escape(config.release_path)}

    #{units}
    sudo systemctl daemon-reload

    #{wake_script}
    #{caddy_script}
    """
  end

  defp unit_name(systemd_unit, "server"), do: systemd_unit
  defp unit_name(systemd_unit, bin), do: "#{systemd_unit}-#{bin}"

  defp unit_description(name, "server"), do: "#{name} (Cais)"
  defp unit_description(name, "worker"), do: "#{name} worker (Cais jobs)"
  defp unit_description(name, bin), do: "#{name} #{bin}"
end
