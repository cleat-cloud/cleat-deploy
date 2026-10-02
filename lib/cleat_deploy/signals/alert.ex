defmodule CleatDeploy.Signals.Alert do
  @moduledoc """
  A default Corte 02 alert: unavailability, deploy failed, error rate or saturation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CleatDeploy.Accounts.Tenant
  alias CleatDeploy.Apps.App

  @rules ~w(unavailability deploy_failed error_rate saturation)
  @statuses ~w(firing acked resolved)
  @channels ~w(in_app webhook)

  schema "signal_alerts" do
    field :rule, :string
    field :status, :string, default: "firing"
    field :message, :string, default: ""
    field :payload, :map, default: %{}
    field :channel, :string, default: "in_app"
    field :fired_at, :utc_datetime
    field :acked_at, :utc_datetime
    field :resolved_at, :utc_datetime
    field :delivered_at, :utc_datetime

    belongs_to :tenant, Tenant
    belongs_to :app, App

    timestamps(type: :utc_datetime)
  end

  def rules, do: @rules
  def statuses, do: @statuses

  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :tenant_id,
      :app_id,
      :rule,
      :status,
      :message,
      :payload,
      :channel,
      :fired_at
    ])
    |> validate_required([:tenant_id, :app_id, :rule, :status, :message, :fired_at])
    |> validate_inclusion(:rule, @rules)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:channel, @channels)
    |> unique_constraint([:tenant_id, :app_id, :rule], name: :signal_alerts_open_index)
  end
end
