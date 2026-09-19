defmodule CleatDeploy.Deploy.SshRunner do
  @moduledoc """
  SSH-based deploy runner for Hetzner and Lightsail targets.

  Clones the GitHub repo, uploads source, builds the OTP release on the VM,
  runs migrations, and restarts systemd — mirroring `scripts/deploy/update.sh`.
  """
  @behaviour CleatDeploy.Deploy.Runner

  alias CleatDeploy.{Apps, Deployments}
  alias CleatDeploy.Deploy.Ssh

  @impl true
  def deploy(deployment) do
    deployment = Deployments.get_deployment!(deployment.id)
    app = Apps.get_app!(deployment.app_id)
    server = app.server

    case deployment.source do
      "drop" -> Ssh.run_drop(deployment, app, server)
      _ -> Ssh.run_deploy(deployment, app, server)
    end
  end
end
