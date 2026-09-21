defmodule CleatDeploy.Apps.RuntimeLogsSsh do
  @moduledoc false
  @behaviour CleatDeploy.Apps.RuntimeLogs

  alias CleatDeploy.Deploy.Ssh
  alias CleatDeploy.Servers.Server

  @impl true
  def run(subject, argv) when is_list(argv) do
    server = server_for(subject)

    if local_journal?(server) do
      run_local(argv)
    else
      Ssh.run(server, ssh_subject(subject, server), argv)
    end
  end

  # The subject may be an app (which owns a `:server`) or a bare server.
  defp server_for(%{server: server}), do: server
  defp server_for(server), do: server

  # `Ssh.run/3` resolves the SSH host from the app's public host. A bare server
  # has no `:host`, so fall back to its stored IP.
  defp ssh_subject(%Server{host_ip: host_ip}, _server), do: %{host: host_ip}
  defp ssh_subject(subject, _server), do: subject

  defp local_journal?(server) do
    System.find_executable("journalctl") != nil and local_server?(server)
  end

  defp local_server?(%{host_ip: host_ip}) when is_binary(host_ip) do
    host_ip in local_ipv4s()
  end

  defp local_server?(_), do: false

  defp local_ipv4s do
    case :inet.getifaddrs() do
      {:ok, ifaces} ->
        ifaces
        |> Enum.flat_map(fn {_name, opts} ->
          case Keyword.get(opts, :addr) do
            {a, b, c, d} -> ["#{a}.#{b}.#{c}.#{d}"]
            _ -> []
          end
        end)
        |> Kernel.++(["127.0.0.1"])
        |> Enum.uniq()

      _ ->
        ["127.0.0.1"]
    end
  end

  defp run_local(argv) do
    {bin, args} = local_cmd(argv)

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output}
    end
  end

  defp local_cmd(["sudo", "journalctl" | args]) do
    if running_as_root?() do
      {"journalctl", args}
    else
      {"sudo", ["journalctl" | args]}
    end
  end

  defp local_cmd([bin | args]), do: {bin, args}

  defp running_as_root? do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {"0\n", 0} -> true
      _ -> false
    end
  end
end
