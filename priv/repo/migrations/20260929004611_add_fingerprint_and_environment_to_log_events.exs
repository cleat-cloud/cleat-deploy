defmodule CleatDeploy.Repo.Migrations.AddFingerprintAndEnvironmentToLogEvents do
  use Ecto.Migration

  def change do
    alter table(:log_events) do
      add :environment, :string, null: false, default: ""
      add :fingerprint, :string, null: false, default: ""
    end

    create index(:log_events, [:tenant_id, :fingerprint])
    create index(:log_events, [:tenant_id, :environment])
  end
end
