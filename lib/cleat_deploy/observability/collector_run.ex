defmodule CleatDeploy.Observability.CollectorRun do
  @moduledoc """
  Heartbeat written after each periodic log sweep.

  `Observability.ingest_status/1` reads the newest row so a stopped collector
  is told apart from a tenant that simply had no new log lines.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "collector_runs" do
    field :ran_at, :utc_datetime
    field :apps, :integer, default: 0
    field :failures, :integer, default: 0
    field :failed_slugs, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:ran_at, :apps, :failures, :failed_slugs])
    |> validate_required([:ran_at])
  end
end
