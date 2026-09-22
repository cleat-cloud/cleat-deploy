defmodule CleatDeploy.Apps.IdleShutdownSsh do
  @moduledoc false
  @behaviour CleatDeploy.Apps.IdleShutdown

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.Ssh

  @impl true
  def run(%App{} = app, argv) when is_list(argv) do
    Ssh.run(app.server, app, argv)
  end
end
