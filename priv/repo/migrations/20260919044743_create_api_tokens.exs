defmodule CleatDeploy.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :name, :string, null: false, default: "default"
      add :token, :binary, null: false, size: 32
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:api_tokens, [:user_id])
    create index(:api_tokens, [:tenant_id])
    create unique_index(:api_tokens, [:token])
  end
end
