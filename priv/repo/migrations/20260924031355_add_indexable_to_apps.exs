defmodule CleatDeploy.Repo.Migrations.AddIndexableToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :indexable, :boolean, null: false, default: false
    end
  end
end
