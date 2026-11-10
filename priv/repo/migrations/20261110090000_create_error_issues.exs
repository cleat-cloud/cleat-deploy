defmodule CleatDeploy.Repo.Migrations.CreateErrorIssues do
  use Ecto.Migration

  def change do
    create table(:error_issues) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :app_id, references(:apps, on_delete: :delete_all), null: false
      add :fingerprint, :string, null: false
      add :status, :string, null: false, default: "unresolved"
      add :severity, :string, null: false, default: "err"
      add :sample, :text, null: false, default: ""
      add :count, :integer, null: false, default: 0
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :last_deployment_id, references(:deployments, on_delete: :nilify_all)
      add :source, :string, null: false, default: "journal"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:error_issues, [:tenant_id, :app_id, :fingerprint])
    create index(:error_issues, [:tenant_id, :status, :last_seen_at])
    create index(:error_issues, [:app_id, :status])
  end
end
