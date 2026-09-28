defmodule CleatDeploy.Observability.LogEvent do
  @moduledoc """
  A single journal line persisted by the Cleat collector.

  Rows are immutable and idempotent: `cursor` is journald's `__CURSOR`, and a
  unique index on `[server_id, cursor]` makes re-ingesting the same window a
  no-op.
  """

  use Ecto.Schema

  alias CleatDeploy.Accounts.Tenant
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Servers.Server

  @severities ~w(emerg alert crit err warning notice info debug)

  @type severity :: String.t()

  schema "log_events" do
    field :source, :string, default: "app"
    field :unit, :string, default: ""
    field :cursor, :string
    field :severity, :string, default: "info"
    field :message, :string, default: ""
    field :occurred_at, :utc_datetime

    belongs_to :tenant, Tenant
    belongs_to :app, App
    belongs_to :server, Server
    belongs_to :deployment, Deployment

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Ordered severity names, least to most severe."
  def severities, do: @severities

  @doc """
  Names at or above `level` (journald priority), most severe first.
  """
  def severities_at_least(level) when level in @severities do
    @severities |> Enum.take(Enum.find_index(@severities, &(&1 == level)) + 1) |> Enum.reverse()
  end

  def severities_at_least(_), do: @severities
end
