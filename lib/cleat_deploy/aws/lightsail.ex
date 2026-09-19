defmodule CleatDeploy.AWS.Lightsail do
  @moduledoc """
  Behaviour for AWS Lightsail instance operations.
  """

  alias CleatDeploy.AWS.Lightsail.{Bundle, InstanceSpec}

  @type region :: String.t()
  @type instance_name :: String.t()
  @type bundle_id :: String.t()

  @callback get_instance(region(), instance_name()) ::
              {:ok, InstanceSpec.t()} | {:error, term()}

  @callback list_instances(region()) :: {:ok, [InstanceSpec.t()]} | {:error, term()}

  @callback list_bundles(region()) :: {:ok, [Bundle.t()]} | {:error, term()}

  @callback change_bundle(region(), instance_name(), bundle_id()) :: :ok | {:error, term()}

  @callback power(region(), instance_name(), :start | :stop) :: :ok | {:error, term()}

  def client do
    Application.fetch_env!(:cleat_deploy, :lightsail_client)
  end

  def get_instance(region, instance_name) do
    client().get_instance(region, instance_name)
  end

  def list_instances(region) do
    client().list_instances(region)
  end

  def list_bundles(region) do
    client().list_bundles(region)
  end

  def change_bundle(region, instance_name, bundle_id) do
    client().change_bundle(region, instance_name, bundle_id)
  end

  def power(region, instance_name, action) when action in [:start, :stop] do
    client().power(region, instance_name, action)
  end
end
