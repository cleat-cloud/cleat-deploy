defmodule CleatDeploy.Apps.Provisioning do
  @moduledoc false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Servers.Server

  @host_domain "gestaobem.com"

  @known_presets %{
    "puppe1990/trip-planner-ia-phx" => %{
      name: "Trip Planner",
      slug: "trip-planner",
      host: "trip.gestaobem.com",
      port: 4000,
      systemd_unit: "trip_planner_ia",
      release_path: "/opt/trip_planner_ia",
      release_name: "trip_planner_ia"
    },
    "puppe1990/rapid-tools" => %{
      name: "RapidTools",
      slug: "rapid-tools",
      host: "tools.gestaobem.com",
      port: 4001,
      systemd_unit: "rapid_tools",
      release_path: "/opt/rapid_tools"
    },
    "puppe1990/OpenDrive" => %{
      name: "OpenDrive",
      slug: "open-drive",
      host: "drive.gestaobem.com",
      port: 4002,
      systemd_unit: "open_drive",
      release_path: "/opt/open_drive"
    },
    "puppe1990/mass-transcriptor-phoenix" => %{
      name: "Mass Transcriptor",
      slug: "mass-transcriptor",
      host: "transcribe.gestaobem.com",
      port: 4003,
      systemd_unit: "mass_transcriptor",
      release_path: "/opt/mass_transcriptor"
    },
    "puppe1990/phoenix_tts" => %{
      name: "Phoenix TTS",
      slug: "phoenix-tts",
      host: "tts.gestaobem.com",
      port: 4004,
      systemd_unit: "phoenix_tts",
      release_path: "/opt/phoenix_tts"
    },
    "gestao-bem/catalog_platform" => %{
      name: "Catálogo",
      slug: "catalogo",
      host: "loja.gestaobem.com",
      port: 4000,
      systemd_unit: "catalog_platform",
      release_path: "/opt/catalog_platform",
      release_name: "catalog_platform",
      custom_domain: true,
      server_name: "catalogo-lightsail"
    },
    "puppe1990/vexo" => %{
      name: "Vexo",
      slug: "vexo",
      host: "vexo.gestaobem.com",
      port: 4012,
      systemd_unit: "vexo",
      release_path: "/opt/vexo",
      server_name: "catalogo-lightsail"
    },
    "puppe1990/assistente-ia" => %{
      name: "CLARITY AI",
      slug: "assistente",
      host: "clarity.gestaobem.com",
      port: 4013,
      systemd_unit: "assistente",
      release_path: "/opt/assistente",
      server_name: "catalogo-lightsail"
    },
    "puppe1990/atelie" => %{
      name: "Ateliê",
      slug: "atelie",
      host: "atelie.gestaobem.com",
      port: 4020,
      runtime: "golang",
      systemd_unit: "atelie",
      release_path: "/opt/atelie",
      server_name: "gestaobem-cx33"
    },
    "puppe1990/leilao-erp" => %{
      name: "Leilão ERP",
      slug: "leilao-erp",
      host: "eletronicos.gestaobem.com",
      port: 8080,
      runtime: "golang",
      systemd_unit: "leilao-erp",
      release_path: "/opt/leilao-erp",
      server_name: "gestaobem-cx33"
    },
    "puppe1990/trama-bras" => %{
      name: "Trama Brás",
      slug: "trama-bras",
      host: "trama.gestaobem.com",
      port: 4006,
      runtime: "golang",
      systemd_unit: "trama-bras",
      release_path: "/opt/trama-bras",
      server_name: "gestaobem-cx33"
    },
    "puppe1990/github-projects-viewer-cais" => %{
      name: "GitHub Projects",
      slug: "github-projects",
      host: "github.gestaobem.com",
      port: 4021,
      runtime: "golang",
      systemd_unit: "github-projects",
      release_path: "/opt/github-projects",
      server_name: "gestaobem-cx33"
    },
    "puppe1990/cifra-finops" => %{
      name: "Cifra",
      slug: "cifra",
      host: "finops.gestaobem.com",
      port: 4022,
      runtime: "golang",
      systemd_unit: "cifra",
      release_path: "/opt/cifra",
      server_name: "gestaobem-cx33"
    },
    "gestao-bem/prato-ai" => %{
      name: "PratoAI",
      slug: "prato-ai",
      host: "pratoai.gestaobem.com",
      port: 4007,
      systemd_unit: "prato_ai",
      release_path: "/opt/prato_ai",
      server_name: "gestaobem-cx33"
    }
  }

  @doc """
  Returns preset attrs for registering an app from a GitHub repo slug.
  """
  def preset_from_repo(github_repo, servers \\ []) when is_list(servers) do
    github_repo = String.trim(github_repo)

    if github_repo == "" do
      %{}
    else
      github_repo
      |> then(&Map.get(@known_presets, &1, derive_preset(&1)))
      |> Map.put(:github_repo, github_repo)
      |> Map.put_new(:branch, "main")
      |> put_server_id(servers)
      |> put_deploy_defaults()
      |> stringify_keys()
    end
  end

  @doc """
  Merges preset attrs into form params when a repository is selected.

  Preset values win for auto fields unless `advanced` is enabled in params.
  """
  def apply_preset(params, servers) when is_map(params) do
    repo = param(params, "github_repo")

    if repo in [nil, ""] do
      params
    else
      preset = preset_from_repo(repo, servers)
      advanced? = param(params, "advanced") in ["true", "on", true]

      if advanced? do
        params
      else
        Map.merge(params, preset)
      end
    end
  end

  defp derive_preset(github_repo) do
    slug = slug_from_repo(github_repo)

    %{
      name: humanize_slug(slug),
      slug: slug,
      host: "#{slug}.#{@host_domain}",
      port: 4000
    }
  end

  defp slug_from_repo(github_repo) do
    github_repo
    |> String.split("/", parts: 2)
    |> List.last()
    |> String.downcase()
    |> String.replace("_", "-")
    |> String.replace(~r/[^a-z0-9-]+/u, "-")
    |> String.trim("-")
  end

  defp humanize_slug(slug) do
    slug
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp put_server_id(attrs, servers) do
    server_id =
      case Map.get(attrs, :server_name) do
        name when is_binary(name) ->
          servers
          |> Enum.find_value(fn %Server{id: id, name: server_name} ->
            if server_name == name, do: id
          end)
          |> Kernel.||(default_server_id(servers))

        _ ->
          default_server_id(servers)
      end

    attrs
    |> Map.delete(:server_name)
    |> Map.put(:server_id, server_id)
  end

  defp default_server_id([]), do: nil

  defp default_server_id(servers) do
    Enum.find_value(servers, fn
      %Server{id: id, name: "gestaobem-cx33"} -> id
      _ -> nil
    end) ||
      case servers do
        [%Server{id: id} | _] -> id
        _ -> nil
      end
  end

  defp put_deploy_defaults(%{slug: slug} = attrs) when is_binary(slug) and slug != "" do
    runtime = Map.get(attrs, :runtime, "phoenix")

    attrs
    |> Map.put_new(:systemd_unit, App.default_systemd_unit(slug, runtime))
    |> Map.put_new(:release_path, App.default_release_path(slug, runtime))
    |> Map.put_new(:release_name, App.release_name(slug))
  end

  defp put_deploy_defaults(attrs), do: attrs

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(params, key)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
