defmodule CleatDeploy.Repo.Migrations.AllowAppsPerRepoAndBranch do
  use Ecto.Migration

  # One app per repository kept instances from sharing a repo. Instances are the
  # same project deployed from another branch, so uniqueness moves to
  # (tenant, repo, branch): `purplestock` (main) and `purplestock-staging`
  # (staging) coexist while a duplicated branch is still rejected.
  def up do
    drop_if_exists unique_index(:apps, [:tenant_id, :github_repo],
                     name: :apps_tenant_id_github_repo_index
                   )

    create unique_index(:apps, [:tenant_id, :github_repo, :branch],
             where: "github_repo != ''",
             name: :apps_tenant_id_github_repo_branch_index
           )
  end

  def down do
    drop_if_exists unique_index(:apps, [:tenant_id, :github_repo, :branch],
                     name: :apps_tenant_id_github_repo_branch_index
                   )

    create unique_index(:apps, [:tenant_id, :github_repo],
             where: "github_repo != ''",
             name: :apps_tenant_id_github_repo_index
           )
  end
end
