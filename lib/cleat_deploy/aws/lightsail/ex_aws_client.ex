defmodule CleatDeploy.AWS.Lightsail.ExAwsClient do
  @moduledoc """
  AWS Lightsail client using Req and AWS Signature V4.
  """
  @behaviour CleatDeploy.AWS.Lightsail

  alias CleatDeploy.AWS.Lightsail.{Bundle, Catalog, InstanceSpec}

  @version "Lightsail_20161128"
  @service "lightsail"

  @impl true
  def get_instance(region, instance_name) do
    case request(region, "GetInstance", %{instanceName: instance_name}) do
      {:ok, %{"instance" => instance}} ->
        {:ok, map_instance(instance, region)}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  @impl true
  def list_instances(region) do
    fetch_instances(region, nil, [])
  end

  @impl true
  def list_bundles(region) do
    with {:ok, %{"bundles" => bundles}} <-
           request(region, "GetBundles", %{includeInactive: false}) do
      {:ok, Enum.map(bundles, &map_bundle/1)}
    end
  end

  @impl true
  def change_bundle(region, instance_name, bundle_id) do
    case request(region, "UpdateInstanceBundle", %{
           instanceName: instance_name,
           bundleId: bundle_id
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def power(region, instance_name, action) when action in [:start, :stop] do
    action_name = if action == :start, do: "StartInstance", else: "StopInstance"

    case request(region, action_name, %{instanceName: instance_name}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(region, action, params) do
    host = "lightsail.#{region}.amazonaws.com"
    url = "https://#{host}/"
    body = Jason.encode!(params)
    datetime = :calendar.universal_time()

    headers = [
      {"content-type", "application/x-amz-json-1.1"},
      {"host", host},
      {"x-amz-target", "#{@version}.#{action}"}
    ]

    credential = credential()

    signed_headers =
      :aws_signature.sign_v4(
        credential.access_key_id,
        credential.secret_access_key,
        region,
        @service,
        datetime,
        "POST",
        url,
        headers,
        body
      )

    case Req.post(url, headers: signed_headers, body: body, receive_timeout: 60_000) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        decode_body(response_body)

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:lightsail, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp credential do
    %{
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
    }
  end

  defp fetch_instances(region, page_token, acc) do
    params =
      if is_binary(page_token) and page_token != "" do
        %{pageToken: page_token}
      else
        %{}
      end

    case request(region, "GetInstances", params) do
      {:ok, body} ->
        instances = Enum.map(body["instances"] || [], &map_instance(&1, region))
        acc = acc ++ instances

        case body["nextPageToken"] do
          token when is_binary(token) and token != "" ->
            fetch_instances(region, token, acc)

          _ ->
            {:ok, acc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp map_instance(instance, region) do
    bundle_id = instance["bundleId"]
    catalog = Catalog.find_bundle(bundle_id)

    %InstanceSpec{
      bundle_id: bundle_id,
      bundle_name: (catalog && catalog.bundle_name) || Catalog.bundle_name(bundle_id),
      cpu_count:
        get_in(instance, ["hardware", "cpuCount"]) || (catalog && catalog.cpu_count) || 1,
      ram_mb:
        ram_mb_from_gb(get_in(instance, ["hardware", "ramSizeInGb"])) ||
          (catalog && catalog.ram_mb) || 512,
      disk_gb: disk_gb(instance) || (catalog && catalog.disk_gb) || 20,
      status: get_in(instance, ["state", "name"]) || "unknown",
      blueprint_name: instance["blueprintName"] || "—",
      monthly_price_usd: (catalog && catalog.monthly_price_usd) || Decimal.new("0"),
      name: instance["name"],
      public_ip: instance["publicIpAddress"],
      region: get_in(instance, ["location", "regionName"]) || region
    }
  end

  defp normalize_error({:lightsail, status, body} = reason) when status in [400, 404] do
    if not_found_body?(body), do: :not_found, else: reason
  end

  defp normalize_error(reason), do: reason

  defp not_found_body?(body) when is_map(body) do
    code = to_string(body["code"] || body["__type"] || "")
    String.contains?(code, "NotFound")
  end

  defp not_found_body?(body) when is_binary(body), do: String.contains?(body, "NotFound")
  defp not_found_body?(_), do: false

  defp map_bundle(bundle) do
    bundle_id = bundle["bundleId"]
    catalog = Catalog.find_bundle(bundle_id)

    %Bundle{
      bundle_id: bundle_id,
      bundle_name: (catalog && catalog.bundle_name) || bundle["name"] || bundle_id,
      cpu_count: bundle["cpuCount"] || (catalog && catalog.cpu_count) || 1,
      ram_mb:
        ram_mb_from_gb(bundle["ramSizeInGb"]) ||
          (catalog && catalog.ram_mb) || 512,
      disk_gb: bundle["diskSizeInGb"] || (catalog && catalog.disk_gb) || 20,
      monthly_price_usd: (catalog && catalog.monthly_price_usd) || Decimal.new("0")
    }
  end

  defp ram_mb_from_gb(gb) when is_number(gb), do: round(gb * 1024)
  defp ram_mb_from_gb(_), do: nil

  defp disk_gb(%{"hardware" => %{"disks" => [%{"sizeInGb" => size} | _]}}), do: size
  defp disk_gb(_), do: nil
end
