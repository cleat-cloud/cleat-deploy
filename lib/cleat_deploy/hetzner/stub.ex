defmodule CleatDeploy.Hetzner.Stub do
  @moduledoc """
  Offline Hetzner client for dev/test without an API token.
  """
  @behaviour CleatDeploy.Hetzner

  alias CleatDeploy.AWS.Lightsail.InstanceSpec
  alias CleatDeploy.Hetzner.Catalog

  @impl true
  def list_instances(_location), do: {:ok, []}

  @impl true
  def get_instance(_location, instance_name) do
    bundle_id = bundle_for_instance(instance_name)
    bundle = Catalog.find_bundle(bundle_id)

    {:ok,
     %InstanceSpec{
       bundle_id: bundle.bundle_id,
       bundle_name: bundle.bundle_name,
       cpu_count: bundle.cpu_count,
       ram_mb: bundle.ram_mb,
       disk_gb: bundle.disk_gb,
       status: "running",
       blueprint_name: "Ubuntu 24.04",
       monthly_price_usd: bundle.monthly_price_usd
     }}
  end

  @impl true
  def list_bundles(_location), do: {:ok, Catalog.all_bundles()}

  @impl true
  def change_bundle(_location, instance_name, bundle_id) do
    if Catalog.find_bundle(bundle_id) do
      :ets.insert(stub_table(), {instance_name, bundle_id})
      :ok
    else
      {:error, :invalid_bundle}
    end
  end

  @impl true
  def get_metrics(_location, _instance_name, start_at, end_at) do
    {:ok, fake_metrics(start_at, end_at)}
  end

  @impl true
  def power(_instance_name, action) when action in [:start, :stop], do: :ok

  @impl true
  def create_instance(attrs) when is_map(attrs) do
    attrs =
      Map.new(attrs, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)

    name = attrs["name"] || "hetzner-box"
    bundle_id = attrs["server_type"] || attrs["bundle_id"] || "cx33"
    bundle = Catalog.find_bundle(bundle_id) || Catalog.find_bundle("cx33")

    {:ok,
     %InstanceSpec{
       bundle_id: bundle.bundle_id,
       bundle_name: bundle.bundle_name,
       cpu_count: bundle.cpu_count,
       ram_mb: bundle.ram_mb,
       disk_gb: bundle.disk_gb,
       status: "running",
       blueprint_name: "Ubuntu 24.04",
       monthly_price_usd: bundle.monthly_price_usd,
       name: name,
       public_ip: "203.0.113.20",
       region: attrs["location"] || attrs["region"] || "fsn1"
     }}
  end

  defp fake_metrics(start_at, end_at) do
    start_unix = DateTime.to_unix(start_at)
    end_unix = DateTime.to_unix(end_at)
    step = max(div(end_unix - start_unix, 48), 60)

    cpu =
      Enum.map(0..47, fn i ->
        t = start_unix + i * step
        %{t: t, v: 8.0 + :math.sin(i / 4) * 6.0 + rem(i, 5)}
      end)

    network_in =
      Enum.map(0..47, fn i ->
        t = start_unix + i * step
        %{t: t, v: 40_000.0 + :math.sin(i / 5) * 20_000.0}
      end)

    network_out =
      Enum.map(0..47, fn i ->
        t = start_unix + i * step
        %{t: t, v: 18_000.0 + :math.cos(i / 6) * 8_000.0}
      end)

    %{cpu: cpu, network_in: network_in, network_out: network_out}
  end

  defp bundle_for_instance(instance_name) do
    case :ets.lookup(stub_table(), instance_name) do
      [{^instance_name, bundle_id}] -> bundle_id
      _ -> "cx33"
    end
  end

  defp stub_table do
    case :ets.whereis(:cleat_deploy_hetzner_stub) do
      :undefined ->
        :ets.new(:cleat_deploy_hetzner_stub, [:named_table, :public, :set])

      tid ->
        tid
    end
  end
end
