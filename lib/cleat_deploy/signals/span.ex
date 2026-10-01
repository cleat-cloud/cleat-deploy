defmodule CleatDeploy.Signals.Span do
  @moduledoc """
  A single OTLP span persisted in the panel SQLite store.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CleatDeploy.Accounts.Tenant
  alias CleatDeploy.Apps.App

  @kinds ~w(unspecified internal server client producer consumer)
  @statuses ~w(unset ok error)

  schema "trace_spans" do
    field :trace_id, :string
    field :span_id, :string
    field :parent_span_id, :string, default: ""
    field :name, :string, default: ""
    field :kind, :string, default: "unspecified"
    field :service_name, :string, default: ""
    field :status_code, :string, default: "unset"
    field :start_time_unix_nano, :integer, default: 0
    field :end_time_unix_nano, :integer, default: 0
    field :duration_ns, :integer, default: 0
    field :attributes, :map, default: %{}

    belongs_to :tenant, Tenant
    belongs_to :app, App

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :tenant_id,
      :app_id,
      :trace_id,
      :span_id,
      :parent_span_id,
      :name,
      :kind,
      :service_name,
      :status_code,
      :start_time_unix_nano,
      :end_time_unix_nano,
      :duration_ns,
      :attributes
    ])
    |> validate_required([:tenant_id, :app_id, :trace_id, :span_id, :name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status_code, @statuses)
    |> unique_constraint([:tenant_id, :trace_id, :span_id])
  end
end
