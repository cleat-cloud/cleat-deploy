defmodule CleatDeploy.Repo.Migrations.AddBranchScopeToAppEnvVars do
  use Ecto.Migration

  # A variable applies either to every branch a deploy can target ("*") or to a
  # single branch name. "*" is not a valid git branch, so it never collides with
  # a real ref and keeps the upsert conflict target a plain unique index.
  def change do
    alter table(:app_env_vars) do
      add :branch, :string, null: false, default: "*"
    end

    drop_if_exists unique_index(:app_env_vars, [:app_id, :key])
    create unique_index(:app_env_vars, [:app_id, :key, :branch])
  end
end
