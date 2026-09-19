defmodule CleatDeployWeb.Api.LoginThrottleTest do
  use CleatDeployWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:cleat_deploy, :login_throttle_limit)
    Application.put_env(:cleat_deploy, :login_throttle_limit, 2)

    on_exit(fn ->
      if previous do
        Application.put_env(:cleat_deploy, :login_throttle_limit, previous)
      else
        Application.delete_env(:cleat_deploy, :login_throttle_limit)
      end
    end)

    :ok
  end

  test "throttles repeated failed logins" do
    email = "throttle-#{System.unique_integer([:positive])}@example.com"

    assert json_response(login(email), 401)["error"] == "invalid_credentials"
    assert json_response(login(email), 401)["error"] == "invalid_credentials"
    assert json_response(login(email), 429)["error"] == "rate_limited"
  end

  test "throttles per email" do
    a = "throttle-a-#{System.unique_integer([:positive])}@example.com"
    b = "throttle-b-#{System.unique_integer([:positive])}@example.com"

    json_response(login(a), 401)
    json_response(login(a), 401)
    assert json_response(login(a), 429)

    # A different email is not affected.
    assert json_response(login(b), 401)["error"] == "invalid_credentials"
  end

  defp login(email) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/auth/tokens", Jason.encode!(%{email: email, password: "wrong"}))
  end
end
