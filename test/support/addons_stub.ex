defmodule CleatDeploy.Deploy.AddonsStub do
  @moduledoc false
  @behaviour CleatDeploy.Deploy.Addons

  alias CleatDeploy.Apps.App

  # Every declared addon is up; the detail is the database (Postgres) or the ACL
  # user (Redis), exactly like the real probe reports.
  @impl true
  def run(%App{} = app, _argv) do
    prefix = "cleat_#{String.replace(app.slug, ~r/[^a-zA-Z0-9_]/, "_")}"

    output =
      app
      |> CleatDeploy.Apps.App.deploy_addons()
      |> Enum.map_join("\n", fn
        "redis" -> "CLEAT addon redis ready #{prefix}"
        addon -> "CLEAT addon #{addon} ready #{prefix}"
      end)

    {:ok, output}
  end
end
