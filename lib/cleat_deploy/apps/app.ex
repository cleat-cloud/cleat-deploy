defmodule CleatDeploy.Apps.App do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias CleatDeploy.Accounts.Tenant
  alias CleatDeploy.Apps.AppEnvVar
  alias CleatDeploy.Encrypted
  alias CleatDeploy.Servers.Server

  schema "apps" do
    field :name, :string
    field :slug, :string
    field :github_repo, :string
    field :branch, :string, default: "main"
    field :host, :string
    field :port, :integer, default: 4000
    field :systemd_unit, :string
    field :release_path, :string
    field :webhook_secret, Encrypted.Binary
    field :auto_deploy, :boolean, default: true
    field :idle_shutdown_enabled, :boolean, default: false
    field :indexable, :boolean, default: false
    field :deploy_manifest, :map, default: %{}
    field :runtime, :string, default: "phoenix"
    field :runtime_apt_packages, {:array, :string}, default: []
    field :runtime_packages_text, :string, virtual: true

    belongs_to :tenant, Tenant
    belongs_to :server, Server
    has_many :env_vars, AppEnvVar

    timestamps(type: :utc_datetime)
  end

  def changeset(app, attrs) do
    app
    |> cast(attrs, [
      :name,
      :slug,
      :github_repo,
      :branch,
      :host,
      :port,
      :systemd_unit,
      :release_path,
      :webhook_secret,
      :auto_deploy,
      :idle_shutdown_enabled,
      :indexable,
      :runtime,
      :runtime_apt_packages,
      :runtime_packages_text,
      :server_id,
      :tenant_id
    ])
    |> update_change(:host, &normalize_host/1)
    |> validate_required([:name, :slug, :host, :server_id, :tenant_id])
    |> cast_runtime_packages()
    |> put_runtime_packages_text()
    |> validate_branch()
    |> validate_inclusion(:runtime, ["phoenix", "golang", "static", "node", "rails", "rust"])
    |> put_github_repo_default()
    |> validate_repo()
    |> unique_constraint(:slug, name: :apps_tenant_id_slug_index)
    |> unique_constraint(:github_repo, name: :apps_tenant_id_github_repo_branch_index)
    |> unique_constraint(:host, name: :apps_server_id_host_index)
    |> unique_constraint(:port, name: :apps_server_id_port_index)
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> foreign_key_constraint(:server_id)
    |> put_default_webhook_secret()
    |> put_deploy_defaults()
  end

  def branch_changeset(app, attrs) do
    app
    |> cast(attrs, [:branch], empty_values: [])
    |> validate_branch()
  end

  @doc """
  Changeset for deploy settings editable after creation: branch, auto-deploy,
  idle shutdown, indexing, host, port, repo and runtime.

  Changing the runtime re-derives the systemd unit and, for non-phoenix
  runtimes, the data dir default (which depends on the release path), so an app
  registered as `phoenix` by mistake can be corrected to `node`/`golang`/`rails`/`rust`.
  """
  def deploy_settings_changeset(app, attrs) do
    app
    |> cast(
      attrs,
      [
        :branch,
        :auto_deploy,
        :idle_shutdown_enabled,
        :indexable,
        :host,
        :port,
        :github_repo,
        :runtime
      ],
      empty_values: []
    )
    |> update_change(:host, &normalize_host/1)
    |> update_runtime_defaults()
    |> validate_branch()
    |> validate_inclusion(:runtime, ["phoenix", "golang", "static", "node", "rails", "rust"])
    |> validate_required([:auto_deploy])
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_repo()
    |> unique_constraint(:host, name: :apps_server_id_host_index)
    |> unique_constraint(:port, name: :apps_server_id_port_index)
    |> unique_constraint(:github_repo, name: :apps_tenant_id_github_repo_branch_index)
  end

  # Regenerate defaults that are derived from the runtime. Port is untouched.
  defp update_runtime_defaults(%Ecto.Changeset{changes: %{runtime: runtime}} = changeset) do
    slug = get_field(changeset, :slug) || ""

    changeset
    |> put_change(:systemd_unit, default_systemd_unit(slug, runtime))
    |> put_change(:release_path, default_release_path(slug, runtime))
  end

  defp update_runtime_defaults(changeset), do: changeset

  def release_name("trip-planner"), do: "trip_planner_ia"
  def release_name("catalogo"), do: "catalog_platform"
  def release_name("controle-agente-viagens"), do: "controle_agente_viagens_phx"
  # Mix app atom is :festa_platform (not the PaaS slug "decor")
  def release_name("decor"), do: "festa_platform"
  def release_name("gestao-bem-decor"), do: "festa_platform"
  def release_name("pay-core"), do: "pay_core"
  def release_name("pay_core"), do: "pay_core"
  def release_name(slug) when is_binary(slug), do: String.replace(slug, "-", "_")

  def default_systemd_unit(slug, runtime \\ "phoenix")

  def default_systemd_unit(slug, "golang") when is_binary(slug), do: slug
  def default_systemd_unit(slug, "node") when is_binary(slug), do: "node-#{slug}"
  def default_systemd_unit(slug, "rails") when is_binary(slug), do: "rails-#{slug}"
  def default_systemd_unit(slug, "rust") when is_binary(slug), do: "rust-#{slug}"
  def default_systemd_unit(_slug, "static"), do: nil
  def default_systemd_unit("trip-planner", _), do: "trip_planner_ia"
  def default_systemd_unit("decor", _), do: "festa_platform"
  def default_systemd_unit("pay-core", _), do: "pay_core"
  def default_systemd_unit("vexo", _), do: "vexo"
  def default_systemd_unit("assistente", _), do: "assistente"
  def default_systemd_unit(slug, _) when is_binary(slug), do: "phx-#{slug}"

  def default_release_path(slug, runtime \\ "phoenix")

  def default_release_path(slug, "golang") when is_binary(slug), do: "/opt/#{slug}"
  def default_release_path(slug, "node") when is_binary(slug), do: "/opt/#{slug}"
  def default_release_path(slug, "rails") when is_binary(slug), do: "/opt/#{slug}"
  def default_release_path(slug, "rust") when is_binary(slug), do: "/opt/#{slug}"
  def default_release_path(slug, "static") when is_binary(slug), do: "/var/www/#{slug}"
  def default_release_path("trip-planner", _), do: "/opt/trip_planner_ia"
  def default_release_path("decor", _), do: "/opt/festa_platform"
  def default_release_path("pay-core", _), do: "/opt/pay_core"
  def default_release_path(slug, _) when is_binary(slug), do: "/opt/#{release_name(slug)}"

  def main_language(%__MODULE__{runtime: runtime}), do: main_language(runtime)
  def main_language("golang"), do: "Go"
  def main_language("static"), do: "Static"
  def main_language("node"), do: "JavaScript"
  def main_language("rails"), do: "Ruby"
  def main_language("rust"), do: "Rust"
  def main_language(_runtime), do: "Elixir"

  def deploy_config(%__MODULE__{} = app) do
    release_path = app.release_path || default_release_path(app.slug)
    basename = release_path |> Path.basename()

    %{
      release_path: release_path,
      systemd_unit: app.systemd_unit || default_systemd_unit(app.slug),
      release_name: release_name(app.slug),
      env_file: "/etc/#{basename}/env"
    }
  end

  @doc """
  systemd unit this app runs under, derived from the slug when the column is
  blank.
  """
  def unit_name(%__MODULE__{systemd_unit: unit}) when is_binary(unit) and unit != "", do: unit

  def unit_name(%__MODULE__{} = app) do
    default_systemd_unit(app.slug, app.runtime || "phoenix")
  end

  @doc """
  Every systemd unit of this app: the base one (the HTTP process) plus one per
  extra process recorded by the last deploy (`<unit>-<process>`).
  """
  def unit_names(%__MODULE__{} = app) do
    base = unit_name(app)

    case base do
      nil -> []
      base -> [base | Enum.map(extra_units(app), &"#{base}-#{&1}")]
    end
  end

  @doc """
  Extra process suffixes of this app, as recorded by the last deploy.

  Go apps deployed before the manifest was recorded fall back to the `-worker`
  convention of the Go runtime.
  """
  def extra_units(%__MODULE__{deploy_manifest: manifest} = app) when is_map(manifest) do
    case Map.get(manifest, "units") do
      [_ | _] = units -> Enum.filter(units, &is_binary/1)
      _ -> legacy_extra_units(app)
    end
  end

  def extra_units(%__MODULE__{} = app), do: legacy_extra_units(app)

  defp legacy_extra_units(%__MODULE__{runtime: "golang"}), do: ["worker"]
  defp legacy_extra_units(%__MODULE__{}), do: []

  @doc """
  Changeset for the manifest summary the deploy runner records: which extra
  units exist and which addons are declared.
  """
  def deploy_manifest_changeset(%__MODULE__{} = app, summary) when is_map(summary) do
    manifest = %{
      "units" => summary |> Map.get(:units, []) |> Enum.filter(&is_binary/1),
      "addons" => summary |> Map.get(:addons, []) |> Enum.filter(&is_binary/1),
      "wake" => summary[:wake] == true
    }

    change(app, deploy_manifest: manifest)
  end

  @doc """
  Whether the last deploy armed wake-on-request for this app.

  A deploy only arms it when the app has the flag on, is not a static site and
  does not bring its own Caddyfile, so the flag alone says nothing about how a
  hibernated app comes back.
  """
  def wake_armed?(%__MODULE__{deploy_manifest: manifest}) when is_map(manifest) do
    Map.get(manifest, "wake") == true
  end

  def wake_armed?(%__MODULE__{}), do: false

  @doc "Addons declared by the last deploy (canonical names)."
  def deploy_addons(%__MODULE__{deploy_manifest: manifest}) when is_map(manifest) do
    manifest |> Map.get("addons", []) |> Enum.filter(&is_binary/1)
  end

  def deploy_addons(%__MODULE__{}), do: []

  @doc """
  Persistent directory for runtime data (e.g. an embedded SQLite database).

  Lives outside the release directory so it survives deploys. Injected into the
  app's systemd unit as `CLEAT_DATA_DIR`. `nil` for static sites.
  """
  def data_dir(%__MODULE__{runtime: "static"}), do: nil

  def data_dir(%__MODULE__{} = app) do
    release_path = app.release_path || default_release_path(app.slug, app.runtime)
    data_dir_for(app.runtime, release_path)
  end

  defp data_dir_for("phoenix", release_path), do: "/var/lib/#{Path.basename(release_path)}"
  defp data_dir_for(_runtime, release_path), do: "#{release_path}/data"

  # Static apps can exist without a git repo (git-less `cleat drop` deploys).
  # The column is NOT NULL, so a blank repo is stored as "".
  defp put_github_repo_default(changeset) do
    if get_field(changeset, :runtime) == "static" and
         get_field(changeset, :github_repo) in [nil, ""] do
      put_change(changeset, :github_repo, "")
    else
      changeset
    end
  end

  defp validate_repo(changeset) do
    case get_field(changeset, :github_repo) do
      blank when blank in [nil, ""] ->
        if get_field(changeset, :runtime) == "static" do
          changeset
        else
          add_error(changeset, :github_repo, "can't be blank")
        end

      _repo ->
        validate_format(changeset, :github_repo, ~r/^[^\/]+\/[^\/]+$/,
          message: "must be owner/repo"
        )
    end
  end

  defp put_deploy_defaults(changeset) do
    case get_field(changeset, :slug) do
      slug when is_binary(slug) and slug != "" ->
        runtime = get_field(changeset, :runtime) || "phoenix"

        changeset
        |> put_default(:systemd_unit, default_systemd_unit(slug, runtime))
        |> put_default(:release_path, default_release_path(slug, runtime))

      _ ->
        changeset
    end
  end

  defp put_default(changeset, field, default) do
    if get_field(changeset, field) in [nil, ""] do
      put_change(changeset, field, default)
    else
      changeset
    end
  end

  defp validate_branch(changeset) do
    changeset
    |> normalize_branch()
    |> validate_required([:branch])
    |> validate_length(:branch, min: 1, max: 255)
    |> validate_format(:branch, ~r/^(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._\/-]*$/,
      message: "must be a git branch name"
    )
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalize_branch(changeset) do
    case get_change(changeset, :branch) do
      branch when is_binary(branch) ->
        normalized =
          branch
          |> String.trim()
          |> String.replace_prefix("refs/heads/", "")

        cond do
          normalized == "" ->
            add_error(changeset, :branch, "can't be blank")

          normalized != branch ->
            put_change(changeset, :branch, normalized)

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp put_default_webhook_secret(changeset) do
    if get_field(changeset, :webhook_secret) in [nil, ""] do
      put_change(changeset, :webhook_secret, Base.url_encode64(:crypto.strong_rand_bytes(24)))
    else
      changeset
    end
  end

  defp cast_runtime_packages(changeset) do
    case get_change(changeset, :runtime_packages_text) do
      nil ->
        changeset

      text ->
        packages =
          text
          |> String.split(~r/[\s,]+/, trim: true)
          |> Enum.reject(&(&1 == ""))

        changeset
        |> put_change(:runtime_apt_packages, packages)
        |> delete_change(:runtime_packages_text)
    end
  end

  defp put_runtime_packages_text(changeset) do
    packages = get_field(changeset, :runtime_apt_packages) || []

    put_change(
      changeset,
      :runtime_packages_text,
      Enum.join(packages, "\n")
    )
  end
end
