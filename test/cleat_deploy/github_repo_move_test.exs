defmodule CleatDeploy.GithubRepoMoveTest do
  use ExUnit.Case, async: false

  alias CleatDeploy.Github

  @repo "puppe1990/hora-solar"
  @repo_id "1371527531"
  @canonical "gestao-bem/hora-solar"

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token")
    Application.put_env(:cleat_deploy, :github_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous_token do
        System.put_env("GITHUB_TOKEN", previous_token)
      else
        System.delete_env("GITHUB_TOKEN")
      end

      Application.delete_env(:cleat_deploy, :github_req_options)
    end)

    :ok
  end

  test "reports the canonical repo instead of following the redirect of a moved repo" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:github, conn.method, conn.request_path})

      case conn.request_path do
        "/repos/" <> _rest ->
          conn
          |> Plug.Conn.put_resp_header(
            "location",
            "https://api.github.com/repositories/#{@repo_id}/hooks"
          )
          |> Plug.Conn.resp(301, "")

        "/repositories/" <> _rest ->
          Req.Test.json(conn, %{"full_name" => @canonical})
      end
    end)

    assert {:error, {:repo_moved, @canonical}} =
             Github.ensure_webhook(%{github_repo: @repo, webhook_secret: "secret"})

    assert_received {:github, "GET", "/repos/" <> _}
    assert_received {:github, "GET", "/repositories/#{@repo_id}"}
    refute_received {:github, "PATCH", _}
    refute_received {:github, "POST", _}
  end

  test "updates the hook in place when the repo name still matches" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:github, conn.method, conn.request_path})

      case conn.method do
        "GET" -> Req.Test.json(conn, [%{"id" => 7, "config" => %{"url" => Github.webhook_url()}}])
        "PATCH" -> Req.Test.json(conn, %{"id" => 7})
      end
    end)

    assert :ok = Github.ensure_webhook(%{github_repo: @repo, webhook_secret: "secret"})

    assert_received {:github, "GET", "/repos/" <> _}
    assert_received {:github, "PATCH", "/repos/puppe1990/hora-solar/hooks/7"}
  end
end
