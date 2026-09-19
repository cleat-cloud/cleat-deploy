defmodule CleatDeploy.Repo.Migrations.AddSourceToDeployments do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :source, :string, null: false, default: "git"
      add :artifact_path, :string
    end
  end
end
