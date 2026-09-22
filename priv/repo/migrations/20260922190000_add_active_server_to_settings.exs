defmodule CleatDeploy.Repo.Migrations.AddActiveServerToSettings do
  use Ecto.Migration

  # Which server the panel treats as active for the tenant (dashboard card).
  # Nullable: without a choice the panel keeps picking the running/oldest one,
  # and removing a server clears the preference instead of blocking the delete.
  def change do
    alter table(:settings) do
      add :active_server_id, references(:servers, on_delete: :nilify_all)
    end
  end
end
