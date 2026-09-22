defmodule CleatDeploy.Settings.Setting do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias CleatDeploy.Accounts.Tenant

  # Below 5 minutes a sleep/wake cycle costs more than it saves; the sweeper
  # only runs every 5 minutes, so shorter windows would not be honoured anyway.
  @min_minutes 5
  @max_minutes 43_200

  schema "settings" do
    field :idle_shutdown_enabled, :boolean, default: false
    field :idle_shutdown_minutes, :integer, default: 60

    belongs_to :tenant, Tenant

    timestamps(type: :utc_datetime)
  end

  def min_minutes, do: @min_minutes
  def max_minutes, do: @max_minutes

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:idle_shutdown_enabled, :idle_shutdown_minutes])
    |> validate_required([:idle_shutdown_enabled, :idle_shutdown_minutes])
    |> validate_number(:idle_shutdown_minutes,
      greater_than_or_equal_to: @min_minutes,
      less_than_or_equal_to: @max_minutes
    )
  end
end
