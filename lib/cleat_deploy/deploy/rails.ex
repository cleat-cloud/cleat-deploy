defmodule CleatDeploy.Deploy.Rails do
  @moduledoc """
  Build and run a Ruby on Rails app.

  Installs Ruby via mise (honouring `ruby_version` from the manifest, then
  `.ruby-version`, then the Gemfile `ruby` directive), runs `bundle install`,
  `assets:precompile` and `db:prepare`, publishes the project to the release
  directory and keeps it alive with a systemd unit behind the Caddy reverse
  proxy.

  The start command is resolved at build time:

    1. `start_command` from `.cleat_deploy/deploy.json`, if set
    2. `bundle exec puma -C config/puma.rb`, when a Puma config exists
    3. `bundle exec puma -b tcp://0.0.0.0:$PORT`

  `DATABASE_URL`, `SECRET_KEY_BASE`, `RAILS_MASTER_KEY` and friends come from
  the panel's env vars.
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.ServerProvision
  alias CleatDeploy.Deploy.Ssh

  @default_ruby_version "3.3.6"

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

    BUILD_DIR="$HOME/cleat_deploy_build_#{sha}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    trap 'rm -rf "$BUILD_DIR"; rm -f #{remote_tar}' EXIT
    tar -xzf #{remote_tar} -C "$BUILD_DIR"
    cd "$BUILD_DIR"
    #{ruby_install(manifest.ruby_version)}
    #{project_cd(manifest)}

    if [[ ! -f Gemfile ]]; then
      echo "No Gemfile found in the Rails project" >&2
      exit 1
    fi

    #{env_setup(app, config, sha)}

    log "Installing gems"
    bundle config set --local path vendor/bundle
    bundle config set --local without 'development test'
    bundle install --jobs 4 --retry 3

    #{node_and_js()}

    #{assets_step()}

    #{migrate_step()}

    #{start_command_script(manifest.start_command)}

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
    [[ -n "$TMP_ENV" ]] && rm -f "$TMP_ENV" || true

    #{ServerProvision.provision_script(app, config, manifest)}

    log "Restarting #{config.systemd_unit}"
    sudo systemctl restart #{config.systemd_unit}
    sleep 3

    if sudo systemctl is-active --quiet #{config.systemd_unit}; then
      log "Service #{config.systemd_unit} is active"
    else
      sudo journalctl -u #{config.systemd_unit} -n 50 --no-pager
      exit 1
    fi

    #{ServerProvision.reload_caddy_script()}
    """
  end

  defp ruby_install(explicit) do
    override = if explicit in [nil, ""], do: "", else: explicit

    """
    if ! command -v mise >/dev/null 2>&1; then
      log "Installing mise"
      sudo apt-get update
      sudo apt-get install -y curl build-essential git ca-certificates
      curl -fsSL https://mise.run | sh
    fi
    export PATH="$HOME/.local/bin:$PATH"
    eval "$(mise activate bash)"

    RUBY_VERSION="#{override}"
    if [[ -z "$RUBY_VERSION" && -f .ruby-version ]]; then
      RUBY_VERSION="$(tr -d '[:space:]' < .ruby-version | sed 's/^ruby-//')"
    fi
    if [[ -z "$RUBY_VERSION" && -f Gemfile ]]; then
      RUBY_VERSION="$(grep -E '^[[:space:]]*ruby[[:space:]]' Gemfile | grep -Eo '[0-9]+\\.[0-9]+\\.[0-9]+' | head -1 || true)"
    fi
    RUBY_VERSION="${RUBY_VERSION:-#{@default_ruby_version}}"

    log "Installing Ruby ${RUBY_VERSION} (mise)"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \\
      libssl-dev libyaml-dev libreadline-dev zlib1g-dev libncurses-dev \\
      libffi-dev libgdbm-dev libgmp-dev libpq-dev libsqlite3-dev
    mise install "ruby@${RUBY_VERSION}"
    mise use -g "ruby@${RUBY_VERSION}"

    command -v bundle >/dev/null 2>&1 || gem install bundler --no-document
    """
  end

  defp project_cd(%AppManifest{build_dir: dir}) when is_binary(dir) and dir != "" do
    """
    log "Using Rails project in #{dir}"
    cd #{shell_escape(dir)}
    """
  end

  defp project_cd(%AppManifest{}) do
    """
    if [[ ! -f Gemfile ]]; then
      nested=$(find . -maxdepth 2 -name Gemfile -not -path '*/vendor/*' | head -1)
      if [[ -n "$nested" ]]; then
        log "Using Rails project in $(dirname "$nested")"
        cd "$(dirname "$nested")"
      fi
    fi
    """
  end

  # Writes the panel env file, then makes a user-readable copy so build steps
  # (asset precompile, db:prepare) can source DATABASE_URL and friends.
  defp env_setup(app, config, sha) do
    """
    #{Ssh.env_sync_script(app, config)}
    ENV_FILE=#{shell_escape(config.env_file)}
    TMP_ENV=""
    if [[ -f "$ENV_FILE" ]]; then
      TMP_ENV="/tmp/cleat_deploy_env_#{sha}"
      sudo cp "$ENV_FILE" "$TMP_ENV"
      sudo chown "$(id -u):$(id -g)" "$TMP_ENV"
      chmod 600 "$TMP_ENV"
    fi

    run_rails() {
      if [[ -n "$TMP_ENV" && -f "$TMP_ENV" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$TMP_ENV"
        set +a
      fi
      export RAILS_ENV=production
      export SECRET_KEY_BASE="${SECRET_KEY_BASE:-cleat_buildtime_secret_key_base_32chars_min}"
      "$@"
    }
    """
  end

  defp node_and_js do
    """
    if [[ -f package.json ]]; then
      if ! command -v node >/dev/null 2>&1; then
        log "Installing Node.js"
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
      fi
      if [[ -f yarn.lock ]]; then
        corepack enable >/dev/null 2>&1 || true
        log "Installing JS dependencies (yarn)"
        yarn install --frozen-lockfile || yarn install
      else
        log "Installing JS dependencies (npm)"
        npm install
      fi
    fi
    """
  end

  defp assets_step do
    """
    if [[ -f app/assets/config/manifest.js || -d app/assets || -d app/javascript || -f config/importmap.rb || -f package.json ]]; then
      log "Precompiling assets"
      run_rails bundle exec rails assets:precompile
    else
      log "No asset pipeline detected; skipping assets:precompile"
    fi
    """
  end

  defp migrate_step do
    """
    if [[ -f config/database.yml ]]; then
      log "Preparing database (db:prepare)"
      run_rails bundle exec rails db:prepare
    else
      log "No database.yml found; skipping db:prepare"
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
    if [[ -f config/puma.rb ]]; then
      START_CMD='bundle exec puma -C config/puma.rb'
    else
      START_CMD='bundle exec puma -b tcp://0.0.0.0:$PORT'
    fi
    """
    |> String.trim()
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
