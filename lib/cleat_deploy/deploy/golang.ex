defmodule CleatDeploy.Deploy.Golang do
  @moduledoc false

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
    binaries = binaries(manifest)
    worker_units = Enum.reject(binaries, &(&1 == "server"))

    build_cmds =
      Enum.map_join(binaries, "\n", fn bin ->
        source = source_package(bin)

        """
        log "Building #{bin} (#{source})"
        go build -o bin/#{bin} #{source}
        """
      end)

    restart_cmds =
      [config.systemd_unit | Enum.map(worker_units, &"#{config.systemd_unit}-#{&1}")]
      |> Enum.map_join("\n", fn unit ->
        """
        log "Restarting #{unit}"
        sudo systemctl restart #{unit}
        sleep 1
        if sudo systemctl is-active --quiet #{unit}; then
          log "Service #{unit} is active"
        else
          sudo journalctl -u #{unit} -n 30 --no-pager
          exit 1
        fi
        """
      end)

    """
    set -euo pipefail

    log() { printf '==> %s\\n' "$*"; }

    if ! swapon --show | grep -q /swapfile; then
      sudo fallocate -l 4G /swapfile || true
      sudo chmod 600 /swapfile || true
      sudo mkswap /swapfile || true
      sudo swapon /swapfile || true
    fi

    export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
    GO_VER="1.26.4"
    if ! command -v go >/dev/null 2>&1 || ! go version | grep -qE 'go1\\.(2[6-9]|[3-9][0-9])'; then
      log "Installing Go ${GO_VER}"
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar build-essential
      curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -o /tmp/go.tgz
      sudo rm -rf /usr/local/go
      sudo tar -C /usr/local -xzf /tmp/go.tgz
      export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
    fi

    if [[ -f package.json ]] && ! command -v npm >/dev/null 2>&1; then
      log "Installing Node.js"
      curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    fi

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
        log "Building frontend assets"
        npm run build
      fi
    fi

    mkdir -p bin
    #{build_cmds}

    RELEASE_DIR="#{config.release_path}/releases/build"
    sudo mkdir -p "$RELEASE_DIR/bin" #{config.release_path}/data
    sudo rm -rf "${RELEASE_DIR:?}/bin"/*
    sudo cp -a bin/. "$RELEASE_DIR/bin/"
    if [[ -d web/static ]]; then
      sudo rm -rf "$RELEASE_DIR/web"
      sudo mkdir -p "$RELEASE_DIR/web"
      sudo cp -a web/static "$RELEASE_DIR/web/"
    fi
    sudo ln -sfn "$RELEASE_DIR" #{config.release_path}/current

    #{ServerProvision.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Ssh.env_sync_script(app, config)}

    #{restart_cmds}
    #{ServerProvision.reload_caddy_script()}
    """
  end

  defp binaries(%AppManifest{binaries: bins}) when is_list(bins) and bins != [], do: bins
  defp binaries(_), do: ["server"]

  defp source_package("server"), do: "./cmd/server"
  defp source_package("worker"), do: "./cmd/worker"
  defp source_package(bin) when is_binary(bin), do: "./cmd/#{bin}"
end
