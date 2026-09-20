defmodule CleatDeploy.Deploy.Static do
  @moduledoc """
  Build/publish a static site: optional Node build, then copy the output into
  the release directory. Caddy serves the files directly (no systemd unit).
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.ServerProvision

  @candidate_dirs ~w(dist build public _site out)

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

    log() { printf '==> %s\\n' "$*"; }

    if ! swapon --show | grep -q /swapfile; then
      sudo fallocate -l 2G /swapfile || true
      sudo chmod 600 /swapfile || true
      sudo mkswap /swapfile || true
      sudo swapon /swapfile || true
    fi

    #{node_install()}

    BUILD_DIR="$HOME/cleat_deploy_build_#{sha}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    trap 'rm -rf "$BUILD_DIR"; rm -f #{remote_tar}' EXIT
    tar -xzf #{remote_tar} -C "$BUILD_DIR"
    cd "$BUILD_DIR"

    if [[ -f package.json ]]; then
      log "Installing JS dependencies"
      npm ci || npm install
      if npm run | grep -q " build"; then
        log "Building static site"
        npm run build
      fi
    fi

    #{publish_dir_script(manifest)}

    RELEASE_DIR="#{config.release_path}/releases/build"
    sudo mkdir -p "$RELEASE_DIR"
    sudo rm -rf "${RELEASE_DIR:?}"/*
    sudo cp -a "$PUBLISH_DIR"/. "$RELEASE_DIR/"
    sudo ln -sfn "$RELEASE_DIR" #{config.release_path}/current
    #{ServerProvision.prune_releases_script(config.release_path)}
    sudo chmod -R a+rX #{config.release_path}

    #{ServerProvision.provision_script(app, config, manifest)}
    #{ServerProvision.reload_caddy_script()}
    """
  end

  @doc """
  Publishes an uploaded tarball (git-less drop) as-is: extract and serve.
  No build step, no source detection — the archive root is the site.
  """
  def remote_drop_script(%App{} = app, config, sha, remote_tar, %AppManifest{} = manifest) do
    """
    set -euo pipefail

    log() { printf '==> %s\\n' "$*"; }

    BUILD_DIR="$HOME/cleat_deploy_drop_#{sha}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    trap 'rm -rf "$BUILD_DIR"; rm -f #{remote_tar}' EXIT
    tar -xzf #{remote_tar} -C "$BUILD_DIR"

    RELEASE_DIR="#{config.release_path}/releases/build"
    sudo mkdir -p "$RELEASE_DIR"
    sudo rm -rf "${RELEASE_DIR:?}"/*
    sudo cp -a "$BUILD_DIR"/. "$RELEASE_DIR"/
    sudo ln -sfn "$RELEASE_DIR" #{config.release_path}/current
    #{ServerProvision.prune_releases_script(config.release_path)}
    sudo chmod -R a+rX #{config.release_path}
    rm -rf "$BUILD_DIR"

    #{ServerProvision.provision_script(app, config, manifest)}
    #{ServerProvision.reload_caddy_script()}
    """
  end

  defp node_install do
    """
    if [[ -f package.json ]] && ! command -v npm >/dev/null 2>&1; then
      log "Installing Node.js"
      curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    fi
    """
  end

  defp publish_dir_script(%AppManifest{build_dir: dir}) when is_binary(dir) and dir != "" do
    """
    PUBLISH_DIR="#{dir}"
    if [[ ! -d "$PUBLISH_DIR" ]]; then
      echo "Static output directory not found: $PUBLISH_DIR" >&2
      exit 1
    fi
    log "Publishing $PUBLISH_DIR"
    """
  end

  defp publish_dir_script(%AppManifest{}) do
    """
    PUBLISH_DIR=""
    for candidate in #{Enum.join(@candidate_dirs, " ")}; do
      if [[ -d "$candidate" ]]; then
        PUBLISH_DIR="$candidate"
        break
      fi
    done
    if [[ -z "$PUBLISH_DIR" && -f index.html ]]; then
      PUBLISH_DIR="."
    fi
    if [[ -z "$PUBLISH_DIR" ]]; then
      echo "No static output directory found (looked for #{Enum.join(@candidate_dirs, ", ")}, or index.html at the repo root)" >&2
      exit 1
    fi
    log "Publishing $PUBLISH_DIR"
    """
  end
end
