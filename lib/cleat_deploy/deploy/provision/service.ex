defmodule CleatDeploy.Deploy.Provision.Service do
  @moduledoc false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Provision.{Account, Caddy, Shell, WakeAgent}

  @doc """
  Systemd units for long-lived app servers that start through a generated
  `current/start.sh` (Node, Rails, Rust, Gleam).
  """
  def provision_script(%App{} = app, config, %AppManifest{runtime: runtime} = manifest) do
    {env_lines, label} = runtime_profile(runtime, app)
    service_provision_script(app, config, manifest, env_lines, label)
  end

  @doc """
  Restarts every unit of the app and fails the deploy when one of them does not
  come up. `web` goes first so the HTTP endpoint is ready before the workers.

  A stop that needed SIGKILL is surfaced as a warning: the app ignored SIGTERM
  (no graceful shutdown), and a hard kill on an app with SQLite/Litestream can
  leave WAL state behind.
  """
  def restart_units_script(config, %AppManifest{} = manifest) do
    manifest
    |> app_units(config.systemd_unit)
    |> Enum.map_join("\n\n", fn {_process, unit_name} ->
      """
      log "Restarting #{unit_name}"
      sudo systemctl restart #{unit_name}
      sleep 2

      if sudo systemctl is-active --quiet #{unit_name}; then
        log "Service #{unit_name} is active"
        if sudo journalctl -u #{unit_name} --since "3 min ago" --no-pager 2>/dev/null | grep -q "timed out. Killing."; then
          log "WARN: #{unit_name} ignored SIGTERM and was SIGKILLed on stop — add a graceful shutdown handler"
        fi
      else
        sudo journalctl -u #{unit_name} -n 50 --no-pager
        exit 1
      fi
      """
      |> String.trim()
    end)
  end

  @doc """
  Command files for the non-web processes (`start.<name>.cmd`), written next to
  the launcher. The web command keeps using `start.cmd`.
  """
  def extra_start_commands(%AppManifest{} = manifest, config) do
    manifest
    |> AppManifest.processes()
    |> Enum.reject(fn {process, _command} -> process == "web" end)
    |> Enum.sort()
    |> Enum.map_join("\n", fn {process, command} ->
      release_dir = "#{config.release_path}/releases/build"

      "echo '#{Base.encode64(command)}' | base64 -d | sudo tee #{Shell.shell_escape("#{release_dir}/#{command_file_name(process)}")} > /dev/null"
    end)
  end

  @doc """
  Generic launcher written to `current/start.sh` for app servers whose start
  command lives in `current/start.cmd` (or in the file named by the first
  argument, used by the extra processes of a multi-process app). Sources the
  systemd-provided env (`PORT`, `HOST`, `NODE_ENV`/`RAILS_ENV`) and runs the
  command.

  Runs the command instead of `exec`-ing straight through so a non-zero exit and
  the app's own stderr stay visible in the journal (a bare `exec` made a crashed
  app indistinguishable from a clean shutdown).
  """
  def start_script do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    cd "$(dirname "$0")"

    # Rails (Puma's pid file, the log, the cache, ActiveStorage) writes into
    # directories that git does not carry when they are empty — the deploy clone
    # never has them.
    mkdir -p tmp/pids tmp/cache log storage

    CMD_FILE="${1:-start.cmd}"
    CMD="$(cat "$(dirname "$0")/$CMD_FILE")"
    printf '==> starting (%s): %s\\n' "$CMD_FILE" "$CMD" >&2

    set +e
    bash -c "$CMD"
    code=$?
    set -e
    printf '==> app exited with status %s\\n' "$code" >&2
    exit "$code"
    """
  end

  defp runtime_profile("node", _app), do: {["Environment=NODE_ENV=production"], "Node"}

  defp runtime_profile("rails", _app), do: {["Environment=RAILS_ENV=production"], "Rails"}

  defp runtime_profile("rust", app) do
    {[
       "Environment=LOCO_ENV=production",
       "Environment=BINDING=127.0.0.1",
       "Environment=HOST=https://#{app.host}"
     ], "Rust"}
  end

  # The Gleam shipment reads PORT and binds where the app decides; `erl` comes
  # from /usr/local/bin (linked at build time) because the shipment carries no
  # ERTS of its own.
  defp runtime_profile("gleam", _app), do: {[], "Gleam"}

  # One unit per process: `web` keeps the base unit name (Caddy, the wake agent
  # and the idle sweeper all point at it) and is the only one that gets
  # PORT/HOST; every other process becomes `<unit>-<name>` and never binds the
  # app port.
  defp service_provision_script(%App{} = app, config, %AppManifest{} = manifest, env_lines, label) do
    data_dir = Shell.data_dir_for(manifest, config)
    env_dir = Path.dirname(config.env_file)
    memory_max = manifest.memory_max_mb || 400
    extra_env = Enum.join(env_lines, "\n    ")
    units = app_units(manifest, config.systemd_unit)
    user = Account.service_user(app.slug)

    unit_files =
      Enum.map_join(units, "\n\n", fn {process, unit_name} ->
        unit =
          service_unit_file(
            app,
            config,
            unit_name,
            process,
            data_dir,
            memory_max,
            extra_env,
            user
          )

        """
        sudo tee /etc/systemd/system/#{unit_name}.service > /dev/null <<'PAAS_SYSTEMD_UNIT'
        #{String.trim_trailing(unit)}
        PAAS_SYSTEMD_UNIT
        """
      end)

    enable_units =
      Enum.map_join(units, "\n", fn {_process, unit_name} ->
        "sudo systemctl enable #{unit_name}"
      end)

    caddy_script = Caddy.provision_script(app, config, manifest)
    wake_script = WakeAgent.script(app, config, manifest)

    """
    log "Provisioning #{label} host #{app.host} on port #{app.port}"
    sudo mkdir -p #{Shell.shell_escape(env_dir)} #{Shell.shell_escape(data_dir)} #{Shell.shell_escape(Path.join(data_dir, "tmp"))}
    sudo touch #{Shell.shell_escape(config.env_file)}
    sudo chmod 600 #{Shell.shell_escape(config.env_file)}

    #{Account.create_script(user, data_dir)}

    #{unit_files}

    sudo systemctl daemon-reload
    #{enable_units}

    #{wake_script}
    #{caddy_script}
    """
  end

  # `[process, unit_name]` pairs: `web` first (it owns the base unit), then the
  # extra processes in a stable order.
  defp app_units(%AppManifest{} = manifest, systemd_unit) do
    [{"web", systemd_unit}] ++
      Enum.map(AppManifest.extra_units(manifest), &{&1, "#{systemd_unit}-#{&1}"})
  end

  defp service_unit_file(app, config, _unit_name, process, data_dir, memory_max, extra_env, user) do
    port_lines =
      if process == "web" do
        "Environment=HOST=127.0.0.1\nEnvironment=PORT=#{app.port}"
      else
        ""
      end

    description =
      if process == "web",
        do: Shell.escape_unit_description(app.name),
        else: Shell.escape_unit_description("#{app.name} (#{process})")

    # The web process uses the launcher default (`start.cmd`); the others get
    # their own command file so they never run the web command.
    exec_arg = if process == "web", do: "", else: " #{command_file_name(process)}"

    """
    [Unit]
    Description=#{description}
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
    #{port_lines}
    #{extra_env}
    ExecStart=/bin/bash #{config.release_path}/current/start.sh#{exec_arg}
    Restart=always
    RestartSec=5
    # Kill the whole cgroup: an orphaned child (e.g. a node process that escaped
    # the launcher) keeps the port and makes every restart fail to bind, which
    # without a start limit becomes an infinite restart loop.
    KillMode=control-group
    # Node/Rails servers may wait for in-flight requests before exiting; 15s
    # cut graceful handlers short and systemd escalated to SIGKILL (#212).
    # restart_units_script warns when a stop still needs the SIGKILL.
    TimeoutStopSec=30
    MemoryMax=#{memory_max}M
    LimitNOFILE=65535
    # Unprivileged service: write is limited to persist + release (#231).
    NoNewPrivileges=true
    PrivateTmp=true
    ProtectSystem=full
    ProtectHome=true
    ReadWritePaths=#{data_dir} #{config.release_path}

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp command_file_name("web"), do: "start.cmd"
  defp command_file_name(process), do: "start.#{process}.cmd"
end
