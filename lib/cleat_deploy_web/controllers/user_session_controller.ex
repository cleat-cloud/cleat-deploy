defmodule CleatDeployWeb.UserSessionController do
  use CleatDeployWeb, :controller

  alias Phoenix.Flash
  alias CleatDeploy.Accounts
  alias CleatDeploy.LoginThrottle
  alias CleatDeployWeb.UserAuth

  def new(conn, _params) do
    flash = Map.get(conn.assigns, :flash, %{})

    conn =
      if Flash.get(flash, :error) do
        assign(conn, :flash, Map.drop(flash, [:info, "info"]))
      else
        conn
      end

    email = get_in(conn.assigns, [:current_scope, Access.key(:user), Access.key(:email)])
    form = Phoenix.Component.to_form(%{"email" => email}, as: "user")

    render(conn, :new, form: form)
  end

  # magic link login
  def create(conn, %{"user" => %{"token" => token} = user_params} = params) do
    info =
      case params do
        %{"_action" => "confirmed"} -> "User confirmed successfully."
        _ -> "Welcome back!"
      end

    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, _expired_tokens}} ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> render(:new, form: Phoenix.Component.to_form(%{}, as: "user"))
    end
  end

  # email + password login
  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
    case LoginThrottle.check(throttle_key(conn, email)) do
      {:error, :rate_limited} ->
        form = Phoenix.Component.to_form(user_params, as: "user")

        conn
        |> put_status(429)
        |> put_flash(:error, "Too many login attempts. Wait a few minutes and try again.")
        |> render(:new, form: form)

      :ok ->
        if user = Accounts.get_user_by_email_and_password(email, password) do
          flash = Map.get(conn.assigns, :flash, %{})

          conn
          |> assign(:flash, Map.drop(flash, [:error, "error"]))
          |> put_flash(:info, "Welcome back!")
          |> UserAuth.log_in_user(user, user_params)
        else
          form = Phoenix.Component.to_form(user_params, as: "user")

          # Do not disclose whether the email is registered.
          conn
          |> put_flash(:error, "Invalid email or password")
          |> render(:new, form: form)
        end
    end
  end

  def confirm(conn, %{"token" => token}) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = Phoenix.Component.to_form(%{"token" => token}, as: "user")

      conn
      |> assign(:user, user)
      |> assign(:form, form)
      |> render(:confirm)
    else
      conn
      |> put_flash(:error, "Magic link is invalid or it has expired.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  defp throttle_key(conn, email) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    ip <> "|" <> to_string(email || "")
  end
end
