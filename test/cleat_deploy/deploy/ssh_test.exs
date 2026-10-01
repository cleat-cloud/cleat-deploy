defmodule CleatDeploy.Deploy.SshTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Deploy.Ssh

  test "command/1 quotes each argument so the shell rebuilds the exact argv" do
    argv = ["bash", "-lc", "echo 'hello world' && printf '%s' done"]

    {out, 0} = System.cmd("bash", ["-c", "printf '%s\\n' " <> Ssh.command(argv)])

    assert String.split(out, "\n", trim: true) == argv
  end

  test "git_clone_plan/2 treats a 40-hex git_ref as a commit, not a branch" do
    sha = "e1b61521d8d2767eb23ebef0aed5b1eb4d041d32"

    assert Ssh.git_clone_plan(sha, "main") == {:sha, "main", sha}
    assert Ssh.git_clone_plan(String.upcase(sha), "main") == {:sha, "main", String.downcase(sha)}
    assert Ssh.git_clone_plan("main", "develop") == {:branch, "main"}
    assert Ssh.git_clone_plan(nil, "main") == {:branch, "main"}
    assert Ssh.git_clone_plan("", "main") == {:branch, "main"}
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
