defmodule CleatDeploy.Repo.Migrations.AllowDropsWithoutRepo do
  use Ecto.Migration

  # Drop-only static apps carry an empty `github_repo` (the column stays NOT
  # NULL — SQLite cannot alter that without a table rebuild). A partial unique
  # index keeps real repos unique per tenant while allowing many empty ones.
  def change do
    drop_if_exists unique_index(:apps, [:tenant_id, :github_repo])

    create unique_index(:apps, [:tenant_id, :github_repo],
             where: "github_repo != ''",
             name: :apps_tenant_id_github_repo_index
           )
  end
end
