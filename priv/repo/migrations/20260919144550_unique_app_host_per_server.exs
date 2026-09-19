defmodule CleatDeploy.Repo.Migrations.UniqueAppHostPerServer do
  use Ecto.Migration

  # Two apps on the same server cannot share a host: Caddy would keep only the
  # first site block and silently serve the wrong app.
  def up do
    execute("UPDATE apps SET host = lower(host)")
    create unique_index(:apps, [:server_id, :host])
  end

  def down do
    drop unique_index(:apps, [:server_id, :host])
  end
end
