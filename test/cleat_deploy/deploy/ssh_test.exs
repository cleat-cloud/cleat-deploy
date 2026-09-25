defmodule CleatDeploy.Deploy.SshTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Deploy.Ssh

  test "command/1 quotes each argument so the shell rebuilds the exact argv" do
    argv = ["bash", "-lc", "echo 'hello world' && printf '%s' done"]

    {out, 0} = System.cmd("bash", ["-c", "printf '%s\\n' " <> Ssh.command(argv)])

    assert String.split(out, "\n", trim: true) == argv
  end

  test "cleanup_stale_identity_files/0 removes leftover PEM paths and leaves other tmp files" do
    leftover =
      Path.join(System.tmp_dir!(), "cleat_deploy_ssh_stale_#{System.unique_integer([:positive])}")

    other = Path.join(System.tmp_dir!(), "cleat_other_#{System.unique_integer([:positive])}")

    File.write!(leftover, "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n")
    File.write!(other, "keep me")

    try do
      Ssh.cleanup_stale_identity_files()
      refute File.exists?(leftover)
      assert File.exists?(other)
    after
      File.rm(leftover)
      File.rm(other)
    end
  end
end
