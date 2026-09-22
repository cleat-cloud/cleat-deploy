defmodule CleatDeploy.Repo.Migrations.AddDeployManifestToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :deploy_manifest, :json, null: false, default: "{}"
    end
  end
end
