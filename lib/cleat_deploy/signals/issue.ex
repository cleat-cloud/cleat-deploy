defmodule CleatDeploy.Signals.Issue do
  @moduledoc """
  One error group per `(tenant, app, fingerprint)` with a lifecycle.

  Corte 04b of Cleat Signals: unresolved / resolved / ignored. A new event
  on a resolved issue is a regression; ignored stays ignored until reopen.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CleatDeploy.Accounts.Tenant
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment

  @statuses ~w(unresolved resolved ignored)
  @sources ~w(journal otlp)

  schema "error_issues" do
    field :fingerprint, :string
    field :status, :string, default: "unresolved"
    field :severity, :string, default: "err"
    field :sample, :string, default: ""
    field :count, :integer, default: 0
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :source, :string, default: "journal"

    belongs_to :tenant, Tenant
    belongs_to :app, App
    belongs_to :last_deployment, Deployment

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def sources, do: @sources

  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :tenant_id,
      :app_id,
      :fingerprint,
      :status,
      :severity,
      :sample,
      :count,
      :first_seen_at,
      :last_seen_at,
      :last_deployment_id,
      :source
    ])
    |> validate_required([
      :tenant_id,
      :app_id,
      :fingerprint,
      :status,
      :severity,
      :sample,
      :count,
      :first_seen_at,
      :last_seen_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> unique_constraint([:tenant_id, :app_id, :fingerprint])
  end
end
