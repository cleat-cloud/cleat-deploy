defmodule CleatDeploy.Repo.Migrations.AddExceptionSampleRate do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :exception_sample_rate, :float, null: false, default: 0.0
    end
  end
end
