defmodule CleatDeploy.Deploy.Provision.Phoenix do
  @moduledoc false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Provision.{Account, Caddy, Shell, WakeAgent}

  # Phoenix/OTP releases do not need root on a shared host (#218): each app runs
  # as its own unprivileged system account with write access limited to its data
  # dir. Existing installs migrate on their next deploy — the account is created
  # and the data dir (written as root until now) is handed to it before the unit
  # restarts. Systemd reads the root-only env file before dropping privileges.
  def provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    data_dir = Shell.data_dir_for(manifest, config)
    env_dir = Path.dirname(config.env_file)
    memory_max = manifest.memory_max_mb || 400
    user = Account.service_user(app.slug)

    unit = """
    [Unit]
    Description=#{Shell.escape_unit_description(app.name)}
    After=network.target
    StartLimitIntervalSec=60
    StartLimitBurst=5

    [Service]
    Type=exec
    User=#{user}
    Group=#{user}
    WorkingDirectory=#{config.release_path}/current
    EnvironmentFile=#{config.env_file}
    Environment=CLEAT_DATA_DIR=#{data_dir}
    Environment=HOME=#{data_dir}
    Environment=RELEASE_TMP=#{data_dir}/tmp
    ExecStart=#{config.release_path}/current/bin/#{config.release_name} start
    Restart=always
    RestartSec=5
    KillMode=control-group
    TimeoutStopSec=15
    MemoryMax=#{memory_max}M
    LimitNOFILE=65535
    # Unprivileged service: it can only write its own data dir (#218).
    NoNewPrivileges=true
    PrivateTmp=true
    ProtectSystem=full
    ProtectHome=true
    ReadWritePaths=#{data_dir}

    [Install]
    WantedBy=multi-user.target
    """

    caddy_script = Caddy.provision_script(app, config, manifest)
    wake_script = WakeAgent.script(app, config, manifest)

    """
    log "Provisioning host #{app.host} on port #{app.port}"
    sudo mkdir -p #{Shell.shell_escape(env_dir)} #{Shell.shell_escape(data_dir)} #{Shell.shell_escape(Path.join(data_dir, "tmp"))}

    #{Account.create_script(user, data_dir)}

    sudo tee /etc/systemd/system/#{config.systemd_unit}.service > /dev/null <<'PAAS_SYSTEMD_UNIT'
    #{String.trim_trailing(unit)}
    PAAS_SYSTEMD_UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable #{config.systemd_unit}

    #{wake_script}
    #{caddy_script}
    """
  end

  # Fallback for manifests whose runtime has no dedicated pipeline: the same
  # root-owned OTP release unit the panel has always written.
  def default_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    data_dir = Shell.data_dir_for(manifest, config)
    env_dir = Path.dirname(config.env_file)
    memory_max = manifest.memory_max_mb || 400

    unit = """
    [Unit]
    Description=#{Shell.escape_unit_description(app.name)}
    After=network.target
    StartLimitIntervalSec=60
    StartLimitBurst=5

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
    KillMode=control-group
    TimeoutStopSec=15
    MemoryMax=#{memory_max}M
    LimitNOFILE=65535

    [Install]
    WantedBy=multi-user.target
    """

    caddy_script = Caddy.provision_script(app, config, manifest)
    wake_script = WakeAgent.script(app, config, manifest)

    """
    log "Provisioning host #{app.host} on port #{app.port}"
    sudo mkdir -p #{Shell.shell_escape(env_dir)} #{Shell.shell_escape(data_dir)}

    sudo tee /etc/systemd/system/#{config.systemd_unit}.service > /dev/null <<'PAAS_SYSTEMD_UNIT'
    #{String.trim_trailing(unit)}
    PAAS_SYSTEMD_UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable #{config.systemd_unit}

    #{wake_script}
    #{caddy_script}
    """
  end
end
