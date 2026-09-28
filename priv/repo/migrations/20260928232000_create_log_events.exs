defmodule CleatDeploy.Repo.Migrations.CreateLogEvents do
  use Ecto.Migration

  def change do
    create table(:log_events) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :app_id, references(:apps, on_delete: :delete_all)
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :deployment_id, references(:deployments, on_delete: :nilify_all)

      add :source, :string, null: false, default: "app"
      add :unit, :string, null: false, default: ""
      add :cursor, :string, null: false
      add :severity, :string, null: false, default: "info"
      add :message, :text, null: false, default: ""
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:log_events, [:server_id, :cursor])
    create index(:log_events, [:tenant_id, :occurred_at])
    create index(:log_events, [:app_id, :occurred_at])
    create index(:log_events, [:server_id, :occurred_at])
    create index(:log_events, [:deployment_id])
  end
end
