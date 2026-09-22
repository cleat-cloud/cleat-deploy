defmodule CleatDeploy.Deploy.ServerProvision do
  @moduledoc false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Wake

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

    caddy_script = caddy_provision_script(app, config, manifest)
    wake_script = wake_provision_script(app, config, manifest)

    """
    log "Provisioning host #{app.host} on port #{app.port}"
    sudo mkdir -p #{shell_escape(env_dir)} #{shell_escape(data_dir)}

    sudo tee /etc/systemd/system/#{config.systemd_unit}.service > /dev/null <<'PAAS_SYSTEMD_UNIT'
    #{String.trim_trailing(unit)}
    PAAS_SYSTEMD_UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable #{config.systemd_unit}

    #{wake_script}
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
        StartLimitIntervalSec=60
        StartLimitBurst=5

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

    caddy_script = caddy_provision_script(app, config, manifest)
    wake_script = wake_provision_script(app, config, manifest)

    """
    log "Provisioning host #{app.host} on port #{app.port}"
    sudo mkdir -p #{shell_escape(env_dir)} #{shell_escape(data_dir)}
    id #{ssh_user} >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash #{ssh_user}
    sudo chown -R #{ssh_user}:#{ssh_user} #{shell_escape(config.release_path)}

    #{units}
    sudo systemctl daemon-reload

    #{wake_script}
    #{caddy_script}
    """
  end

  defp golang_unit_name(systemd_unit, "server"), do: systemd_unit
  defp golang_unit_name(systemd_unit, bin), do: "#{systemd_unit}-#{bin}"

  defp golang_unit_description(name, "server"), do: "#{name} (Cais)"
  defp golang_unit_description(name, "worker"), do: "#{name} worker (Cais jobs)"
  defp golang_unit_description(name, bin), do: "#{name} #{bin}"

  defp static_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    caddy_script = caddy_provision_script(app, config, manifest)
    wake_script = wake_provision_script(app, config, manifest)

    """
    log "Provisioning static site #{app.host}"
    sudo mkdir -p #{shell_escape(config.release_path)}

    #{wake_script}
    #{caddy_script}
    """
  end

  defp node_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    service_provision_script(app, config, manifest, ["Environment=NODE_ENV=production"], "Node")
  end

  defp rails_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    service_provision_script(app, config, manifest, ["Environment=RAILS_ENV=production"], "Rails")
  end

  # Shared systemd units for long-lived app servers that start through a
  # generated `current/start.sh` (Node, Rails).
  #
  # One unit per process: `web` keeps the base unit name (Caddy, the wake agent
  # and the idle sweeper all point at it) and is the only one that gets
  # PORT/HOST; every other process becomes `<unit>-<name>` and never binds the
  # app port.
  defp service_provision_script(%App{} = app, config, %AppManifest{} = manifest, env_lines, label) do
    data_dir = data_dir_for(manifest, config)
    env_dir = Path.dirname(config.env_file)
    memory_max = manifest.memory_max_mb || 400
    extra_env = Enum.join(env_lines, "\n    ")
    units = app_units(manifest, config.systemd_unit)

    unit_files =
      Enum.map_join(units, "\n\n", fn {process, unit_name} ->
        unit = service_unit_file(app, config, unit_name, process, data_dir, memory_max, extra_env)

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

    caddy_script = caddy_provision_script(app, config, manifest)
    wake_script = wake_provision_script(app, config, manifest)

    """
    log "Provisioning #{label} host #{app.host} on port #{app.port}"
    sudo mkdir -p #{shell_escape(env_dir)} #{shell_escape(data_dir)}
    sudo touch #{shell_escape(config.env_file)}
    sudo chmod 600 #{shell_escape(config.env_file)}

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

  defp service_unit_file(app, config, _unit_name, process, data_dir, memory_max, extra_env) do
    port_lines =
      if process == "web" do
        "Environment=HOST=127.0.0.1\nEnvironment=PORT=#{app.port}"
      else
        ""
      end

    description =
      if process == "web",
        do: escape_unit_description(app.name),
        else: escape_unit_description("#{app.name} (#{process})")

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
    User=root
    Group=root
    WorkingDirectory=#{config.release_path}/current
    EnvironmentFile=#{config.env_file}
    Environment=CLEAT_DATA_DIR=#{data_dir}
    #{extra_env}
    #{port_lines}
    ExecStart=/bin/bash #{config.release_path}/current/start.sh#{exec_arg}
    Restart=always
    RestartSec=5
    # Kill the whole cgroup: an orphaned child (e.g. a node process that escaped
    # the launcher) keeps the port and makes every restart fail to bind, which
    # without a start limit becomes an infinite restart loop.
    KillMode=control-group
    TimeoutStopSec=15
    MemoryMax=#{memory_max}M
    LimitNOFILE=65535

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp command_file_name("web"), do: "start.cmd"
  defp command_file_name(process), do: "start.#{process}.cmd"

  @doc """
  Restarts every unit of the app and fails the deploy when one of them does not
  come up. `web` goes first so the HTTP endpoint is ready before the workers.
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

      "echo '#{Base.encode64(command)}' | base64 -d | sudo tee #{shell_escape("#{release_dir}/#{command_file_name(process)}")} > /dev/null"
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

  defp caddy_provision_script(
         %App{},
         _config,
         %AppManifest{caddy_mode: "replace", caddyfile: path}
       )
       when is_binary(path) and path != "" do
    """
    #{ensure_caddy_script()}

    log "Installing custom Caddyfile (#{path})"
    if [[ ! -f "$BUILD_DIR/#{path}" ]]; then
      echo "Custom Caddyfile not found at $BUILD_DIR/#{path}" >&2
      exit 1
    fi
    sudo cp "$BUILD_DIR/#{path}" /etc/caddy/Caddyfile
    """
  end

  # Caddy's `file_server` sends only `ETag`/`Last-Modified`, so browsers fall
  # back to heuristic freshness and keep serving a previous deploy's page
  # without ever revalidating. `no-cache` forces a conditional request on every
  # load: unchanged files still answer 304, changed ones are refetched. The
  # filenames published here are not content-hashed, so nothing can be cached
  # immutably.
  defp caddy_provision_script(%App{} = app, _config, %AppManifest{runtime: "static"}) do
    address = caddy_site_address(app)

    caddy_site = """
    #{address} {
      encode gzip
      root * #{static_site_root(app)}
      try_files {path} {path}/index.html /index.html
      header Cache-Control "no-cache"
      file_server
    }
    """

    caddy_site_script(address, caddy_site)
  end

  defp caddy_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    address = caddy_site_address(app)

    if Wake.enabled?(app, manifest) do
      unit = config.systemd_unit

      # `forward_auth` runs before the proxy: the agent answers 2xx once the app
      # is listening (starting it first when it is not), and only then does
      # Caddy hand the request to the app.
      caddy_site = """
      #{address} {
        encode gzip
        forward_auth 127.0.0.1:#{Wake.wake_port()} {
          uri /wake?unit=#{unit}&port=#{app.port}
        }
        reverse_proxy 127.0.0.1:#{app.port}
      }
      """

      """
      #{caddy_site_script(address, caddy_site)}
      #{Wake.arm_script(unit)}
      """
    else
      caddy_site = """
      #{address} {
        encode gzip
        reverse_proxy 127.0.0.1:#{app.port}
      }
      """

      caddy_site_script(address, caddy_site)
    end
  end

  # Installs (or refreshes) the wake agent for opted-in apps. Apps that are not
  # armed get their stamp removed, so the sweeper never stops something that
  # cannot be woken again.
  defp wake_provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    if Wake.enabled?(app, manifest) do
      Wake.install_script(config.systemd_unit)
    else
      Wake.disarm_script(config.systemd_unit)
    end
  end

  # A VM created from the panel has nothing installed: the ops bootstrap scripts
  # put Caddy there, but the panel has to be able to provision a fresh server on
  # its own. Idempotent (a `command -v` check), so it can be inlined wherever a
  # Caddyfile is written.
  defp ensure_caddy_script do
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

  # Rewrites the managed site block for `address` on every deploy. The upstream
  # (app port) can change after creation, so appending only when the address is
  # new would leave Caddy proxying to the old port. Emitted as a shell function
  # so the caller picks the body and this stays the single implementation of the
  # strip-and-append dance.
  defp caddy_site_script(address, caddy_site) do
    """
    #{ensure_caddy_script()}

    write_caddy_site() {
      CADDYFILE="/etc/caddy/Caddyfile"
      sudo touch "$CADDYFILE"
      TMPFILE="$(mktemp)"
      sudo awk -v site=#{shell_escape(address)} '
        $0 == site " {" { inside = 1; next }
        inside && $0 == "}" { inside = 0; next }
        inside { next }
        { print }
      ' "$CADDYFILE" > "$TMPFILE"
      cat >> "$TMPFILE"
      sudo install -m 0644 -o root -g root "$TMPFILE" "$CADDYFILE"
      rm -f "$TMPFILE"
      log "Writing Caddy site #{address}"
    }

    write_caddy_site <<'PAAS_CADDY_SITE'
    #{String.trim_trailing(caddy_site)}
    PAAS_CADDY_SITE
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

  @doc """
  Runs the app's `release_command`s from `.cleat_deploy/deploy.json` against the
  release already published in `current/`, before the service is restarted.

  Sourced with the app env file and `CLEAT_DATA_DIR` (same environment the unit
  will get), streamed into the deploy log, and with a timeout per command. A
  non-zero exit aborts the deploy because the caller's script runs under
  `set -e` — the restart never happens and the previous process keeps serving.

  Returns `""` when the manifest declares no release command.
  """
  def release_command_script(%App{}, config, %AppManifest{} = manifest) do
    commands = AppManifest.release_commands(manifest)

    if commands == [] do
      ""
    else
      timeout = AppManifest.release_timeout_s(manifest)
      runtime_env = runtime_env_exports(manifest)
      data_dir = data_dir_for(manifest, config)
      total = length(commands)

      commands
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {command, index} ->
        release_command_step(command, index, total, config, runtime_env, timeout, data_dir)
      end)
      |> String.trim()
    end
  end

  # The command is shipped base64-encoded (no quoting games) and echoed back
  # through the file, so the log shows exactly what ran.
  defp release_command_step(command, index, total, config, runtime_env, timeout, data_dir) do
    """
    echo '#{Base.encode64(command)}' | base64 -d | sudo tee /tmp/cleat_release_cmd.sh > /dev/null
    sudo chmod 700 /tmp/cleat_release_cmd.sh
    log "Running release command (#{index}/#{total}): $(cat /tmp/cleat_release_cmd.sh)"
    sudo bash -c 'set -a; source #{config.env_file}; set +a; cd #{config.release_path}/current; export CLEAT_DATA_DIR=#{data_dir}; #{runtime_env}timeout #{timeout} bash /tmp/cleat_release_cmd.sh'
    sudo rm -f /tmp/cleat_release_cmd.sh
    """
  end

  defp runtime_env_exports(%AppManifest{runtime: "rails"}), do: "export RAILS_ENV=production; "
  defp runtime_env_exports(%AppManifest{runtime: "node"}), do: "export NODE_ENV=production; "
  defp runtime_env_exports(%AppManifest{}), do: ""

  @doc """
  Deletes legacy/orphan release directories under `release_path/releases`.

  Every runtime publishes to `releases/build` and the caller runs this right
  after pointing `current` at it, so anything else is stale (e.g. the old
  timestamped releases that used to fill the disk).
  """
  def prune_releases_script(release_path) do
    """
    sudo find #{shell_escape(release_path)}/releases -mindepth 1 -maxdepth 1 -type d ! -name build -exec rm -rf {} + 2>/dev/null || true
    """
    |> String.trim()
  end

  @doc """
  Empties a release directory before publishing into it.

  `rm -rf "$DIR"/*` does not match dotfiles, so a stale `.next`, `.output` or
  `.gitignore` from a previous release survives the copy. `find -mindepth 1
  -delete` removes everything, hidden entries included.
  """
  def clean_release_script(release_path) do
    """
    sudo mkdir -p #{shell_escape(release_path)}
    sudo find #{shell_escape(release_path)} -mindepth 1 -delete
    """
    |> String.trim()
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
