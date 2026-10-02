defmodule CleatDeploy.Repo.Migrations.AddAppsAnalyticsInject do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :analytics_inject, :boolean, null: false, default: false
    end

    execute(
      """
      UPDATE apps
      SET analytics_inject = 1
      WHERE runtime != 'static'
         OR slug IN ('cleat', 'cleat-paas', 'fagulha')
      """,
      """
      UPDATE apps SET analytics_inject = 0
      """
    )
  end
end
