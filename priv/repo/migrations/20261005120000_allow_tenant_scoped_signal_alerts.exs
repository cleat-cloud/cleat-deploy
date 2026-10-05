defmodule CleatDeploy.Repo.Migrations.AllowTenantScopedSignalAlerts do
  use Ecto.Migration

  # SQLite cannot drop NOT NULL in place, so the table is rebuilt. `app_id` NULL
  # anchors tenant-wide rules (ingest_stale) that do not belong to a single app.
  def up do
    create table(:signal_alerts_rebuild) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :app_id, references(:apps, on_delete: :delete_all)
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

    execute """
    INSERT INTO signal_alerts_rebuild (id, tenant_id, app_id, rule, status, message, payload, channel, fired_at, acked_at, resolved_at, delivered_at, inserted_at, updated_at)
    SELECT id, tenant_id, app_id, rule, status, message, payload, channel, fired_at, acked_at, resolved_at, delivered_at, inserted_at, updated_at
    FROM signal_alerts
    """

    drop table(:signal_alerts)
    rename table(:signal_alerts_rebuild), to: table(:signal_alerts)

    create index(:signal_alerts, [:tenant_id, :status])
    create index(:signal_alerts, [:app_id, :status])

    create unique_index(:signal_alerts, [:tenant_id, :app_id, :rule],
             where: "status IN ('firing', 'acked')",
             name: :signal_alerts_open_index
           )
  end

  def down do
    execute "DELETE FROM signal_alerts WHERE app_id IS NULL"

    create table(:signal_alerts_rebuild) do
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

    execute """
    INSERT INTO signal_alerts_rebuild (id, tenant_id, app_id, rule, status, message, payload, channel, fired_at, acked_at, resolved_at, delivered_at, inserted_at, updated_at)
    SELECT id, tenant_id, app_id, rule, status, message, payload, channel, fired_at, acked_at, resolved_at, delivered_at, inserted_at, updated_at
    FROM signal_alerts
    """

    drop table(:signal_alerts)
    rename table(:signal_alerts_rebuild), to: table(:signal_alerts)

    create index(:signal_alerts, [:tenant_id, :status])
    create index(:signal_alerts, [:app_id, :status])

    create unique_index(:signal_alerts, [:tenant_id, :app_id, :rule],
             where: "status IN ('firing', 'acked')",
             name: :signal_alerts_open_index
           )
  end
end
