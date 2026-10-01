defmodule CleatDeploy.Deploy.Ssh.Clone do
  @moduledoc false

  alias CleatDeploy.Deploy.Ssh.Session

  @sha40 ~r/\A[0-9a-fA-F]{40}\z/

  @doc """
  Classifies `git_ref` as a full commit SHA or a branch name.

  A 40-hex string is not a remote branch: `git clone -b <sha>` fails. Callers
  clone `default_branch` and then fetch/checkout the commit.
  """
  def git_clone_plan(git_ref, default_branch) when git_ref in [nil, ""] do
    {:branch, default_branch}
  end

  def git_clone_plan(git_ref, default_branch) when is_binary(git_ref) do
    if Regex.match?(@sha40, git_ref) do
      {:sha, default_branch, String.downcase(git_ref)}
    else
      {:branch, git_ref}
    end
  end

  def clone_repo(github_repo, plan) do
    dir = Session.temp_path("cleat_deploy_clone")
    _ = File.rm_rf(dir)
    url = github_clone_url(github_repo)

    case do_clone(url, dir, plan) do
      {:ok, _output} ->
        {:ok, dir}

      {:error, output} ->
        _ = File.rm_rf(dir)
        {:error, "git clone failed:\n" <> output}
    end
  end

  defp github_clone_url(repo) do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        "https://x-access-token:#{token}@github.com/#{repo}.git"

      _ ->
        "https://github.com/#{repo}.git"
    end
  end

  defp do_clone(url, dir, {:branch, branch}) do
    Session.cmd("git", ["clone", "--depth", "50", "-b", branch, url, dir])
  end

  defp do_clone(url, dir, {:sha, branch, sha}) do
    with {:ok, _} <- Session.cmd("git", ["clone", "--depth", "50", "-b", branch, url, dir]),
         {:ok, _} <- Session.cmd("git", ["-C", dir, "fetch", "--depth", "1", "origin", sha]) do
      Session.cmd("git", ["-C", dir, "checkout", "--force", sha])
    end
  end
end
