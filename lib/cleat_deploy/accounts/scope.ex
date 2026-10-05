defmodule CleatDeploy.Accounts.Scope do
  @moduledoc """
  Caller scope for multi-tenant authorization and query isolation.
  """

  alias CleatDeploy.Accounts.{Tenant, User}

  @write_roles ~w(owner admin)

  defstruct user: nil, tenant: nil, role: nil

  @doc """
  Builds a scope for the given user and tenant.
  """
  def for_user(%User{} = user, %Tenant{} = tenant, role \\ "owner") do
    %__MODULE__{user: user, tenant: tenant, role: role}
  end

  def for_user(%User{} = user) do
    CleatDeploy.Accounts.get_scope_for_user(user)
  end

  def for_user(nil), do: nil

  @doc """
  Roles allowed to mutate apps, servers, deployments, env vars and signals.

  Single source of truth: the API plug and the LiveViews both read this, so a
  member is read-only in every interface.
  """
  def write_roles, do: @write_roles

  def can_write?(%__MODULE__{role: role}), do: role in @write_roles
  def can_write?(_), do: false
end
