defmodule CleatDeploy.Repo.Migrations.AddIdleShutdownToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :idle_shutdown_enabled, :boolean, null: false, default: false
    end
  end
end
