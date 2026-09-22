defmodule CleatDeploy.Hetzner.Client do
  @moduledoc """
  Hetzner Cloud API client using Req.
  """
  @behaviour CleatDeploy.Hetzner

  alias CleatDeploy.AWS.Lightsail.InstanceSpec
  alias CleatDeploy.Hetzner.Catalog

  @base_url "https://api.hetzner.cloud/v1"

  @impl true
  def get_instance(_location, instance_name) do
    case request(:get, "/servers", name: instance_name) do
      {:ok, %{"servers" => [%{} = server | _]}} -> {:ok, map_server(server)}
      {:ok, %{"servers" => []}} -> {:error, :not_found}
      {:ok, _} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_instances(_location) do
    fetch_servers(1, [])
  end

  @impl true
  def list_bundles(_location) do
    {:ok, Catalog.all_bundles()}
  end

  @impl true
  def change_bundle(_location, instance_name, bundle_id) do
    with {:ok, server_id} <- server_id_by_name(instance_name),
         {:ok, _} <-
           request(:post, "/servers/#{server_id}/actions/change_type", %{
             server_type: bundle_id,
             upgrade_disk: true
           }) do
      :ok
    end
  end

  @impl true
  def power(instance_name, action) when action in [:start, :stop] do
    endpoint = if action == :start, do: "poweron", else: "poweroff"

    with {:ok, server_id} <- server_id_by_name(instance_name),
         {:ok, _} <- request(:post, "/servers/#{server_id}/actions/#{endpoint}", %{}) do
      :ok
    end
  end

  @impl true
  def get_metrics(_location, instance_name, start_at, end_at) do
    params = [
      start: DateTime.to_iso8601(start_at),
      end: DateTime.to_iso8601(end_at)
    ]

    with {:ok, server_id} <- server_id_by_name(instance_name),
         {:ok, cpu_body} <-
           request(:get, "/servers/#{server_id}/metrics", [{:type, "cpu"} | params]),
         {:ok, net_body} <-
           request(:get, "/servers/#{server_id}/metrics", [{:type, "network"} | params]) do
      {:ok, merge_metrics(cpu_body, net_body)}
    end
  end

  @impl true
  def create_instance(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    name = attrs["name"]
    location = attrs["location"] || attrs["region"] || "fsn1"
    server_type = attrs["server_type"] || attrs["bundle_id"] || "cx33"
    image = attrs["image"] || "ubuntu-24.04"
    public_keys = List.wrap(attrs["ssh_public_keys"])
    user_data = attrs["user_data"]

    with {:ok, ssh_ids} <- ensure_ssh_keys(public_keys),
         {:ok, %{"server" => server}} <-
           request(
             :post,
             "/servers",
             create_payload(name, server_type, image, location, ssh_ids, user_data)
           ),
         {:ok, spec} <- await_public_ip(server) do
      {:ok, spec}
    else
      # A name already in use means the VM exists: return it instead of
      # creating a second one. Any other uniqueness error (e.g. an SSH key
      # uploaded under another name) must surface as itself — falling back to
      # the name lookup would hide it behind a bare `:not_found`.
      {:error, {:hetzner, _status, body}} = error ->
        if uniqueness_error?(body) do
          case get_instance(location, name) do
            {:ok, spec} -> {:ok, spec}
            {:error, _reason} -> error
          end
        else
          error
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :create_failed}
    end
  end

  def map_server(server) when is_map(server) do
    type = server["server_type"] || %{}
    bundle_id = type["name"]
    catalog = Catalog.find_bundle(bundle_id)
    image = server["image"] || %{}

    %InstanceSpec{
      bundle_id: bundle_id,
      bundle_name: (catalog && catalog.bundle_name) || type["description"] || bundle_id,
      cpu_count: type["cores"] || (catalog && catalog.cpu_count) || 1,
      ram_mb: ram_mb(type["memory"]) || (catalog && catalog.ram_mb) || 1024,
      disk_gb: type["disk"] || (catalog && catalog.disk_gb) || 20,
      status: server["status"] || "unknown",
      blueprint_name: image["description"] || image["name"] || "—",
      monthly_price_usd: monthly_price(type, catalog),
      name: server["name"],
      public_ip: public_ipv4(server),
      region: get_in(server, ["datacenter", "location", "name"])
    }
  end

  defp fetch_servers(page, acc) do
    case request(:get, "/servers", page: page, per_page: 50) do
      {:ok, %{"servers" => servers} = body} ->
        acc = acc ++ Enum.map(servers, &map_server/1)
        last_page = get_in(body, ["meta", "pagination", "last_page"]) || page

        if page < last_page do
          fetch_servers(page + 1, acc)
        else
          {:ok, acc}
        end

      {:ok, _} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def public_ipv4(server) when is_map(server) do
    get_in(server, ["public_net", "ipv4", "ip"])
  end

  defp create_payload(name, server_type, image, location, ssh_ids, user_data) do
    payload = %{
      "name" => name,
      "server_type" => server_type,
      "image" => image,
      "location" => location,
      "ssh_keys" => ssh_ids,
      "start_after_create" => true,
      "labels" => %{"role" => "paas", "managed-by" => "cleat-deploy"}
    }

    if is_binary(user_data) and user_data != "" do
      Map.put(payload, "user_data", user_data)
    else
      payload
    end
  end

  defp ensure_ssh_keys([]), do: {:error, :missing_ssh_key}

  defp ensure_ssh_keys(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case ensure_ssh_key(key) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_ssh_key(public_key) when is_binary(public_key) do
    material = String.trim(public_key)
    name = ssh_key_name(material)

    case request(:get, "/ssh_keys", name: name) do
      {:ok, %{"ssh_keys" => [%{"id" => id} | _]}} ->
        {:ok, id}

      {:ok, %{"ssh_keys" => []}} ->
        case existing_key_id(material) do
          {:ok, id} -> {:ok, id}
          :error -> create_ssh_key(name, material)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_ssh_key(name, public_key) do
    case request(:post, "/ssh_keys", %{name: name, public_key: public_key}) do
      {:ok, %{"ssh_key" => %{"id" => id}}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  # The same key is often already registered under another name (one created by
  # hand when the VM was set up, say) and Hetzner rejects a second copy with a
  # uniqueness error, so the upload has to match on the key material.
  defp existing_key_id(public_key) do
    case request(:get, "/ssh_keys", per_page: 50) do
      {:ok, %{"ssh_keys" => keys}} -> find_key_id(keys, public_key)
      {:error, _reason} -> :error
    end
  end

  @doc """
  Id of the key whose material matches `public_key`, `:error` when absent.
  """
  def find_key_id(keys, public_key) when is_list(keys) and is_binary(public_key) do
    wanted = String.trim(public_key)

    case Enum.find(keys, &(String.trim(to_string(&1["public_key"])) == wanted)) do
      %{"id" => id} -> {:ok, id}
      _ -> :error
    end
  end

  @doc """
  Name Hetzner stores this public key under.

  Derived from the key itself so the same key is only ever uploaded once; the
  API rejects duplicate names, not duplicate keys.
  """
  def ssh_key_name(public_key) when is_binary(public_key) do
    digest =
      :crypto.hash(:sha256, public_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "paas-#{digest}"
  end

  defp await_public_ip(server, attempts \\ 20) do
    spec = map_server(server)

    cond do
      running_with_ip?(spec) ->
        {:ok, spec}

      attempts <= 1 ->
        if is_binary(spec.public_ip) and spec.public_ip != "",
          do: {:ok, spec},
          else: {:error, :no_public_ip}

      true ->
        Process.sleep(2000)

        case request(:get, "/servers/#{server["id"]}", []) do
          {:ok, %{"server" => next}} -> await_public_ip(next, attempts - 1)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp running_with_ip?(%{status: "running", public_ip: ip}) when is_binary(ip) and ip != "",
    do: true

  defp running_with_ip?(_), do: false

  defp uniqueness_error?(%{"error" => %{"code" => code}}) when is_binary(code) do
    String.contains?(code, "uniqueness")
  end

  defp uniqueness_error?(_), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp merge_metrics(cpu_body, net_body) do
    cpu_series = time_series(cpu_body)
    net_series = time_series(net_body)

    %{
      cpu: parse_series(cpu_series["cpu"]),
      network_in: parse_series(net_series["network.0.bandwidth.in"]),
      network_out: parse_series(net_series["network.0.bandwidth.out"])
    }
  end

  defp time_series(%{"metrics" => %{"time_series" => series}}) when is_map(series), do: series
  defp time_series(_), do: %{}

  defp parse_series(%{"values" => values}) when is_list(values) do
    values
    |> Enum.map(&parse_sample/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_series(_), do: []

  defp parse_sample([t, v]) do
    %{t: to_unix(t), v: to_float(v)}
  end

  defp parse_sample(_), do: nil

  defp to_unix(t) when is_integer(t), do: t
  defp to_unix(t) when is_float(t), do: trunc(t)

  defp to_unix(t) when is_binary(t) do
    case Integer.parse(t) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_unix(_), do: 0

  defp to_float(v) when is_number(v), do: v * 1.0

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  defp server_id_by_name(instance_name) do
    case request(:get, "/servers", name: instance_name) do
      {:ok, %{"servers" => [%{"id" => id} | _]}} -> {:ok, id}
      {:ok, %{"servers" => []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, path, params) when method in [:get] and is_list(params) do
    case Req.request(
           method: method,
           url: @base_url <> path,
           headers: auth_headers(),
           params: params,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_body(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:hetzner, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, path, body) when is_map(body) do
    case Req.request(
           method: method,
           url: @base_url <> path,
           headers: auth_headers(),
           json: body,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        decode_body(response_body)

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:hetzner, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp auth_headers do
    [{"authorization", "Bearer #{api_token()}"}]
  end

  defp api_token do
    System.get_env("HCLOUD_TOKEN") ||
      System.get_env("HETZNER_API_TOKEN") ||
      raise "HCLOUD_TOKEN or HETZNER_API_TOKEN is missing"
  end

  defp ram_mb(gb) when is_number(gb), do: round(gb * 1024)
  defp ram_mb(_), do: nil

  defp monthly_price(%{"prices" => prices}, catalog) when is_list(prices) do
    gross =
      prices
      |> Enum.find_value(fn price ->
        get_in(price, ["price_monthly", "gross"])
      end)

    parse_decimal(gross) || (catalog && catalog.monthly_price_usd) || Decimal.new("0")
  end

  defp monthly_price(_type, catalog) do
    (catalog && catalog.monthly_price_usd) || Decimal.new("0")
  end

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(_), do: nil
end
