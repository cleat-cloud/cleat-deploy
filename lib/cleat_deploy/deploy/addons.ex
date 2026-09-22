defmodule CleatDeploy.Deploy.Addons do
  @moduledoc """
  Managed datastores declared in `.cleat_deploy/deploy.json` (`addons`).

  Everything is native — apt packages plus systemd services, no containers: one
  PostgreSQL cluster and one Redis instance per server, with a role + database
  (Postgres) and an ACL user (Redis) per app. The panel owns the credentials: it
  generates them, stores them encrypted as app env vars and injects
  `DATABASE_URL` / `REDIS_URL` through the app env file, so units, release
  commands and migrations all see them.

  Data lives in the distro's service directories (`/var/lib/postgresql/…`,
  `/var/lib/redis`), outside `release_path`, so it survives deploys.

  Declaring an addon hands its env var to Cleat: an existing value is only reused
  when it is one of ours (it parses back to the same shape), otherwise the addon
  overwrites it. To point at your own database, do not declare the addon.
  """

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest

  @postgres "postgres:pgvector"
  @redis "redis"

  @postgres_port 5432
  @redis_port 6379
  @redis_databases 16

  @callback run(App.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}

  @doc "Env var each addon injects."
  def env_var(@postgres), do: "DATABASE_URL"
  def env_var(@redis), do: "REDIS_URL"

  @doc "Addons supported by this module."
  def known, do: [@postgres, @redis]

  @doc """
  Resolves the addons declared in a manifest, generating and persisting
  credentials for the ones that do not have a usable env var yet.

  Returns `{addons, credentials}`; credentials is keyed by addon and is what the
  provision script needs to create the role/user.
  """
  def ensure(%App{} = app, %AppManifest{} = manifest) do
    addons = AppManifest.addons(manifest)

    credentials =
      Enum.reduce(addons, %{}, fn addon, credentials ->
        Map.put(credentials, addon, ensure_credential(app, addon))
      end)

    {addons, credentials}
  end

  defp ensure_credential(%App{} = app, addon) do
    case parse_credential_from_env(app, addon) do
      %{} = credential ->
        credential

      nil ->
        credential = new_credential(app, addon)
        persist(app, addon, credential)
        credential
    end
  end

  @doc """
  Rotates the credentials of the given addons: a new password is stored in the app
  env var, and the provision script (next deploy) applies it on the server.
  """
  def rotate(%App{} = app, addons) when is_list(addons) do
    credentials =
      Enum.reduce(addons, %{}, fn addon, credentials ->
        credential = new_credential(app, addon)
        persist(app, addon, credential)
        Map.put(credentials, addon, credential)
      end)

    {addons, credentials}
  end

  defp persist(%App{} = app, addon, credential) do
    {:ok, _} = Apps.put_env_var(app, env_var(addon), credential.url)
    app
  end

  @doc """
  Idempotent provisioning script for the addons of an app, run on every deploy
  (after the units are written, before the release command). Empty when the app
  declares none.
  """
  def provision_script(%App{}, config, %AppManifest{} = manifest) do
    credentials = Map.get(config, :addon_credentials, %{})

    manifest
    |> AppManifest.addons()
    |> Enum.map_join("\n\n", fn addon ->
      case Map.get(credentials, addon) do
        nil -> ""
        credential -> provision_step(addon, credential)
      end
    end)
    |> String.trim()
  end

  defp provision_step(@postgres, %{user: user, password: password, database: database}) do
    [
      "log \"Provisioning addon #{@postgres} (database #{database})\"",
      postgres_install_script(),
      postgres_role_script(user, password, database)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp provision_step(@redis, %{user: user, password: password, database: database}) do
    """
    log "Provisioning addon #{@redis} (user #{user})"
    #{redis_install_script()}
    sudo redis-cli ACL SETUSER #{user} on >#{password} ~* +@all > /dev/null
    log "Redis user #{user} ready (database #{database})"
    """
    |> String.trim()
  end

  defp postgres_install_script do
    """
    if ! command -v psql >/dev/null 2>&1; then
      log "Installing PostgreSQL"
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib
    fi

    PG_VERSION="$(ls /etc/postgresql 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -z "$PG_VERSION" ]]; then
      echo "PostgreSQL is installed but no cluster was found in /etc/postgresql" >&2
      exit 1
    fi

    if ! dpkg -s "postgresql-${PG_VERSION}-pgvector" >/dev/null 2>&1; then
      log "Installing pgvector for PostgreSQL ${PG_VERSION}"
      if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "postgresql-${PG_VERSION}-pgvector"; then
        echo "pgvector is not packaged as postgresql-${PG_VERSION}-pgvector on this distribution" >&2
        exit 1
      fi
    fi

    PG_CONF="/etc/postgresql/${PG_VERSION}/main/conf.d/cleat.conf"
    PG_WANT="shared_preload_libraries = 'pg_stat_statements'"
    if [[ "$(sudo cat "$PG_CONF" 2>/dev/null || true)" != "$PG_WANT" ]]; then
      log "Enabling pg_stat_statements"
      sudo mkdir -p "/etc/postgresql/${PG_VERSION}/main/conf.d"
      printf '%s\\n' "$PG_WANT" | sudo tee "$PG_CONF" > /dev/null
      sudo systemctl restart postgresql
    fi

    sudo systemctl enable postgresql >/dev/null 2>&1 || true
    sudo systemctl is-active --quiet postgresql || sudo systemctl start postgresql
    """
    |> String.trim()
  end

  # Identifiers are generated by `db_identifier/1` (lower-case letters, digits and
  # underscore) and passwords are URL-safe base64, so neither can break out of
  # the quoting below.
  defp postgres_role_script(user, password, database) do
    """
    if [[ "$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '#{user}'")" != "1" ]]; then
      sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE #{user} LOGIN PASSWORD '#{password}'"
    else
      sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE #{user} WITH LOGIN PASSWORD '#{password}'"
    fi

    if [[ "$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '#{database}'")" != "1" ]]; then
      sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE #{database} OWNER #{user}"
    fi

    sudo -u postgres psql -v ON_ERROR_STOP=1 -d #{database} -c "CREATE EXTENSION IF NOT EXISTS vector"
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d #{database} -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
    """
    |> String.trim()
  end

  defp redis_install_script do
    """
    if ! command -v redis-server >/dev/null 2>&1; then
      log "Installing Redis"
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server
    fi

    sudo systemctl enable redis-server >/dev/null 2>&1 || true
    sudo systemctl is-active --quiet redis-server || sudo systemctl start redis-server
    """
    |> String.trim()
  end

  @doc """
  Best-effort removal of the app's database/role (Postgres) or ACL user (Redis),
  used when the app is deleted.
  """
  def teardown_script(%App{} = app, addon) do
    credential = parse_credential_from_env(app, addon) || new_credential(app, addon)

    case addon do
      @postgres ->
        """
        if command -v psql >/dev/null 2>&1; then
          sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS #{credential.database}" >/dev/null 2>&1 || true
          sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS #{credential.user}" >/dev/null 2>&1 || true
        fi
        """

      @redis ->
        """
        if command -v redis-cli >/dev/null 2>&1; then
          sudo redis-cli ACL DELUSER #{credential.user} >/dev/null 2>&1 || true
        fi
        """
    end
    |> String.trim()
  end

  @doc """
  Shell snippet reporting the state of the addons: `CLEAT addon <addon> <state>
  <detail>` per line, where state is `ready` when the datastore answers.
  """
  def status_script(%App{} = app, addons) do
    addons
    |> Enum.map_join("\n\n", fn addon ->
      credential = parse_credential_from_env(app, addon) || new_credential(app, addon)
      status_step(addon, credential)
    end)
    |> String.trim()
  end

  defp status_step(@postgres, %{user: user, database: database}) do
    """
    PG_STATE="$(systemctl is-active postgresql 2>/dev/null || true)"
    if command -v psql >/dev/null 2>&1 && [[ "$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '#{database}'" 2>/dev/null || true)" == "1" ]]; then
      printf 'CLEAT addon %s ready %s\\n' '#{@postgres}' '#{database}'
    else
      printf 'CLEAT addon %s %s %s\\n' '#{@postgres}' "${PG_STATE:-missing}" '#{user}'
    fi
    """
    |> String.trim()
  end

  defp status_step(@redis, %{user: user}) do
    """
    REDIS_STATE="$(systemctl is-active redis-server 2>/dev/null || true)"
    if command -v redis-cli >/dev/null 2>&1 && sudo redis-cli ACL LIST 2>/dev/null | grep -q '#{user}'; then
      printf 'CLEAT addon %s ready %s\\n' '#{@redis}' '#{user}'
    else
      printf 'CLEAT addon %s %s %s\\n' '#{@redis}' "${REDIS_STATE:-missing}" '#{user}'
    fi
    """
    |> String.trim()
  end

  @doc "Parses the output of `status_script/2`."
  def parse_status(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(String.trim(line), " ") do
        ["CLEAT", "addon", addon, state, detail] ->
          Map.put(acc, addon, %{state: state, detail: detail})

        _ ->
          acc
      end
    end)
  end

  @doc """
  Probes the addons on the server in a background task and sends
  `{:addon_status, ref, result}` to `pid` (same contract as the other probes).
  """
  def probe_async(pid, ref, %App{} = app, addons) when is_pid(pid) do
    Task.start(fn -> send(pid, {:addon_status, ref, status(app, addons)}) end)
  end

  @doc "Runs the status probe synchronously."
  def status(%App{} = app, addons) do
    case client().run(app, ["bash", "-lc", status_script(app, addons)]) do
      {:ok, output} -> {:ok, parse_status(output)}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp client do
    Application.get_env(:cleat_deploy, :addons, CleatDeploy.Deploy.AddonsSsh)
  end

  defp format_error(reason) when is_binary(reason), do: String.trim(reason)
  defp format_error(reason), do: inspect(reason)

  # --- credentials --------------------------------------------------------

  defp new_credential(%App{} = app, @postgres) do
    user = db_identifier(app)

    build_credential(
      "postgres",
      user,
      user,
      @postgres_port,
      "#{@postgres}/#{user}"
    )
  end

  defp new_credential(%App{} = app, @redis) do
    user = db_identifier(app)
    database = :erlang.phash2({app.id, app.slug}, @redis_databases)
    build_credential("redis", user, to_string(database), @redis_port, "#{@redis}/#{user}")
  end

  defp build_credential(scheme, user, database, port, description) do
    password = generate_password()

    %{
      user: user,
      password: password,
      database: database,
      description: description,
      url: "#{scheme}://#{user}:#{password}@127.0.0.1:#{port}/#{database}"
    }
  end

  # PostgreSQL identifiers and Redis user names live inside the 63 byte limit of
  # Postgres and stay in the safe alphabet (no quoting needed downstream).
  defp db_identifier(%App{slug: slug}) do
    slug
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.downcase()
    |> String.slice(0, 40)
    |> then(&"cleat_#{&1}")
  end

  defp generate_password do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Recovers the credentials from a URL this module generated. Returns `:error` when
  the URL does not look like one of ours (e.g. someone else's database).
  """
  def parse_credential(url, addon, _app) when is_binary(url) do
    with %URI{userinfo: userinfo, host: host, path: path} <- URI.parse(url),
         true <- is_binary(userinfo) and String.contains?(userinfo, ":"),
         [user, password] <- String.split(userinfo, ":", parts: 2),
         true <- scheme_matches?(url, addon),
         true <- host in [nil, "127.0.0.1", "localhost"],
         database when is_binary(database) <- String.trim_leading(path || "", "/"),
         true <- database != "" do
      {:ok,
       %{
         user: user,
         password: password,
         database: database,
         description: "#{addon}/#{user}",
         url: url
       }}
    else
      _ -> :error
    end
  end

  def parse_credential(_url, _addon, _app), do: :error

  defp scheme_matches?(url, @postgres), do: String.starts_with?(url, "postgres")
  defp scheme_matches?(url, @redis), do: String.starts_with?(url, "redis")

  defp parse_credential_from_env(%App{} = app, addon) do
    with url when is_binary(url) <- Apps.env_map(app) |> Map.get(env_var(addon)),
         {:ok, credential} <- parse_credential(url, addon, app) do
      credential
    else
      _ -> nil
    end
  end
end
