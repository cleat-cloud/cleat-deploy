defmodule CleatDeploy.Deploy.Rust do
  @moduledoc """
  Build and run a Rust server, with first-class support for Loco.

  Installs rustup, compiles a `--release` binary (target dir cached outside
  the per-deploy build tree), copies `config/` and `assets/` (and a Loco
  `frontend/` when present) into the release, and keeps the process alive with
  a systemd unit behind the Caddy reverse proxy.

  The start command is resolved at build time:

    1. `start_command` from `.cleat_deploy/deploy.json`, if set
    2. `./bin/server start`, for a Loco app (`loco-rs` or `config/production.yaml`)
    3. `./bin/server`, for a plain Rust binary

  The compiled package binary is always published as `bin/server`. Loco's
  `LOCO_ENV=production`, `PORT`, `BINDING` and public `HOST` come from the
  systemd unit. `DATABASE_URL` / `JWT_SECRET` come from the panel env vars.
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
      sudo fallocate -l 4G /swapfile || true
      sudo chmod 600 /swapfile || true
      sudo mkswap /swapfile || true
      sudo swapon /swapfile || true
    fi

    #{apt_packages()}
    #{rust_install()}

    BUILD_DIR="$HOME/cleat_deploy_build_#{sha}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    trap 'rm -rf "$BUILD_DIR"; rm -f #{remote_tar}' EXIT
    log "Unpacking source"
    tar -xzf #{remote_tar} -C "$BUILD_DIR"
    cd "$BUILD_DIR"
    #{project_cd(manifest)}

    if [[ ! -f Cargo.toml ]]; then
      echo "No Cargo.toml found in the Rust project" >&2
      exit 1
    fi

    #{frontend_step(manifest)}

    export CARGO_HOME="$HOME/.cargo"
    export CARGO_TARGET_DIR="$HOME/.cache/cleat-rust/#{shell_escape_unquoted(app.slug)}"
    mkdir -p "$CARGO_TARGET_DIR"

    #{build_step(manifest.build_command)}

    BIN_NAME=$(python3 - <<'PY'
    import re, sys
    from pathlib import Path
    text = Path("Cargo.toml").read_text()
    match = re.search(r'(?ms)^\\[package\\].*?^name\\s*=\\s*"([^"]+)"', text)
    if not match:
        sys.exit("Could not read package name from Cargo.toml")
    print(match.group(1).replace("-", "_"))
    PY
    )
    BIN_PATH="$CARGO_TARGET_DIR/release/$BIN_NAME"
    if [[ ! -f "$BIN_PATH" ]]; then
      echo "Release binary not found at $BIN_PATH" >&2
      ls -la "$CARGO_TARGET_DIR/release" >&2 || true
      exit 1
    fi
    mkdir -p bin
    cp "$BIN_PATH" bin/server
    chmod +x bin/server
    log "Built bin/server ($BIN_NAME)"

    #{start_command_script(manifest.start_command)}

    RELEASE_DIR="#{config.release_path}/releases/build"
    sudo mkdir -p "$RELEASE_DIR"
    sudo rm -rf "${RELEASE_DIR:?}"/*
    sudo mkdir -p "$RELEASE_DIR/bin"
    log "Publishing binary and runtime files to $RELEASE_DIR"
    sudo cp -a bin/server "$RELEASE_DIR/bin/server"
    for dir in config assets frontend; do
      if [[ -d "$dir" ]]; then
        sudo cp -a "$dir" "$RELEASE_DIR/$dir"
      fi
    done
    sudo ln -sfn "$RELEASE_DIR" #{config.release_path}/current
    #{ServerProvision.prune_releases_script(config.release_path)}
    sudo chmod -R a+rX #{config.release_path}

    log "Start command: $START_CMD"
    printf '%s' "$START_CMD" | sudo tee "$RELEASE_DIR/start.cmd" > /dev/null
    echo '#{Base.encode64(ServerProvision.start_script())}' | base64 -d | sudo tee "$RELEASE_DIR/start.sh" > /dev/null
    sudo chmod +x "$RELEASE_DIR/start.sh"
    #{ServerProvision.extra_start_commands(manifest, config)}

    #{ServerProvision.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Addons.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Ssh.env_sync_script(app, config)}
    #{migrate_step(manifest, config)}
    #{ServerProvision.release_command_script(app, config, manifest)}

    #{ServerProvision.restart_units_script(config, manifest)}

    #{ServerProvision.reload_caddy_script()}

    log "Done in ${SECONDS}s"
    """
  end

  defp apt_packages do
    """
    log "Installing build packages"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \\
      curl ca-certificates build-essential pkg-config libssl-dev libsqlite3-dev python3
    """
  end

  defp rust_install do
    """
    export PATH="$HOME/.cargo/bin:$PATH"
    if ! command -v rustup >/dev/null 2>&1; then
      log "Installing Rust (rustup)"
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
    rustup default stable
    log "Rust $(rustc --version)"
    """
  end

  defp project_cd(%AppManifest{build_dir: dir}) when is_binary(dir) and dir != "" do
    """
    log "Using Rust project in #{dir}"
    cd #{shell_escape(dir)}
    """
  end

  defp project_cd(%AppManifest{}) do
    """
    if [[ ! -f Cargo.toml ]]; then
      nested=$(find . -maxdepth 2 -name Cargo.toml | head -1)
      if [[ -n "$nested" ]]; then
        log "Using Rust project in $(dirname "$nested")"
        cd "$(dirname "$nested")"
      fi
    fi
    """
  end

  defp frontend_step(%AppManifest{node_version: version}) do
    """
    if [[ -f frontend/package.json ]]; then
      #{node_install(version)}
      log "Building frontend"
      (cd frontend && { npm ci --no-audit --no-fund || npm install --no-audit --no-fund; } && npm run build)
    fi
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

  defp build_step(command) when is_binary(command) and command != "" do
    """
    log "Building (custom build_command)"
    #{command}
    """
  end

  defp build_step(_) do
    """
    log "Building (cargo build --release)"
    cargo build --release
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
    if [[ -f config/production.yaml ]] || grep -Eq 'loco-rs' Cargo.toml 2>/dev/null; then
      START_CMD='./bin/server start'
    else
      START_CMD='./bin/server'
    fi
    """
    |> String.trim()
  end

  # `db migrate` is the runtime's default migration step; an explicit
  # release_command replaces it.
  defp migrate_step(%AppManifest{} = manifest, config) do
    if AppManifest.release_commands(manifest) == [] do
      """
      if [[ -f #{config.release_path}/current/config/production.yaml ]] || grep -Eq 'loco-rs' Cargo.toml 2>/dev/null; then
        log "Running loco db migrate"
        sudo bash -c 'set -a; source #{config.env_file}; set +a; cd #{config.release_path}/current; export LOCO_ENV=production; ./bin/server db migrate'
      else
        log "No Loco production config; skipping db migrate"
      fi
      """
      |> String.trim()
    else
      """
      log "Skipping db migrate (release_command is set in .cleat_deploy/deploy.json)"
      """
      |> String.trim()
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp shell_escape_unquoted(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
  end
end
