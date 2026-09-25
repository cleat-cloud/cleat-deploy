defmodule CleatDeploy.Deploy.Ssh.Phoenix do
  @moduledoc false

  alias CleatDeploy.Deploy.{AppManifest, ServerProvision}

  def phoenix_remote_build_script(server, app, config, sha, remote_tar, runtime, manifest) do
    packages_install =
      case runtime.packages do
        [] ->
          ""

        packages ->
          """
          log "Installing runtime packages: #{Enum.join(packages, " ")}"
          sudo DEBIAN_FRONTEND=noninteractive apt-get update
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y #{Enum.join(packages, " ")}
          """
      end

    post_install_script =
      case runtime.post_install do
        [] -> ""
        steps -> Enum.map_join(steps, "\n", & &1) <> "\n"
      end

    """
    set -euo pipefail

    log() { printf '==> %s\\n' "$*"; }

    #{packages_install}#{post_install_script}
    if ! swapon --show | grep -q /swapfile; then
      sudo fallocate -l 2G /swapfile || true
      sudo chmod 600 /swapfile || true
      sudo mkswap /swapfile || true
      sudo swapon /swapfile || true
    fi

    if ! command -v mise >/dev/null 2>&1; then
      log "Installing mise + Erlang/Elixir"
      sudo apt-get update
      sudo apt-get install -y curl build-essential git ca-certificates
      curl -fsSL https://mise.run | sh
    fi

    export PATH="/home/#{server.ssh_user}/.local/bin:$PATH"
    eval "$(/home/#{server.ssh_user}/.local/bin/mise activate bash)"
    mise install erlang@28.4.1 elixir@1.19.5-otp-28
    mise use -g erlang@28.4.1 elixir@1.19.5-otp-28

    BUILD_DIR="$HOME/cleat_deploy_build_#{sha}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    trap 'rm -rf "$BUILD_DIR"; rm -f #{remote_tar}' EXIT
    tar -xzf #{remote_tar} -C "$BUILD_DIR"
    cd "$BUILD_DIR"
    #{mix_project_cd(manifest)}

    export MIX_ENV=prod
    export SECRET_KEY_BASE=buildtime_secret_key_base_32chars_min
    export TURSO_DATABASE_URL=libsql://build.turso.io
    export TURSO_AUTH_TOKEN=build_token

    log "Fetching dependencies"
    mix local.hex --force
    mix local.rebar --force
    mix deps.get --only prod

    log "Compiling application"
    mix compile

    log "Compiling assets"
    mix assets.setup
    mix assets.deploy

    log "Building release #{config.release_name} (slug=#{app.slug})"
    mix release --overwrite

    REL_DIR="_build/prod/rel/#{config.release_name}"
    if [[ ! -d "$REL_DIR" ]]; then
      echo "Release directory missing: $REL_DIR" >&2
      echo "Available releases:" >&2
      ls -la _build/prod/rel 2>/dev/null || true
      echo "Hint: set release_name in .cleat_deploy/deploy.json to the Mix app atom (see mix.exs app:)." >&2
      exit 1
    fi

    RELEASE_DIR="#{config.release_path}/releases/build"
    sudo mkdir -p "$RELEASE_DIR"
    sudo rm -rf "${RELEASE_DIR:?}"/*
    sudo cp -a "$REL_DIR/." "$RELEASE_DIR/"
    sudo ln -sfn "$RELEASE_DIR" #{config.release_path}/current
    #{ServerProvision.prune_releases_script(config.release_path)}

    #{ServerProvision.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Addons.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Ssh.Env.env_sync_script(app, config)}
    #{migrate_script(app, config, manifest)}
    #{ServerProvision.release_command_script(app, config, manifest)}

    log "Restarting #{config.systemd_unit}"
    sudo systemctl restart #{config.systemd_unit}
    sleep 2

    if sudo systemctl is-active --quiet #{config.systemd_unit}; then
      log "Service #{config.systemd_unit} is active"
    else
      sudo journalctl -u #{config.systemd_unit} -n 30 --no-pager
      exit 1
    fi

    #{ServerProvision.reload_caddy_script()}
    """
  end

  # A release_command takes over the migration slot: it is the app's own
  # post-publish step, so the built-in Ecto migrate must not run as well.
  defp migrate_script(_app, config, %AppManifest{} = manifest) do
    if AppManifest.release_commands(manifest) == [] do
      ServerProvision.migrate_script(config)
    else
      ""
    end
  end

  defp mix_project_cd(%AppManifest{build_dir: dir}) when is_binary(dir) and dir != "" do
    """
    log "Using mix project in #{dir}"
    cd #{dir}
    """
  end

  defp mix_project_cd(%AppManifest{}) do
    """
    if [[ ! -f mix.exs ]]; then
      nested=$(find . -maxdepth 2 -name mix.exs | head -1)
      if [[ -n "$nested" ]]; then
        log "Using mix project in $(dirname "$nested")"
        cd "$(dirname "$nested")"
      fi
    fi
    """
  end
end
