defmodule CleatDeploy.AWS.Lightsail.Stub do
  @moduledoc """
  Offline Lightsail client for dev/test without AWS credentials.
  """
  @behaviour CleatDeploy.AWS.Lightsail

  alias CleatDeploy.AWS.Lightsail.{Catalog, InstanceSpec}

  @impl true
  def list_instances(_region), do: {:ok, []}

  @impl true
  def get_instance(_region, instance_name) do
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
       blueprint_name: "Ubuntu",
       monthly_price_usd: bundle.monthly_price_usd
     }}
  end

  @impl true
  def list_bundles(_region), do: {:ok, Catalog.all_bundles()}

  @impl true
  def change_bundle(_region, instance_name, bundle_id) do
    if Catalog.find_bundle(bundle_id) do
      :ets.insert(stub_table(), {instance_name, bundle_id})
      :ok
    else
      {:error, :invalid_bundle}
    end
  end

  @impl true
  def power(_region, _instance_name, action) when action in [:start, :stop], do: :ok

  defp bundle_for_instance(instance_name) do
    case :ets.lookup(stub_table(), instance_name) do
      [{^instance_name, bundle_id}] -> bundle_id
      _ -> "nano_3_0"
    end
  end

  defp stub_table do
    case :ets.whereis(:cleat_deploy_lightsail_stub) do
      :undefined ->
        :ets.new(:cleat_deploy_lightsail_stub, [:named_table, :public, :set])

      tid ->
        tid
    end
  end
end
