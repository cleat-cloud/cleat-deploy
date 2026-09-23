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

    #{node_and_js(manifest, config)}

    #{assets_step(config)}

    #{migrate_step(manifest)}

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
    #{ServerProvision.extra_start_commands(manifest, config)}
    [[ -n "$TMP_ENV" ]] && rm -f "$TMP_ENV" || true

    #{ServerProvision.provision_script(app, config, manifest)}
    #{CleatDeploy.Deploy.Addons.provision_script(app, config, manifest)}
    #{ServerProvision.release_command_script(app, config, manifest)}

    #{ServerProvision.restart_units_script(config, manifest)}

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
      libffi-dev libgdbm-dev libgmp-dev libpq-dev libsqlite3-dev pkg-config
    mise install "ruby@${RUBY_VERSION}"
    mise use -g "ruby@${RUBY_VERSION}"

    # The app runs as root (the units and the release command) while mise
    # installs the toolchain under the build user's home, so expose the
    # interpreter where any user finds it. `bundle` is a ruby script, so ruby
    # has to be on the PATH as well — the gems themselves live in the release
    # (`.bundle/config` pins BUNDLE_PATH to vendor/bundle).
    RUBY_BIN="$(dirname "$(mise which ruby 2>/dev/null || true)")"
    if [[ -n "$RUBY_BIN" && -d "$RUBY_BIN" ]]; then
      for bin in ruby gem irb rake bundle bundler; do
        if [[ -x "$RUBY_BIN/$bin" ]]; then
          sudo ln -sfn "$RUBY_BIN/$bin" "/usr/local/bin/$bin"
        fi
      done
    fi

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

  # Node for the asset pipeline (Vite/Sprockets both need it). Major comes from
  # deploy.json `node_version`, then the package.json `engines.node` range, then
  # the default. The package manager follows the lockfile, and every cache lives
  # under the app data dir so a redeploy does not re-download the world.
  defp node_and_js(%AppManifest{} = manifest, config) do
    build_cache = "#{config.release_path}/data/build-cache"

    """
    if [[ -f package.json ]]; then
      # `engines.node` is the only hint a fresh VM has before Node exists, so it
      # cannot be read with node itself.
      package_json_node_major() {
        command -v python3 >/dev/null 2>&1 || return 0
        python3 -c 'import json,re;e=json.load(open("package.json")).get("engines") or {};m=re.search(r"(\\d+)",str(e.get("node","")));print(m.group(1) if m else "")' 2>/dev/null || true
      }

      # corepack ships with Node but writes its shims into the Node install dir,
      # so it needs root; and it is not always there (or the version in
      # packageManager cannot be fetched) — a global npm install is the fallback.
      enable_package_manager() {
        sudo corepack enable >/dev/null 2>&1 || true
        command -v "$1" >/dev/null 2>&1 || sudo npm install -g "$1" >/dev/null 2>&1 || true
      }

      NODE_MAJOR=#{shell_escape(manifest.node_version || "")}
      if [[ -z "$NODE_MAJOR" ]]; then
        NODE_MAJOR="$(package_json_node_major)"
      fi
      NODE_MAJOR="${NODE_MAJOR:-#{@default_node_version}}"
      INSTALLED_MAJOR="$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v' || true)"

      if [[ "$INSTALLED_MAJOR" != "$NODE_MAJOR" ]]; then
        log "Installing Node.js ${NODE_MAJOR}.x"
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
      fi

      BUILD_CACHE=#{shell_escape(build_cache)}
      sudo mkdir -p "$BUILD_CACHE/npm" "$BUILD_CACHE/yarn" "$BUILD_CACHE/pnpm" "$BUILD_CACHE/vite"
      sudo chown -R "$(id -u):$(id -g)" "$BUILD_CACHE" 2>/dev/null || true
      export NPM_CONFIG_CACHE="$BUILD_CACHE/npm"
      export YARN_CACHE_FOLDER="$BUILD_CACHE/yarn"
      export NPM_CONFIG_STORE_DIR="$BUILD_CACHE/pnpm"
      export NODE_ENV=production
      # The clone has no .git, so a `husky install` in the app's prepare script
      # only produces a failure nobody can act on.
      export HUSKY=0

      if [[ -f yarn.lock ]]; then
        enable_package_manager yarn
        log "Installing JS dependencies (yarn)"
        yarn install --frozen-lockfile || yarn install
      elif [[ -f pnpm-lock.yaml ]]; then
        enable_package_manager pnpm
        log "Installing JS dependencies (pnpm)"
        pnpm install --frozen-lockfile || pnpm install
      elif [[ -f package-lock.json ]]; then
        log "Installing JS dependencies (npm ci)"
        npm ci --no-audit --no-fund || npm install
      else
        log "Installing JS dependencies (npm)"
        npm install
      fi
    fi
    """
  end

  # Keeps Vite's own cache between deploys: without it every deploy rebuilds the
  # whole asset graph from scratch.
  defp assets_step(config) do
    """
    if [[ -f app/assets/config/manifest.js || -d app/assets || -d app/javascript || -f config/importmap.rb || -f package.json ]]; then
      BUILD_CACHE=#{shell_escape("#{config.release_path}/data/build-cache")}
      if [[ ! -L tmp/cache/vite ]]; then
        # Only the cache in the data dir needs root; creating the one inside the
        # build tree with sudo would leave it owned by root and break the
        # symlink below (and the cleanup after the build).
        sudo mkdir -p "$BUILD_CACHE/vite"
        sudo chown -R "$(id -u):$(id -g)" "$BUILD_CACHE/vite" 2>/dev/null || true
        mkdir -p tmp/cache
        ln -sfn "$BUILD_CACHE/vite" tmp/cache/vite
      fi
      # Node's default heap (~2 GB) is not enough for a big asset graph: a Vite
      # build of a large app dies with "JavaScript heap out of memory". An app
      # that ships its own NODE_OPTIONS in the env keeps it.
      export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}"
      log "Precompiling assets"
      run_rails bundle exec rails assets:precompile
    else
      log "No asset pipeline detected; skipping assets:precompile"
    fi
    """
  end

  # `db:prepare` is the runtime's default migration step; an explicit
  # release_command replaces it (e.g. `rails db:chatwoot_prepare`).
  defp migrate_step(%AppManifest{} = manifest) do
    if AppManifest.release_commands(manifest) == [] do
      """
      if [[ -f config/database.yml ]]; then
        log "Preparing database (db:prepare)"
        run_rails bundle exec rails db:prepare
      else
        log "No database.yml found; skipping db:prepare"
      fi
      """
      |> String.trim()
    else
      """
      log "Skipping db:prepare (release_command is set in .cleat_deploy/deploy.json)"
      """
      |> String.trim()
    end
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
