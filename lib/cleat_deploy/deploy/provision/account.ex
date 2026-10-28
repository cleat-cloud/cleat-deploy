defmodule CleatDeploy.Deploy.Provision.Account do
  @moduledoc """
  Unprivileged system accounts: naming, creation and data-dir ownership.
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Provision.Shell

  @doc """
  Unprivileged system account for an app.

  `cleat-<slug>` when it fits the 32-char login limit; longer slugs keep a short
  digest so two apps sharing a prefix never share an account.
  """
  def service_user(slug) when is_binary(slug) do
    clean = String.replace(slug, ~r/[^A-Za-z0-9_-]/, "-")
    base = "cleat-" <> clean

    if String.length(base) <= 31 do
      base
    else
      digest = :crypto.hash(:sha256, slug) |> Base.encode16(case: :lower) |> String.slice(0, 6)
      "cleat-" <> String.slice(clean, 0, 18) <> "-" <> digest
    end
  end

  def phoenix_service_user(slug), do: service_user(slug)

  @doc "Creates the app account (idempotently) and hands it its data dir."
  def create_script(user, data_dir) do
    """
    if ! getent group #{user} >/dev/null 2>&1; then
      sudo groupadd --system #{user}
    fi
    if ! id -u #{user} >/dev/null 2>&1; then
      sudo useradd --system --gid #{user} --no-create-home --home-dir #{shell_escape(data_dir)} --shell /usr/sbin/nologin #{user}
    fi
    sudo chown -R #{user}:#{user} #{shell_escape(data_dir)}
    sudo chmod 750 #{shell_escape(data_dir)}
    """
    |> String.trim()
  end

  @doc """
  Hands the app's data dir back to its dedicated account.

  Migrations and release commands run as root before the restart, so they can
  create root-owned files (SQLite WAL, uploaded assets) inside the data dir.
  """
  def phoenix_ownership_script(%App{} = app, config, %AppManifest{runtime: "phoenix"} = manifest) do
    data_dir = Shell.data_dir_for(manifest, config)
    user = service_user(app.slug)

    """
    log "Fixing data ownership for #{user}"
    sudo mkdir -p #{shell_escape(data_dir)} #{shell_escape(Path.join(data_dir, "tmp"))}
    sudo chown -R #{user}:#{user} #{shell_escape(data_dir)}
    """
    |> String.trim()
  end

  def phoenix_ownership_script(app, config, manifest),
    do: service_ownership_script(app, config, manifest)

  @doc """
  Hands data (and, for Node/Rails/Rust/Gleam, the release tree) to the app
  account after root-owned migrate/release commands.
  """
  def service_ownership_script(%App{} = app, config, %AppManifest{runtime: runtime} = manifest)
      when runtime in ["node", "rails", "rust", "gleam"] do
    data_dir = Shell.data_dir_for(manifest, config)
    user = service_user(app.slug)

    """
    log "Fixing data ownership for #{user}"
    sudo mkdir -p #{shell_escape(data_dir)} #{shell_escape(Path.join(data_dir, "tmp"))}
    sudo chown -R #{user}:#{user} #{shell_escape(data_dir)}
    sudo chmod 750 #{shell_escape(data_dir)}
    sudo chown -R #{user}:#{user} #{shell_escape(config.release_path)}
    sudo chmod 750 #{shell_escape(config.release_path)}
    """
    |> String.trim()
  end

  def service_ownership_script(_app, _config, _manifest), do: ""

  defp shell_escape(path), do: Shell.shell_escape(path)
end
