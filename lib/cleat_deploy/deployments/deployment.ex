defmodule CleatDeploy.Deployments.Deployment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias CleatDeploy.Apps.App

  @statuses [:queued, :running, :success, :failed]

  schema "deployments" do
    field :git_sha, :string
    field :git_ref, :string
    field :status, Ecto.Enum, values: @statuses, default: :queued
    field :log, :string, default: ""
    field :triggered_by, :string, default: "manual"
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :source, :string, default: "git"
    field :artifact_path, :string

    belongs_to :app, App

    timestamps(type: :utc_datetime)
  end

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :git_sha,
      :git_ref,
      :status,
      :log,
      :triggered_by,
      :started_at,
      :finished_at,
      :app_id
    ])
    |> validate_required([:git_sha, :app_id])
    |> foreign_key_constraint(:app_id)
  end

  @doc """
  Changeset for a git-less "drop": `source`/`artifact_path` are set
  programmatically so a caller can never point the runner at arbitrary files.
  """
  def drop_changeset(deployment, attrs) do
    artifact = Map.get(attrs, :artifact_path) || Map.get(attrs, "artifact_path")

    deployment
    |> changeset(attrs)
    |> put_change(:source, "drop")
    |> put_change(:artifact_path, artifact)
  end

  def statuses, do: @statuses
end
