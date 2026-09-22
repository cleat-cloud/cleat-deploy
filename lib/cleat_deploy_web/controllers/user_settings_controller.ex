defmodule CleatDeployWeb.UserSettingsController do
  use CleatDeployWeb, :controller

  alias CleatDeploy.Accounts

  @doc """
  Legacy route: account settings live in the `/settings` tabs now.
  """
  def edit(conn, _params) do
    redirect(conn, to: ~p"/settings?tab=account")
  end

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_scope.user, token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email changed successfully.")
        |> redirect(to: ~p"/settings?tab=account")

      {:error, _} ->
        conn
        |> put_flash(:error, "Email change link is invalid or it has expired.")
        |> redirect(to: ~p"/settings?tab=account")
    end
  end
end
