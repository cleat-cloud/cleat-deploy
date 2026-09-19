defmodule CleatDeployWeb.Api.AuthController do
  @moduledoc """
  Token endpoints for the `cleat` CLI.

  `POST /api/v1/auth/tokens` exchanges email/password for a bearer token.
  `DELETE /api/v1/auth/tokens` revokes the token used in the request.
  """

  use CleatDeployWeb, :controller

  alias CleatDeploy.Accounts
  alias CleatDeploy.Accounts.User
  alias CleatDeploy.LoginThrottle
  alias CleatDeployWeb.Api.Serializer

  def create(conn, params) do
    case LoginThrottle.check(throttle_key(conn, params)) do
      {:error, :rate_limited} ->
        conn
        |> put_status(429)
        |> json(%{error: "rate_limited"})

      :ok ->
        do_create(conn, params)
    end
  end

  defp do_create(conn, params) do
    with {:ok, email, password} <- credentials(params),
         %User{} = user <- Accounts.get_user_by_email_and_password(email, password),
         %{} = scope <- Accounts.ensure_scope_for_user(user),
         {:ok, raw, token} <-
           Accounts.create_api_token(user, scope.tenant, %{name: params["name"]}) do
      conn
      |> put_status(:created)
      |> json(%{
        token: raw,
        token_id: token.id,
        user: Serializer.user(user),
        tenant: Serializer.tenant(scope.tenant)
      })
    else
      {:error, :invalid_credentials} ->
        unauthorized(conn, "invalid_credentials")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request", details: errors(changeset)})

      nil ->
        unauthorized(conn, "invalid_credentials")
    end
  end

  def delete(conn, _params) do
    token = conn.assigns.current_api_token

    case Accounts.revoke_api_token(conn.assigns.current_scope.user, token.id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, _reason} -> unauthorized(conn, "invalid_or_revoked_token")
    end
  end

  def me(conn, _params) do
    json(conn, %{data: Serializer.scope(conn.assigns.current_scope)})
  end

  defp throttle_key(conn, params) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    ip <> "|" <> to_string(params["email"] || "")
  end

  defp credentials(params) do
    email = params["email"]
    password = params["password"]

    if is_binary(email) and is_binary(password) and email != "" and password != "" do
      {:ok, email, password}
    else
      {:error, :invalid_credentials}
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp unauthorized(conn, reason) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: reason})
  end
end
