defmodule CleatDeploy.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :idle_shutdown_enabled, :boolean, null: false, default: false
      add :idle_shutdown_minutes, :integer, null: false, default: 60

      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings, [:tenant_id])
  end
end
