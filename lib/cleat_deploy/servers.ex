defmodule CleatDeploy.Servers do
  @moduledoc """
  Manages deploy target servers (Lightsail and Hetzner VMs).
  """

  import Ecto.Query, warn: false
  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Cloud
  alias CleatDeploy.Hetzner
  alias CleatDeploy.Repo
  alias CleatDeploy.Servers.{Provision, Server, SshKeys}

  def list_servers(%Scope{tenant: tenant}) do
    Repo.all(
      from s in Server,
        where: s.tenant_id == ^tenant.id,
        order_by: [asc: s.name]
    )
  end

  def count_servers(%Scope{tenant: tenant}) do
    Repo.aggregate(from(s in Server, where: s.tenant_id == ^tenant.id), :count, :id)
  end

  def get_server!(%Scope{tenant: tenant}, id) do
    Repo.one!(
      from s in Server,
        where: s.tenant_id == ^tenant.id and s.id == ^id
    )
  end

  def create_server(%Scope{tenant: tenant}, attrs) do
    attrs = Map.put(stringify_keys(attrs), "tenant_id", tenant.id)

    %Server{}
    |> Server.changeset(attrs)
    |> Repo.insert()
  end

  def change_provision(attrs \\ %{}) do
    Provision.changeset(Map.merge(Provision.defaults(), stringify_keys(attrs)))
  end

  def provision_server(%Scope{} = scope, attrs) do
    changeset = change_provision(attrs)

    if changeset.valid? do
      data = Ecto.Changeset.apply_changes(changeset)

      with {:ok, keys} <- ssh_material(scope),
           {:ok, spec} <-
             Hetzner.create_instance(%{
               name: data.name,
               location: data.region,
               server_type: data.bundle_id,
               ssh_public_keys: [keys.public],
               user_data: Provision.user_data(keys.public)
             }) do
        create_server(scope, %{
          name: data.name,
          host_ip: spec.public_ip,
          ssh_user: "ubuntu",
          region: spec.region || data.region,
          provider: "hetzner",
          aws_instance_name: spec.name || data.name,
          ssh_private_key: keys.private,
          bundle_id: spec.bundle_id,
          bundle_name: spec.bundle_name,
          cpu_count: spec.cpu_count,
          ram_mb: spec.ram_mb,
          disk_gb: spec.disk_gb,
          instance_status: spec.status || "running",
          blueprint_name: spec.blueprint_name,
          monthly_price_usd: spec.monthly_price_usd,
          specs_synced_at: DateTime.utc_now(:second),
          deploy_mode: data.deploy_mode
        })
      end
    else
      {:error, Map.put(changeset, :action, :insert)}
    end
  end

  def format_cloud_error({:hetzner, _status, %{"error" => %{"message" => message}}})
      when is_binary(message),
      do: message

  def format_cloud_error(:missing_ssh_key), do: "Could not prepare an SSH key for the new VM"

  def format_cloud_error(:no_public_ip),
    do: "Hetzner created the VM but did not assign a public IP"

  def format_cloud_error(_), do: "Hetzner could not create the VM"

  def update_host_ip(%Server{} = server, host_ip) when is_binary(host_ip) do
    server
    |> Server.changeset(%{host_ip: host_ip})
    |> Repo.update()
  end

  def change_server(server, attrs \\ %{}) do
    Server.changeset(server, attrs)
  end

  def ssh_key_configured?(%Server{} = server) do
    is_binary(server.ssh_private_key_encrypted) and server.ssh_private_key_encrypted != ""
  end

  def sync_specs(%Scope{tenant: tenant}, %Server{tenant_id: tenant_id} = server)
      when tenant_id == tenant.id do
    sync_specs(server)
  end

  def sync_specs(%Scope{}, %Server{}), do: {:error, :unauthorized}

  def sync_specs(%Server{} = server) do
    Cloud.sync_specs(server)
  end

  def list_resize_options(%Scope{tenant: tenant}, %Server{tenant_id: tenant_id} = server)
      when tenant_id == tenant.id do
    list_resize_options(server)
  end

  def list_resize_options(%Scope{}, %Server{}), do: []

  def list_resize_options(%Server{} = server) do
    Cloud.list_resize_options(server)
  end

  def resize_bundle(%Scope{tenant: tenant}, %Server{tenant_id: tenant_id} = server, bundle_id)
      when tenant_id == tenant.id do
    resize_bundle(server, bundle_id)
  end

  def resize_bundle(%Scope{}, %Server{}, _bundle_id), do: {:error, :unauthorized}

  def resize_bundle(%Server{} = server, bundle_id) do
    Cloud.resize_bundle(server, bundle_id)
  end

  @doc """
  Powers a server's cloud instance on or off and refreshes its specs.
  """
  def power(%Scope{tenant: tenant}, %Server{tenant_id: tenant_id} = server, action)
      when tenant_id == tenant.id and action in [:start, :stop] do
    Cloud.power(server, action)
  end

  def power(%Scope{}, %Server{}, _action), do: {:error, :unauthorized}

  def sync_inventory(%Scope{tenant: tenant} = scope) do
    servers = list_servers(scope)
    result = Cloud.sync_inventory(servers)
    {result, list_servers(%Scope{tenant: tenant})}
  end

  def sync_all_inventories do
    Repo.all(Server)
    |> Cloud.sync_inventory()
  end

  def delete_server(%Scope{tenant: tenant}, %Server{tenant_id: tenant_id} = server)
      when tenant_id == tenant.id do
    if Repo.exists?(from a in App, where: a.server_id == ^server.id) do
      {:error, :has_apps}
    else
      Repo.delete(server)
    end
  end

  def delete_server(%Scope{}, %Server{}), do: {:error, :unauthorized}

  defp ssh_material(%Scope{} = scope) do
    case first_server_with_key(scope) do
      %Server{ssh_private_key_encrypted: private} = _server ->
        case SshKeys.public_from_private(private) do
          {:ok, public} -> {:ok, %{private: private, public: public}}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        SshKeys.generate()
    end
  end

  defp first_server_with_key(%Scope{tenant: tenant}) do
    Repo.one(
      from s in Server,
        where: s.tenant_id == ^tenant.id and not is_nil(s.ssh_private_key_encrypted),
        order_by: [asc: s.id],
        limit: 1
    )
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
