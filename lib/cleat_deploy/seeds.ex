defmodule CleatDeploy.Seeds do
  @moduledoc """
  Idempotent database seeds for local and production bootstrap.
  """

  alias CleatDeploy.{Apps, Repo, Servers}
  alias CleatDeploy.Accounts

  import Ecto.Query

  @matheus_email "matheus.puppe@gmail.com"

  @doc """
  Seeds the matheus owner account, Gestão Bem tenant, Trip Planner, and RapidTools apps.
  Safe to run multiple times.
  """
  def run(opts \\ []) do
    email = Keyword.get(opts, :email, @matheus_email)
    password = Keyword.get(opts, :password, System.get_env("SEED_USER_PASSWORD"))

    user =
      case Accounts.get_user_by_email(email) do
        %{} = existing ->
          existing

        nil ->
          {:ok, user} = Accounts.register_user(%{email: email})
          user
      end

    user =
      if password do
        {:ok, {user, _tokens}} = Accounts.update_user_password(user, %{password: password})
        user
      else
        user
      end

    scope =
      Accounts.ensure_tenant_for_user(user, %{
        name: "Gestão Bem",
        slug: "gestao-bem"
      })

    tenant_id = scope.tenant.id

    server = ensure_shared_server(scope, tenant_id, opts)

    seed_app(scope, server, tenant_id, %{
      name: "Trip Planner",
      slug: "trip-planner",
      github_repo: "puppe1990/trip-planner-ia-phx",
      branch: "main",
      host: "trip.gestaobem.com",
      port: 4000,
      systemd_unit: "trip_planner_ia",
      release_path: "/opt/trip_planner_ia",
      release_name: "trip_planner_ia"
    })

    seed_app(scope, server, tenant_id, %{
      name: "RapidTools",
      slug: "rapid-tools",
      github_repo: "puppe1990/rapid-tools",
      branch: "main",
      host: "tools.gestaobem.com",
      port: 4001,
      systemd_unit: "rapid_tools",
      release_path: "/opt/rapid_tools"
    })

    seed_app(scope, server, tenant_id, %{
      name: "OpenDrive",
      slug: "open-drive",
      github_repo: "puppe1990/OpenDrive",
      branch: "main",
      host: "drive.gestaobem.com",
      port: 4002,
      systemd_unit: "open_drive",
      release_path: "/opt/open_drive"
    })

    seed_app(scope, server, tenant_id, %{
      name: "Mass Transcriptor",
      slug: "mass-transcriptor",
      github_repo: "puppe1990/mass-transcriptor-phoenix",
      branch: "main",
      host: "transcribe.gestaobem.com",
      port: 4003,
      systemd_unit: "mass_transcriptor",
      release_path: "/opt/mass_transcriptor"
    })

    seed_app(scope, server, tenant_id, %{
      name: "Phoenix TTS",
      slug: "phoenix-tts",
      github_repo: "puppe1990/phoenix_tts",
      branch: "main",
      host: "tts.gestaobem.com",
      port: 4004,
      systemd_unit: "phoenix_tts",
      release_path: "/opt/phoenix_tts"
    })

    catalog_server = maybe_seed_catalog(scope, tenant_id, opts)
    hetzner_server = maybe_seed_hetzner(scope, tenant_id, opts)

    if hetzner_server do
      seed_app(scope, hetzner_server, tenant_id, %{
        name: "CLARITY AI",
        slug: "assistente",
        github_repo: "puppe1990/assistente-ia",
        branch: "main",
        host: "clarity.gestaobem.com",
        port: 4013,
        systemd_unit: "assistente",
        release_path: "/opt/assistente"
      })

      seed_app(scope, hetzner_server, tenant_id, %{
        name: "GitHub Projects",
        slug: "github-projects",
        github_repo: "puppe1990/github-projects-viewer-cais",
        branch: "main",
        host: "github.gestaobem.com",
        port: 4021,
        runtime: "golang",
        systemd_unit: "github-projects",
        release_path: "/opt/github-projects"
      })

      seed_app(scope, hetzner_server, tenant_id, %{
        name: "PratoAI",
        slug: "prato-ai",
        github_repo: "gestao-bem/prato-ai",
        branch: "main",
        host: "pratoai.gestaobem.com",
        port: 4007,
        systemd_unit: "prato_ai",
        release_path: "/opt/prato_ai"
      })
    end

    {:ok,
     %{
       user: user,
       scope: scope,
       server: server,
       catalog_server: catalog_server,
       hetzner_server: hetzner_server
     }}
  end

  defp ensure_shared_server(scope, tenant_id, opts) do
    case Repo.one(
           from s in Servers.Server,
             where: s.tenant_id == ^tenant_id and s.name == "trip-lightsail",
             limit: 1
         ) do
      %Servers.Server{} = existing ->
        maybe_backfill_server_ssh_key(existing, opts)

      nil ->
        {:ok, server} = Servers.create_server(scope, shared_server_seed_attrs(opts))
        server
    end
  end

  defp maybe_seed_catalog(scope, tenant_id, opts) do
    case catalog_server_ip(opts) do
      nil ->
        nil

      host_ip ->
        catalog_server =
          case Repo.one(
                 from s in Servers.Server,
                   where: s.tenant_id == ^tenant_id and s.name == "catalogo-lightsail",
                   limit: 1
               ) do
            %Servers.Server{} = existing ->
              maybe_update_catalog_server(existing, host_ip, opts)

            nil ->
              {:ok, server} =
                Servers.create_server(scope, catalog_server_seed_attrs(host_ip, opts))

              server
          end

        seed_app(scope, catalog_server, tenant_id, %{
          name: "Catálogo",
          slug: "catalogo",
          github_repo: "gestao-bem/catalog_platform",
          branch: "main",
          host: "loja.gestaobem.com",
          port: 4000,
          systemd_unit: "catalog_platform",
          release_path: "/opt/catalog_platform",
          release_name: "catalog_platform",
          custom_domain: true
        })

        catalog_server
    end
  end

  defp maybe_update_catalog_server(%Servers.Server{} = server, host_ip, opts) do
    changes =
      %{host_ip: host_ip, deploy_mode: "dedicated", aws_instance_name: "catalogo-lightsail"}
      |> maybe_put_ssh_key_attr(opts)

    if Enum.any?(changes, fn {key, value} -> Map.get(server, key) != value end) do
      server
      |> Servers.Server.changeset(changes)
      |> Repo.update!()
    else
      server
    end
  end

  defp maybe_put_ssh_key_attr(attrs, opts) do
    case read_ssh_key(opts) do
      nil -> attrs
      key -> Map.put(attrs, :ssh_private_key, key)
    end
  end

  defp seed_app(scope, server, tenant_id, attrs) do
    repo = Map.fetch!(attrs, :github_repo)

    app =
      case Apps.get_app_by_repo(repo) do
        %Apps.App{tenant_id: ^tenant_id} = app ->
          maybe_update_app(app, server, tenant_id, attrs)

        %Apps.App{} = app ->
          app
          |> Ecto.Changeset.change(app_seed_attrs(server, tenant_id, attrs))
          |> Repo.update!()

        nil ->
          {:ok, app, _webhook_status} =
            Apps.create_app(scope, Map.put(attrs, :server_id, server.id))

          app
      end

    Apps.sync_github_webhook(app)
    app
  end

  defp maybe_update_app(app, server, tenant_id, attrs) do
    changes = app_seed_attrs(server, tenant_id, attrs)

    if Enum.any?(changes, fn {key, value} -> Map.get(app, key) != value end) do
      app
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()
    else
      app
    end
  end

  defp shared_server_seed_attrs(opts) do
    attrs = %{
      name: "trip-lightsail",
      host_ip: "100.59.80.29",
      ssh_user: "ubuntu",
      region: "us-east-1",
      deploy_mode: "shared",
      aws_instance_name: "trip-lightsail"
    }

    case read_ssh_key(opts) do
      nil -> attrs
      key -> Map.put(attrs, :ssh_private_key, key)
    end
  end

  defp catalog_server_seed_attrs(host_ip, opts) do
    attrs = %{
      name: "catalogo-lightsail",
      host_ip: host_ip,
      ssh_user: "ubuntu",
      region: "us-east-1",
      deploy_mode: "dedicated",
      aws_instance_name: "catalogo-lightsail"
    }

    case read_ssh_key(opts) do
      nil -> attrs
      key -> Map.put(attrs, :ssh_private_key, key)
    end
  end

  defp catalog_server_ip(opts) do
    Keyword.get(opts, :catalog_server_ip) ||
      System.get_env("CATALOGO_SERVER_IP")
  end

  defp maybe_seed_hetzner(scope, tenant_id, opts) do
    case hetzner_server_ip(opts) do
      nil ->
        nil

      host_ip ->
        case Repo.one(
               from s in Servers.Server,
                 where: s.tenant_id == ^tenant_id and s.name == "gestaobem-cx33",
                 limit: 1
             ) do
          %Servers.Server{} = existing ->
            existing
            |> Servers.Server.changeset(hetzner_server_seed_attrs(host_ip, opts))
            |> Repo.update!()

          nil ->
            {:ok, server} = Servers.create_server(scope, hetzner_server_seed_attrs(host_ip, opts))
            server
        end
    end
  end

  defp hetzner_server_seed_attrs(host_ip, opts) do
    attrs = %{
      name: "gestaobem-cx33",
      host_ip: host_ip,
      ssh_user: "ubuntu",
      region: System.get_env("HETZNER_LOCATION", "fsn1"),
      provider: "hetzner",
      deploy_mode: "shared",
      aws_instance_name: "gestaobem-cx33",
      bundle_id: "cx33",
      bundle_name: "CX33",
      cpu_count: 4,
      ram_mb: 8192,
      disk_gb: 80
    }

    case read_ssh_key(opts) do
      nil -> attrs
      key -> Map.put(attrs, :ssh_private_key, key)
    end
  end

  defp hetzner_server_ip(opts) do
    Keyword.get(opts, :hetzner_server_ip) ||
      System.get_env("HETZNER_SERVER_IP")
  end

  defp maybe_backfill_server_ssh_key(%Servers.Server{} = server, opts) do
    if Servers.ssh_key_configured?(server) do
      server
    else
      case read_ssh_key(opts) do
        nil ->
          server

        key ->
          server
          |> Servers.Server.changeset(%{ssh_private_key: key})
          |> Repo.update!()
      end
    end
  end

  defp read_ssh_key(opts) do
    path =
      Keyword.get(
        opts,
        :ssh_key_path,
        System.get_env(
          "SEED_SSH_KEY_PATH",
          Path.expand("~/.ssh/lightsail-default-key-us-east-1.pem")
        )
      )

    if is_binary(path) and File.exists?(path) do
      File.read!(path)
    end
  end

  defp app_seed_attrs(server, tenant_id, attrs) do
    attrs
    |> Map.take([
      :name,
      :slug,
      :github_repo,
      :branch,
      :host,
      :port,
      :runtime,
      :systemd_unit,
      :release_path,
      :release_name,
      :custom_domain
    ])
    |> Map.put(:tenant_id, tenant_id)
    |> Map.put(:server_id, server.id)
  end
end
