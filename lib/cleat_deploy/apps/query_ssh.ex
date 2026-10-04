defmodule CleatDeploy.Apps.QuerySsh do
  @moduledoc false
  @behaviour CleatDeploy.Apps.Query

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.Ssh
  alias CleatDeploy.Servers.HostStats

  @impl true
  def run(%App{} = app, argv) when is_list(argv) do
    server = app.server

    if HostStats.local?(server) do
      run_local(argv)
    else
      Ssh.run(server, app, argv)
    end
  end

  defp run_local(argv) do
    {bin, args} = local_cmd(argv)

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output}
    end
  end

  defp local_cmd(["bash", "-lc", script]), do: {"bash", ["-lc", script]}
  defp local_cmd([bin | args]), do: {bin, args}
end
