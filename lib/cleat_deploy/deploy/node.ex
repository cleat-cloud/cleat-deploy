defmodule CleatDeploy.Deploy.Node do
  @moduledoc """
  Build and run a long-lived Node.js server: Next.js, TanStack Start (Nitro),
  or any project with an `npm run build` step and a start command.

  Unlike `static`, the whole project (including `node_modules`, `.next`, or
  `.output`) is published and a systemd unit keeps a Node process alive behind
  the Caddy reverse proxy. The start command is resolved at build time:

    1. `start_command` from `.cleat_deploy/deploy.json`, if set
    2. `npm run start`, if the project declares a `start` script
    3. `node .output/server/index.mjs`, for TanStack Start / Nitro output
    4. `npm exec -- next start`, for Next.js output
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.ServerProvision

  @default_node_version "22"

  def remote_build_script(
        _server,
        %App{} = app,
        config,
        sha,
        remote_tar,
        %AppManifest{} = manifest
      ) do
    """
    set -euo pipefail

    SECONDS=0
    log() { printf '==> [%3ds] %s\\n' "$SECONDS" "$*"; }

    if ! swapon --show | grep -q /swapfile; then
      sudo fallocate -l 2G /swapfile || true
      sudo chmod 600 /swapfile || true
      sudo mkswap /swapfile || true
      sudo swapon /swapfile || true
    fi

    export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
    #{node_install(manifest.node_version)}

    BUILD_DIR="$HOME/cleat_deploy_build_#{sha}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    trap 'rm -rf "$BUILD_DIR"; rm -f #{remote_tar}' EXIT
    log "Unpacking source"
    tar -xzf #{remote_tar} -C "$BUILD_DIR"
    cd "$BUILD_DIR"
    #{project_cd(manifest)}

    if [[ ! -f package.json ]]; then
      echo "No package.json found in the Node project" >&2
      exit 1
    fi

    log "Probing environment"
    if ! command -v node >/dev/null 2>&1; then
      log "Node missing after install — PATH=${PATH}"
    else
      log "Node $(node -v), npm $(npm -v)"
    fi

    log "Installing JS dependencies"
    if [[ -f package-lock.json ]]; then
      npm ci || npm install
    else
      npm install
    fi

    #{build_step(manifest.build_command)}

    #{start_command_script(manifest.start_command)}

    #{shrink_release_script()}

    RELEASE_DIR="#{config.release_path}/releases/build"
    sudo mkdir -p "$RELEASE_DIR"
    sudo rm -rf "${RELEASE_DIR:?}"/*
    log "Publishing $PWD to $RELEASE_DIR"
    sudo cp -a . "$RELEASE_DIR"/
    sudo ln -sfn "$RELEASE_DIR" #{config.release_path}/current
    #{ServerProvision.prune_releases_script(config.release_path)}
    sudo chmod -R a+rX #{config.release_path}

    log "Start command: $START_CMD"
    printf '%s' "$START_CMD" | sudo tee "$RELEASE_DIR/start.cmd" > /dev/null
    echo '#{Base.encode64(ServerProvision.start_script())}' | base64 -d | sudo tee "$RELEASE_DIR/start.sh" > /dev/null
    sudo chmod +x "$RELEASE_DIR/start.sh"

    #{ServerProvision.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Ssh.env_sync_script(app, config)}

    log "Restarting #{config.systemd_unit}"
    sudo systemctl restart #{config.systemd_unit}
    sleep 2

    if sudo systemctl is-active --quiet #{config.systemd_unit}; then
      log "Service #{config.systemd_unit} is active"
    else
      sudo journalctl -u #{config.systemd_unit} -n 50 --no-pager
      exit 1
    fi

    #{ServerProvision.reload_caddy_script()}

    log "Done in ${SECONDS}s"
    """
  end

  defp node_install(version) do
    major = normalize_major(version)

    """
    NODE_MAJOR="#{major}"
    if ! command -v node >/dev/null 2>&1 || ! node -v | grep -q "v${NODE_MAJOR}"; then
      log "Installing Node.js ${NODE_MAJOR}.x"
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    fi
    """
  end

  defp normalize_major(version) when is_binary(version) do
    case Regex.run(~r/^v?(\d+)/, String.trim(version)) do
      [_, major] -> major
      _ -> @default_node_version
    end
  end

  defp normalize_major(_), do: @default_node_version

  defp project_cd(%AppManifest{build_dir: dir}) when is_binary(dir) and dir != "" do
    """
    log "Using Node project in #{dir}"
    cd #{shell_escape(dir)}
    """
  end

  defp project_cd(%AppManifest{}) do
    """
    if [[ ! -f package.json ]]; then
      nested=$(find . -maxdepth 2 -name package.json -not -path '*/node_modules/*' | head -1)
      if [[ -n "$nested" ]]; then
        log "Using Node project in $(dirname "$nested")"
        cd "$(dirname "$nested")"
      fi
    fi
    """
  end

  defp build_step(command) when is_binary(command) and command != "" do
    """
    log "Building (custom build_command)"
    #{command}
    """
  end

  defp build_step(_) do
    """
    if node -e "const s=(require('./package.json').scripts)||{};process.exit(s.build?0:1)"; then
      log "Building"
      npm run build
    else
      log "No build script found; skipping build"
    fi
    """
  end

  defp start_command_script(command) when is_binary(command) and command != "" do
    """
    START_CMD=#{shell_escape(command)}
    """
    |> String.trim()
  end

  defp start_command_script(_) do
    """
    if node -e "const s=(require('./package.json').scripts)||{};process.exit(s.start?0:1)"; then
      START_CMD="npm run start"
    elif [[ -f .output/server/index.mjs ]]; then
      START_CMD="node .output/server/index.mjs"
    elif [[ -f .next/BUILD_ID ]]; then
      START_CMD="npm exec -- next start"
    else
      echo "Could not determine a start command. Add a \\"start\\" script, a .output/server/index.mjs, or set start_command in .cleat_deploy/deploy.json." >&2
      exit 1
    fi
    """
    |> String.trim()
  end

  # devDependencies are only needed to build. Publishing them multiplied the
  # release size on disk (~100MB for a Vite/TanStack app), so prune them before
  # the copy. TanStack Start / Nitro output is self-contained — native deps are
  # traced into `.output/server/node_modules` — so its project node_modules can
  # be dropped entirely.
  defp shrink_release_script do
    """
    if [[ "$START_CMD" == "node .output/server/index.mjs" ]]; then
      log "Self-contained Nitro output; dropping node_modules before publish"
      rm -rf node_modules
    elif [[ -d node_modules ]]; then
      log "Pruning dev dependencies for the release"
      npm prune --omit=dev
    fi
    """
    |> String.trim()
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
