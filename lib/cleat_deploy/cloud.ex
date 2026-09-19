defmodule CleatDeploy.Cloud do
  @moduledoc """
  Dispatches instance operations to Lightsail or Hetzner.
  """

  alias CleatDeploy.AWS.Lightsail
  alias CleatDeploy.AWS.Lightsail.InstanceSpec
  alias CleatDeploy.Cloud.RemoteInstance
  alias CleatDeploy.Hetzner
  alias CleatDeploy.Repo
  alias CleatDeploy.Servers.Server

  def sync_specs(%Server{} = server) do
    with {:ok, name} <- instance_name(server) do
      case get_instance(server, name) do
        {:ok, spec} ->
          apply_spec(server, spec)

        {:error, :not_found} ->
          mark_status(server, "missing")

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Reconciles registered servers against live Hetzner and Lightsail inventories.

  Tailscale/CGNAT addresses (`100.64.0.0/10`) are marked `private` and skipped.
  Cloud VMs that disappeared are marked `missing`. Unregistered cloud VMs are
  returned as `discovered`.
  """
  def sync_inventory(servers) when is_list(servers) do
    catalog = load_catalog(servers)

    {updated, missing, private, errors} =
      Enum.reduce(servers, {[], [], [], []}, fn server, acc ->
        reconcile_registered(server, catalog, acc)
      end)

    %{
      updated: Enum.reverse(updated),
      missing: Enum.reverse(missing),
      private: Enum.reverse(private),
      discovered: discovered_instances(servers, catalog),
      errors: Enum.reverse(errors)
    }
  end

  def list_resize_options(%Server{} = server) do
    case list_bundles(server) do
      {:ok, bundles} ->
        Enum.reject(bundles, &(&1.bundle_id == server.bundle_id))

      {:error, _} ->
        []
    end
  end

  def resize_bundle(%Server{} = server, bundle_id) do
    with {:ok, name} <- instance_name(server),
         :ok <- change_bundle(server, name, bundle_id),
         {:ok, updated} <- sync_specs(server) do
      {:ok, updated}
    end
  end

  @doc """
  Powers a cloud instance on or off, then refreshes its specs.
  """
  def power(%Server{} = server, action) when action in [:start, :stop] do
    with {:ok, name} <- instance_name(server),
         :ok <- do_power(server, name, action) do
      sync_specs(server)
    end
  end

  defp do_power(%Server{} = server, name, action) do
    if hetzner?(server) do
      Hetzner.power(name, action)
    else
      Lightsail.power(server.region, name, action)
    end
  end

  def provider(%Server{provider: provider}) when is_binary(provider) and provider != "",
    do: provider

  def provider(_), do: "lightsail"

  def hetzner?(%Server{} = server), do: provider(server) == "hetzner"

  def format_price(%Server{provider: "hetzner", monthly_price_usd: %Decimal{} = price}) do
    "€#{Decimal.round(price, 2)}/mo"
  end

  def format_price(%Server{} = server), do: Server.format_price(server)

  def provider_label("hetzner"), do: "Hetzner Cloud"
  def provider_label(_), do: "AWS Lightsail"

  defp get_instance(%Server{} = server, name) do
    if hetzner?(server) do
      Hetzner.get_instance(server.region, name)
    else
      Lightsail.get_instance(server.region, name)
    end
  end

  defp load_catalog(servers) do
    lightsail_regions =
      servers
      |> Enum.filter(&(provider(&1) == "lightsail"))
      |> Enum.map(& &1.region)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Kernel.++(["us-east-1"])
      |> Enum.uniq()

    lightsail =
      Map.new(lightsail_regions, fn region ->
        {region, index_specs(Lightsail.list_instances(region))}
      end)

    %{
      "lightsail" => lightsail,
      "hetzner" => index_specs(Hetzner.list_instances("fsn1"))
    }
  end

  defp index_specs({:ok, specs}) when is_list(specs) do
    {:ok,
     specs
     |> Enum.filter(&(is_binary(&1.name) and &1.name != ""))
     |> Map.new(&{&1.name, &1})}
  end

  defp index_specs({:error, reason}), do: {:error, reason}

  defp reconcile_registered(server, catalog, {updated, missing, private, errors}) do
    cond do
      private_network?(server.host_ip) ->
        case mark_status(server, "private") do
          {:ok, marked} -> {updated, missing, [marked | private], errors}
          {:error, reason} -> {updated, missing, private, [{server.name, reason} | errors]}
        end

      true ->
        case lookup_spec(server, catalog) do
          {:ok, spec} ->
            case apply_spec(server, spec) do
              {:ok, synced} -> {[synced | updated], missing, private, errors}
              {:error, reason} -> {updated, missing, private, [{server.name, reason} | errors]}
            end

          :not_found ->
            case mark_status(server, "missing") do
              {:ok, marked} -> {updated, [marked | missing], private, errors}
              {:error, reason} -> {updated, missing, private, [{server.name, reason} | errors]}
            end

          {:error, reason} ->
            {updated, missing, private, [{server.name, reason} | errors]}
        end
    end
  end

  defp lookup_spec(server, catalog) do
    with {:ok, by_name} <- catalog_for(server, catalog) do
      name = instance_lookup_name(server)

      case Map.get(by_name, name) do
        %InstanceSpec{} = spec -> {:ok, spec}
        nil -> :not_found
      end
    end
  end

  defp catalog_for(server, catalog) do
    if hetzner?(server) do
      catalog["hetzner"]
    else
      Map.get(catalog["lightsail"], server.region) ||
        Map.get(catalog["lightsail"], "us-east-1") ||
        {:error, :no_region}
    end
  end

  defp discovered_instances(servers, catalog) do
    registered =
      servers
      |> Enum.flat_map(fn server ->
        [server.name, server.aws_instance_name]
      end)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> MapSet.new()

    hetzner_discovered =
      case catalog["hetzner"] do
        {:ok, by_name} ->
          by_name
          |> Map.values()
          |> Enum.map(&RemoteInstance.from_spec("hetzner", &1, &1.region || "fsn1"))

        _ ->
          []
      end

    lightsail_discovered =
      catalog["lightsail"]
      |> Enum.flat_map(fn {region, result} ->
        case result do
          {:ok, by_name} ->
            by_name
            |> Map.values()
            |> Enum.map(&RemoteInstance.from_spec("lightsail", &1, region))

          _ ->
            []
        end
      end)

    (hetzner_discovered ++ lightsail_discovered)
    |> Enum.reject(&(&1.name in [nil, ""] or MapSet.member?(registered, &1.name)))
    |> Enum.uniq_by(&{&1.provider, &1.name})
  end

  defp instance_lookup_name(%Server{aws_instance_name: name})
       when is_binary(name) and name != "",
       do: name

  defp instance_lookup_name(%Server{name: name}), do: name

  defp private_network?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      # Tailscale and CGNAT-style 100.x addresses are not in Hetzner/Lightsail APIs.
      {:ok, {100, _, _, _}} -> true
      _ -> false
    end
  end

  defp private_network?(_), do: false

  defp mark_status(server, status) do
    server
    |> Server.changeset(%{
      instance_status: status,
      specs_synced_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  defp list_bundles(%Server{} = server) do
    if hetzner?(server) do
      Hetzner.list_bundles(server.region)
    else
      Lightsail.list_bundles(server.region)
    end
  end

  defp change_bundle(%Server{} = server, name, bundle_id) do
    if hetzner?(server) do
      Hetzner.change_bundle(server.region, name, bundle_id)
    else
      Lightsail.change_bundle(server.region, name, bundle_id)
    end
  end

  defp instance_name(%Server{aws_instance_name: name})
       when is_binary(name) and name != "",
       do: {:ok, name}

  defp instance_name(_), do: {:error, :missing_instance_name}

  defp apply_spec(server, spec) do
    attrs = %{
      bundle_id: spec.bundle_id,
      bundle_name: spec.bundle_name,
      cpu_count: spec.cpu_count,
      ram_mb: spec.ram_mb,
      disk_gb: spec.disk_gb,
      instance_status: spec.status,
      blueprint_name: spec.blueprint_name,
      monthly_price_usd: spec.monthly_price_usd,
      specs_synced_at: DateTime.utc_now(:second)
    }

    server
    |> Server.changeset(maybe_host_ip(attrs, spec))
    |> Repo.update()
  end

  defp maybe_host_ip(attrs, %{public_ip: ip}) when is_binary(ip) and ip != "" do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {_, _, _, _}} -> Map.put(attrs, :host_ip, ip)
      _ -> attrs
    end
  end

  defp maybe_host_ip(attrs, _), do: attrs
end
