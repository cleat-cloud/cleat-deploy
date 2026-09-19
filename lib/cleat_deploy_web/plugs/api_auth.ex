defmodule CleatDeployWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates JSON API requests via `Authorization: Bearer <token>`.

  On success assigns `:current_scope` (a `%CleatDeploy.Accounts.Scope{}`) and
  `:current_api_token`. Halts with a JSON 401 otherwise.
  """

  import Plug.Conn

  alias CleatDeploy.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      nil ->
        unauthorized(conn, "missing_bearer_token")

      token ->
        case Accounts.get_scope_by_api_token(token) do
          {%{} = scope, api_token} ->
            conn
            |> assign(:current_scope, scope)
            |> assign(:current_api_token, api_token)

          nil ->
            unauthorized(conn, "invalid_or_revoked_token")
        end
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> normalize(token)
      ["bearer " <> token] -> normalize(token)
      _ -> nil
    end
  end

  defp normalize(token) do
    case String.trim(token) do
      "" -> nil
      value -> value
    end
  end

  defp unauthorized(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: reason}))
    |> halt()
  end
end
