defmodule CleatDeploy.Deploy.Gleam do
  @erlang_version "28.4.1"
  @default_gleam_version "1.18.1"

  @moduledoc """
  Build and run a Gleam app on the Erlang target.

  Installs Erlang and Gleam with mise, exports the project as an Erlang
  shipment and publishes the shipment whole, so the generated `entrypoint.sh`
  is what systemd keeps alive behind the Caddy reverse proxy.

  A shipment does **not** embed ERTS (unlike a `mix release`), and the unit
  runs as root, so `erl`/`erlc`/`escript`/`epmd` are symlinked into
  `/usr/local/bin` at build time. Build and run use the same OTP release
  (`#{@erlang_version}`): BEAM bytecode does not load on an older Erlang.

  The build is `gleam deps download` + `gleam export erlang-shipment`, which
  produces `build/erlang-shipment/`; `build_command` in
  `.cleat_deploy/deploy.json` replaces it and must produce the same path. A
  project whose `gleam.toml` targets JavaScript is rejected — this runtime
  builds the Erlang target only.

  The persistent data dir (`<release_path>/data`) is created and exported as
  `CLEAT_DATA_DIR` before the build, so an app that migrates from the source
  tree can do it in `build_command` (the shipment itself does not carry the
  source).
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.ServerProvision

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

    #{apt_packages()}
    #{gleam_install(manifest)}

    BUILD_DIR="$HOME/cleat_deploy_build_#{sha}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    trap 'rm -rf "$BUILD_DIR"; rm -f #{remote_tar}' EXIT
    log "Unpacking source"
    tar -xzf #{remote_tar} -C "$BUILD_DIR"
    cd "$BUILD_DIR"
    #{project_cd(manifest)}

    if [[ ! -f gleam.toml ]]; then
      echo "No gleam.toml found in the Gleam project" >&2
      exit 1
    fi

    if grep -Eq '^[[:space:]]*target[[:space:]]*=[[:space:]]*"javascript"' gleam.toml; then
      echo "gleam.toml targets JavaScript; the gleam runtime builds the Erlang target only." >&2
      echo "Set target = \\"erlang\\" in gleam.toml, or deploy the built output as a node app." >&2
      exit 1
    fi

    DATA_DIR="#{data_dir(config)}"
    log "Preparing persistent data dir $DATA_DIR"
    sudo mkdir -p "$DATA_DIR"
    sudo chown "$(id -u):$(id -g)" "$DATA_DIR"
    export CLEAT_DATA_DIR="$DATA_DIR"

    #{build_step(manifest.build_command)}

    SHIP_DIR="build/erlang-shipment"
    if [[ ! -f "$SHIP_DIR/entrypoint.sh" ]]; then
      echo "No Erlang shipment at $SHIP_DIR (expected $SHIP_DIR/entrypoint.sh)" >&2
      ls -la build 2>/dev/null || true
      exit 1
    fi

    RELEASE_DIR="#{config.release_path}/releases/build"
    sudo mkdir -p "$RELEASE_DIR"
    sudo rm -rf "${RELEASE_DIR:?}"/*
    log "Publishing Erlang shipment to $RELEASE_DIR"
    sudo cp -a "$SHIP_DIR/." "$RELEASE_DIR/"
    sudo chmod +x "$RELEASE_DIR/entrypoint.sh"
    sudo ln -sfn "$RELEASE_DIR" #{config.release_path}/current
    #{ServerProvision.prune_releases_script(config.release_path)}
    sudo chmod -R a+rX #{config.release_path}

    START_CMD='./entrypoint.sh run'
    log "Start command: $START_CMD"
    printf '%s' "$START_CMD" | sudo tee "$RELEASE_DIR/start.cmd" > /dev/null
    echo '#{Base.encode64(ServerProvision.start_script())}' | base64 -d | sudo tee "$RELEASE_DIR/start.sh" > /dev/null
    sudo chmod +x "$RELEASE_DIR/start.sh"
    #{ServerProvision.extra_start_commands(manifest, config)}

    #{ServerProvision.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Addons.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Ssh.env_sync_script(app, config)}
    #{ServerProvision.release_command_script(app, config, manifest)}

    #{ServerProvision.restart_units_script(config, manifest)}

    #{ServerProvision.reload_caddy_script()}

    log "Done in ${SECONDS}s"
    """
  end

  defp data_dir(config), do: "#{config.release_path}/data"

  defp apt_packages do
    """
    log "Installing build packages"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \\
      curl ca-certificates build-essential git
    """
  end

  defp gleam_install(%AppManifest{} = manifest) do
    erlang = @erlang_version
    gleam = gleam_version(manifest)

    """
    if ! command -v mise >/dev/null 2>&1; then
      log "Installing mise"
      curl -fsSL https://mise.run | sh
    fi

    export PATH="$HOME/.local/bin:$PATH"
    eval "$(mise activate bash)"
    mise install erlang@#{erlang} gleam@#{gleam}
    mise use -g erlang@#{erlang} gleam@#{gleam}
    log "Gleam $(gleam --version)"

    # The shipment runs the OTP already installed here and does not carry its
    # own ERTS, and the unit runs as root: expose erl outside the build user.
    ERL_BIN_DIR="$(mise which erl 2>/dev/null | xargs -r dirname || true)"
    if [[ ! -x "${ERL_BIN_DIR:-}/erl" ]]; then
      ERL_BIN_DIR="$HOME/.local/share/mise/installs/erlang/#{erlang}/bin"
    fi
    log "Linking Erlang binaries from $ERL_BIN_DIR"
    for bin in erl erlc escript epmd; do
      if [[ -x "$ERL_BIN_DIR/$bin" ]]; then
        sudo ln -sfn "$ERL_BIN_DIR/$bin" "/usr/local/bin/$bin"
      fi
    done
    """
  end

  defp gleam_version(%AppManifest{gleam_version: version})
       when is_binary(version) and version != "",
       do: version

  defp gleam_version(%AppManifest{}), do: @default_gleam_version

  defp project_cd(%AppManifest{build_dir: dir}) when is_binary(dir) and dir != "" do
    """
    log "Using Gleam project in #{dir}"
    cd #{shell_escape(dir)}
    """
  end

  defp project_cd(%AppManifest{}) do
    """
    if [[ ! -f gleam.toml ]]; then
      nested=$(find . -maxdepth 2 -name gleam.toml | head -1)
      if [[ -n "$nested" ]]; then
        log "Using Gleam project in $(dirname "$nested")"
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
    log "Exporting Erlang shipment"
    gleam deps download
    gleam export erlang-shipment
    """
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
