defmodule CleatDeploy.Repo.Migrations.CreateSignalAlerts do
  use Ecto.Migration

  def change do
    create table(:signal_alerts) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :app_id, references(:apps, on_delete: :delete_all), null: false
      add :rule, :string, null: false
      add :status, :string, null: false, default: "firing"
      add :message, :text, null: false, default: ""
      add :payload, :map, null: false, default: %{}
      add :channel, :string, null: false, default: "in_app"
      add :fired_at, :utc_datetime, null: false
      add :acked_at, :utc_datetime
      add :resolved_at, :utc_datetime
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:signal_alerts, [:tenant_id, :status])
    create index(:signal_alerts, [:app_id, :status])

    create unique_index(:signal_alerts, [:tenant_id, :app_id, :rule],
             where: "status IN ('firing', 'acked')",
             name: :signal_alerts_open_index
           )
  end
end
