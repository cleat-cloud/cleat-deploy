defmodule CleatDeploy.Settings do
  @moduledoc """
  Per-tenant platform settings: the idle shutdown / auto-sleep window and which
  server the panel treats as active.
  """

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.{Scope, Tenant}
  alias CleatDeploy.Repo
  alias CleatDeploy.Settings.Setting

  @doc """
  Returns the tenant settings, falling back to an unsaved struct with defaults.

  Rows are only written on the first save, so a tenant that never touched the
  settings page behaves exactly like a fresh one.
  """
  def get_setting(%Scope{tenant: tenant}), do: get_setting(tenant)

  def get_setting(%Tenant{id: tenant_id}) do
    Repo.get_by(Setting, tenant_id: tenant_id) || %Setting{tenant_id: tenant_id}
  end

  def change_setting(%Setting{} = setting, attrs \\ %{}), do: Setting.changeset(setting, attrs)

  def update_setting(%Scope{tenant: tenant}, attrs) do
    case Setting.changeset(%Setting{tenant_id: tenant.id}, attrs) do
      %Ecto.Changeset{valid?: false} = changeset ->
        {:error, changeset}

      changeset ->
        Repo.insert(changeset,
          on_conflict: {:replace, [:idle_shutdown_enabled, :idle_shutdown_minutes, :updated_at]},
          conflict_target: :tenant_id
        )
    end
  end

  @doc """
  Remembers the server the tenant is looking at.

  Only the preference is written: the idle shutdown values already stored are
  left untouched.
  """
  def put_active_server(%Scope{} = scope, server_id) when is_integer(server_id) do
    changeset = Setting.changeset(get_setting(scope), %{active_server_id: server_id})

    if changeset.valid? do
      Repo.insert(changeset,
        on_conflict: {:replace, [:active_server_id, :updated_at]},
        conflict_target: :tenant_id
      )
    else
      {:error, changeset}
    end
  end

  @doc """
  Tenants that opted into idle shutdown, as `{tenant_id, minutes}`.

  Used by the sweeper: a tenant without a settings row (or with the feature off)
  is never touched.
  """
  def list_idle_shutdown do
    Repo.all(
      from s in Setting,
        where: s.idle_shutdown_enabled == true,
        select: {s.tenant_id, s.idle_shutdown_minutes}
    )
  end
end
