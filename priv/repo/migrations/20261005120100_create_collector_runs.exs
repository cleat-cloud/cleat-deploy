defmodule CleatDeploy.Repo.Migrations.CreateCollectorRuns do
  use Ecto.Migration

  def change do
    create table(:collector_runs) do
      add :ran_at, :utc_datetime, null: false
      add :apps, :integer, null: false, default: 0
      add :failures, :integer, null: false, default: 0
      add :failed_slugs, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:collector_runs, [:ran_at])
  end
end
