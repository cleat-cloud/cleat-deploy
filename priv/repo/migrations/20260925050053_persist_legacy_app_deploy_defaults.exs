defmodule CleatDeploy.Repo.Migrations.PersistLegacyAppDeployDefaults do
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:apps) do
      add :release_name, :string
      add :custom_domain, :boolean, null: false, default: false
    end

    flush()

    rows =
      repo().all(
        from(a in "apps",
          select: %{
            id: a.id,
            slug: a.slug,
            runtime: a.runtime,
            systemd_unit: a.systemd_unit,
            release_path: a.release_path
          }
        )
      )

    Enum.each(rows, fn row ->
      runtime = row.runtime || "phoenix"
      unit = blank_to_nil(row.systemd_unit) || legacy_unit(row.slug, runtime)
      path = blank_to_nil(row.release_path) || legacy_path(row.slug, runtime)
      name = legacy_release_name(row.slug)
      custom_domain = row.slug == "catalogo"

      repo().update_all(from(a in "apps", where: a.id == ^row.id),
        set: [
          systemd_unit: unit,
          release_path: path,
          release_name: name,
          custom_domain: custom_domain
        ]
      )
    end)
  end

  def down do
    alter table(:apps) do
      remove :release_name
      remove :custom_domain
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp legacy_release_name("trip-planner"), do: "trip_planner_ia"
  defp legacy_release_name("catalogo"), do: "catalog_platform"
  defp legacy_release_name("controle-agente-viagens"), do: "controle_agente_viagens_phx"
  defp legacy_release_name("decor"), do: "festa_platform"
  defp legacy_release_name("gestao-bem-decor"), do: "festa_platform"
  defp legacy_release_name("pay-core"), do: "pay_core"
  defp legacy_release_name("pay_core"), do: "pay_core"
  defp legacy_release_name(slug) when is_binary(slug), do: String.replace(slug, "-", "_")
  defp legacy_release_name(_), do: nil

  defp legacy_unit(slug, "golang") when is_binary(slug), do: slug
  defp legacy_unit(slug, "node"), do: "node-#{slug}"
  defp legacy_unit(slug, "rails"), do: "rails-#{slug}"
  defp legacy_unit(slug, "rust"), do: "rust-#{slug}"
  defp legacy_unit(_slug, "static"), do: nil
  defp legacy_unit("trip-planner", _), do: "trip_planner_ia"
  defp legacy_unit("decor", _), do: "festa_platform"
  defp legacy_unit("pay-core", _), do: "pay_core"
  defp legacy_unit("vexo", _), do: "vexo"
  defp legacy_unit("assistente", _), do: "assistente"
  defp legacy_unit(slug, _) when is_binary(slug), do: "phx-#{slug}"
  defp legacy_unit(_, _), do: nil

  defp legacy_path(slug, "golang") when is_binary(slug), do: "/opt/#{slug}"
  defp legacy_path(slug, "node") when is_binary(slug), do: "/opt/#{slug}"
  defp legacy_path(slug, "rails") when is_binary(slug), do: "/opt/#{slug}"
  defp legacy_path(slug, "rust") when is_binary(slug), do: "/opt/#{slug}"
  defp legacy_path(slug, "static") when is_binary(slug), do: "/var/www/#{slug}"
  defp legacy_path("trip-planner", _), do: "/opt/trip_planner_ia"
  defp legacy_path("decor", _), do: "/opt/festa_platform"
  defp legacy_path("pay-core", _), do: "/opt/pay_core"
  defp legacy_path(slug, _) when is_binary(slug), do: "/opt/#{legacy_release_name(slug)}"
  defp legacy_path(_, _), do: nil
end
