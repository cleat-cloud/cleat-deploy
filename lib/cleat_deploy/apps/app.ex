defmodule CleatDeploy.Apps.App do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias CleatDeploy.Accounts.Tenant
  alias CleatDeploy.Apps.AppEnvVar
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
    field :webhook_secret, :string
    field :auto_deploy, :boolean, default: true
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
      :runtime,
      :runtime_apt_packages,
      :runtime_packages_text,
      :server_id,
      :tenant_id
    ])
    |> validate_required([:name, :slug, :github_repo, :host, :server_id, :tenant_id])
    |> cast_runtime_packages()
    |> put_runtime_packages_text()
    |> validate_branch()
    |> validate_format(:github_repo, ~r/^[^\/]+\/[^\/]+$/, message: "must be owner/repo")
    |> validate_inclusion(:runtime, ["phoenix", "golang", "static"])
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> unique_constraint(:slug, name: :apps_tenant_id_slug_index)
    |> unique_constraint(:github_repo, name: :apps_tenant_id_github_repo_index)
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
  Changeset for deploy settings editable after creation: branch and auto-deploy.
  """
  def deploy_settings_changeset(app, attrs) do
    app
    |> cast(attrs, [:branch, :auto_deploy], empty_values: [])
    |> validate_branch()
    |> validate_required([:auto_deploy])
  end

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
  def default_systemd_unit(_slug, "static"), do: nil
  def default_systemd_unit("trip-planner", _), do: "trip_planner_ia"
  def default_systemd_unit("decor", _), do: "festa_platform"
  def default_systemd_unit("pay-core", _), do: "pay_core"
  def default_systemd_unit("vexo", _), do: "vexo"
  def default_systemd_unit("assistente", _), do: "assistente"
  def default_systemd_unit(slug, _) when is_binary(slug), do: "phx-#{slug}"

  def default_release_path(slug, runtime \\ "phoenix")

  def default_release_path(slug, "golang") when is_binary(slug), do: "/opt/#{slug}"
  def default_release_path(slug, "static") when is_binary(slug), do: "/var/www/#{slug}"
  def default_release_path("trip-planner", _), do: "/opt/trip_planner_ia"
  def default_release_path("decor", _), do: "/opt/festa_platform"
  def default_release_path("pay-core", _), do: "/opt/pay_core"
  def default_release_path(slug, _) when is_binary(slug), do: "/opt/#{release_name(slug)}"

  def main_language(%__MODULE__{runtime: runtime}), do: main_language(runtime)
  def main_language("golang"), do: "Go"
  def main_language("static"), do: "Static"
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
