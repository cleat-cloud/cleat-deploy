defmodule CleatDeployWeb.Plugs.ApiRole do
  @moduledoc """
  Authorizes an authenticated API request against the token's tenant role.

  Expects `:current_scope` to be set by `CleatDeployWeb.Plugs.ApiAuth`. Halts
  with a JSON 403 when the role is not allowed.
  """

  import Plug.Conn

  alias CleatDeploy.Accounts.Scope

  def init(opts), do: opts

  def call(conn, opts) do
    roles = Keyword.get(opts, :roles, [])

    case conn.assigns[:current_scope] do
      %Scope{role: role} ->
        if role in roles, do: conn, else: forbidden(conn)

      _ ->
        forbidden(conn)
    end
  end

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    |> halt()
  end
end
