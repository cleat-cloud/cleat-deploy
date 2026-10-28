defmodule CleatDeploy.Repo.Migrations.UniqueActiveDeployPerAppSha do
  use Ecto.Migration

  def change do
    create unique_index(:deployments, [:app_id, :git_sha],
             name: :deployments_app_sha_active_index,
             where: "status IN ('queued', 'running') AND git_sha NOT IN ('manual', 'drop')"
           )
  end
end
