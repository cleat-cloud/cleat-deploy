defmodule CleatDeploy.Hetzner do
  @moduledoc """
  Behaviour for Hetzner Cloud instance operations.
  """

  alias CleatDeploy.AWS.Lightsail.Bundle
  alias CleatDeploy.AWS.Lightsail.InstanceSpec

  @type location :: String.t()
  @type instance_name :: String.t()
  @type bundle_id :: String.t()

  @callback get_instance(location(), instance_name()) ::
              {:ok, InstanceSpec.t()} | {:error, term()}

  @callback list_instances(location()) :: {:ok, [InstanceSpec.t()]} | {:error, term()}

  @callback list_bundles(location()) :: {:ok, [Bundle.t()]} | {:error, term()}

  @callback change_bundle(location(), instance_name(), bundle_id()) :: :ok | {:error, term()}

  @callback create_instance(map()) :: {:ok, InstanceSpec.t()} | {:error, term()}

  @callback get_metrics(location(), instance_name(), DateTime.t(), DateTime.t()) ::
              {:ok, map()} | {:error, term()}

  @callback power(instance_name(), :start | :stop) :: :ok | {:error, term()}

  def client do
    Application.fetch_env!(:cleat_deploy, :hetzner_client)
  end

  def get_instance(location, instance_name) do
    client().get_instance(location, instance_name)
  end

  def list_instances(location) do
    client().list_instances(location)
  end

  def list_bundles(location) do
    client().list_bundles(location)
  end

  def change_bundle(location, instance_name, bundle_id) do
    client().change_bundle(location, instance_name, bundle_id)
  end

  def create_instance(attrs) when is_map(attrs) do
    client().create_instance(attrs)
  end

  def get_metrics(location, instance_name, start_at, end_at) do
    client().get_metrics(location, instance_name, start_at, end_at)
  end

  def power(instance_name, action) when action in [:start, :stop] do
    client().power(instance_name, action)
  end
end
