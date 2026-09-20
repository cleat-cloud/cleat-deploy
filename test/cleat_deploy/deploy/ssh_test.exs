defmodule CleatDeploy.Deploy.SshTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Deploy.Ssh

  test "command/1 quotes each argument so the shell rebuilds the exact argv" do
    argv = ["bash", "-lc", "echo 'hello world' && printf '%s' done"]

    {out, 0} = System.cmd("bash", ["-c", "printf '%s\\n' " <> Ssh.command(argv)])

    assert String.split(out, "\n", trim: true) == argv
  end
end
