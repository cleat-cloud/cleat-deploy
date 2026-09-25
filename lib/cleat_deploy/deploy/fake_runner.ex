defmodule CleatDeploy.Deploy.FakeRunner do
  @moduledoc false
  @behaviour CleatDeploy.Deploy.Runner

  @impl true
  def interrupt(_app, _deployment), do: :ok

  @impl true
  def deploy(deployment) do
    repo = deployment.app.github_repo
    host = deployment.app.host

    {:ok,
     """
     ==> Connecting to deploy VM
     $ git fetch origin #{deployment.git_ref || deployment.app.branch}
     $ MIX_ENV=prod mix deps.get --only prod
     $ MIX_ENV=prod mix assets.deploy
     $ MIX_ENV=prod mix ecto.migrate
     $ MIX_ENV=prod mix release
     $ sudo systemctl restart phx-#{deployment.app.slug}
     ==> Deployment successful — live at #{host} (#{repo})
     """}
  end
end
