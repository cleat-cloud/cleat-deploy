defmodule CleatDeploy.Deploy.Python do
  @moduledoc """
  Build and run a long-lived Python server.

  uv installs a managed CPython into the release (so the unprivileged unit
  does not need the build user's `$HOME`) and syncs the project. The start
  command is resolved at build time:

    1. `start_command` from `.cleat_deploy/deploy.json`, if set
    2. `processes.web`, if declared
    3. `.venv/bin/python main.py`, if `main.py` exists
    4. `.venv/bin/python app.py`, if `app.py` exists
    5. `.venv/bin/python server.py`, if `server.py` exists
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.ServerProvision
  alias CleatDeploy.Deploy.Ssh.CpuLimit

  @default_python_version "3.12"

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
    #{CpuLimit.snippet()}

    if ! swapon --show | grep -q /swapfile; then
      sudo fallocate -l 2G /swapfile || true
      sudo chmod 600 /swapfile || true
      sudo mkswap /swapfile || true
      sudo swapon /swapfile || true
    fi

    export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
    #{uv_install()}

    BUILD_DIR="$HOME/cleat_deploy_build_#{sha}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    trap 'rm -rf "$BUILD_DIR"; rm -f #{remote_tar}' EXIT
    log "Unpacking source"
    tar -xzf #{remote_tar} -C "$BUILD_DIR"
    cd "$BUILD_DIR"
    #{project_cd(manifest)}

    if [[ ! -f pyproject.toml && ! -f requirements.txt && ! -f uv.lock ]]; then
      echo "No pyproject.toml or requirements.txt found in the Python project" >&2
      exit 1
    fi

    #{python_install(manifest.python_version)}
    #{deps_script()}
    #{build_step(manifest.build_command)}
    #{start_command_script(manifest)}

    RELEASE_DIR="#{config.release_path}/releases/build"
    #{ServerProvision.clean_release_script("#{config.release_path}/releases/build")}
    log "Publishing $PWD to $RELEASE_DIR"
    sudo cp -a . "$RELEASE_DIR"/
    sudo ln -sfn "$RELEASE_DIR" #{config.release_path}/current
    #{ServerProvision.prune_releases_script(config.release_path)}

    log "Start command: $START_CMD"
    {
      printf '%s\\n' 'export PATH="$PWD/.venv/bin:$HOME/.local/bin:/usr/local/bin:$PATH"'
      printf '%s' "$START_CMD"
    } | sudo tee "$RELEASE_DIR/start.cmd" > /dev/null
    echo '#{Base.encode64(ServerProvision.start_script())}' | base64 -d | sudo tee "$RELEASE_DIR/start.sh" > /dev/null
    sudo chmod +x "$RELEASE_DIR/start.sh"
    #{ServerProvision.extra_start_commands(manifest, config)}

    #{ServerProvision.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Addons.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Ssh.env_sync_script(app, config)}
    #{ServerProvision.release_command_script(app, config, manifest)}
    #{ServerProvision.service_ownership_script(app, config, manifest)}

    #{ServerProvision.restart_units_script(config, manifest)}

    #{ServerProvision.reload_caddy_script()}

    log "Done in ${SECONDS}s"
    """
  end

  defp uv_install do
    """
    if ! command -v uv >/dev/null 2>&1; then
      log "Installing uv"
      curl -LsSf https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin sh
    fi
    log "uv $(uv --version)"
    """
  end

  defp python_install(version) do
    py = normalize_python_version(version)

    """
    PYTHON_VERSION="#{py}"
    export UV_PYTHON_INSTALL_DIR="$PWD/.cleat-python"
    export UV_PROJECT_ENVIRONMENT="$PWD/.venv"
    log "Installing Python ${PYTHON_VERSION}"
    uv python install "$PYTHON_VERSION"
    """
  end

  defp normalize_python_version(version) when is_binary(version) do
    case Regex.run(~r/(\d+\.\d+)/, String.trim(version)) do
      [_, minor] -> minor
      _ -> @default_python_version
    end
  end

  defp normalize_python_version(_), do: @default_python_version

  # Relocatable: the venv is built in $BUILD_DIR and `cp -a`'d into the
  # release. Absolute shebangs to the build tree would break after the trap
  # deletes it.
  defp deps_script do
    """
    log "Installing Python dependencies"
    uv venv --relocatable --python "$PYTHON_VERSION"
    if [[ -f uv.lock ]]; then
      log "Installing Python dependencies (uv.lock)"
      uv sync --frozen --no-dev --python "$PYTHON_VERSION"
    elif [[ -f pyproject.toml ]]; then
      log "Installing Python dependencies (pyproject.toml)"
      uv sync --no-dev --python "$PYTHON_VERSION"
    elif [[ -f requirements.txt ]]; then
      log "Installing Python dependencies (requirements.txt)"
      uv pip install -r requirements.txt
    fi
    """
  end

  defp project_cd(%AppManifest{build_dir: dir}) when is_binary(dir) and dir != "" do
    """
    log "Using Python project in #{dir}"
    cd #{shell_escape(dir)}
    """
  end

  defp project_cd(%AppManifest{}) do
    """
    if [[ ! -f pyproject.toml && ! -f requirements.txt ]]; then
      nested=$(find . -maxdepth 2 \\( -name pyproject.toml -o -name requirements.txt \\) | head -1)
      if [[ -n "$nested" ]]; then
        log "Using Python project in $(dirname "$nested")"
        cd "$(dirname "$nested")"
      fi
    fi
    """
  end

  defp build_step(command) when is_binary(command) and command != "" do
    """
    log "Building (custom build_command)"
    #{CpuLimit.wrap(command)}
    """
  end

  defp build_step(_) do
    """
    log "No build_command; skipping build"
    """
  end

  defp start_command_script(%AppManifest{start_command: command})
       when is_binary(command) and command != "" do
    """
    START_CMD=#{shell_escape(command)}
    """
    |> String.trim()
  end

  defp start_command_script(%AppManifest{processes: %{"web" => command}})
       when is_binary(command) and command != "" do
    """
    START_CMD=#{shell_escape(command)}
    """
    |> String.trim()
  end

  defp start_command_script(_) do
    """
    if [[ -f main.py ]]; then
      START_CMD=".venv/bin/python main.py"
    elif [[ -f app.py ]]; then
      START_CMD=".venv/bin/python app.py"
    elif [[ -f server.py ]]; then
      START_CMD=".venv/bin/python server.py"
    else
      echo "Could not determine a start command. Add a main.py, app.py, server.py, or set start_command in .cleat_deploy/deploy.json." >&2
      exit 1
    fi
    """
    |> String.trim()
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
