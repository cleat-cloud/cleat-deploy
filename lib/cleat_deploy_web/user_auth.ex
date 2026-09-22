defmodule CleatDeployWeb.UserAuth do
  use CleatDeployWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  require Logger

  alias CleatDeploy.Accounts
  alias CleatDeploy.Accounts.{Scope, Tenant, User}

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_cleat_deploy_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      CleatDeployWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    conn =
      case ensure_user_token(conn) do
        {token, conn} ->
          put_token_in_session(conn, token)

        nil ->
          conn
      end

    session = get_session(conn)

    case resolve_current_scope(session) do
      {%Scope{} = scope, user, token_inserted_at} when not is_nil(token_inserted_at) ->
        conn
        |> assign(:current_scope, scope)
        |> maybe_reissue_user_session_token(user, token_inserted_at)

      {%Scope{} = scope, _, _} ->
        assign(conn, :current_scope, scope)

      nil ->
        assign(conn, :current_scope, nil)
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> put_session(:user_id, user.id)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) do
    case conn.assigns[:current_scope] do
      %Scope{user: %User{id: id}} when id == user.id -> conn
      _ -> renew_session_fresh(conn)
    end
  end

  defp renew_session_fresh(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) when is_binary(token) do
    put_session(conn, :user_token, encode_session_token(token))
  end

  defp encode_session_token(token) when is_binary(token) do
    token
    |> Accounts.normalize_session_token()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Plug for routes that require sudo mode.
  """
  def require_sudo_mode(conn, _opts) do
    if Accounts.sudo_mode?(conn.assigns.current_scope.user, -10) do
      conn
    else
      conn
      |> put_flash(:error, "You must re-authenticate to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  @doc """
  Plug for routes that require the user to not be authenticated.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if authenticated_scope?(conn.assigns.current_scope) do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  defp signed_in_path(_conn), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if authenticated_scope?(conn.assigns.current_scope) do
      conn
    else
      conn =
        if landing_entry?(conn) do
          # The root doubles as the marketing entry point; do not greet a first
          # time visitor with an error toast, just show what Cleat does.
          drop_flash(conn, :info)
        else
          conn
          |> drop_flash(:info)
          |> put_flash(:error, "You must log in to access this page.")
        end

      conn
      |> maybe_store_return_to()
      |> redirect(to: unauthenticated_redirect_to(conn))
      |> halt()
    end
  end

  defp landing_entry?(%{request_path: "/"}), do: true
  defp landing_entry?(_conn), do: false

  defp unauthenticated_redirect_to(%{request_path: "/"}), do: ~p"/features"
  defp unauthenticated_redirect_to(_conn), do: ~p"/users/log-in"

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp authenticated_scope?(%Scope{user: %User{}, tenant: %Tenant{}}), do: true
  defp authenticated_scope?(_), do: false

  @doc """
  LiveView on_mount hooks for session-based authentication.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session, socket)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session, socket)

    if authenticated_scope?(socket.assigns.current_scope) do
      {:cont, socket}
    else
      log_auth_failure(session, socket, "liveview_mount")

      socket =
        socket
        |> Phoenix.LiveView.clear_flash(:info)
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session, connect_socket) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      case resolve_current_scope(session, connect_socket) do
        {%Scope{} = scope, _, _} -> scope
        nil -> nil
      end
    end)
  end

  defp resolve_current_scope(session, connect_socket \\ nil) do
    token = session_user_token(session, connect_socket)

    case token && Accounts.get_user_by_session_token(token) do
      {user, token_inserted_at} ->
        {Accounts.ensure_scope_for_user(user), user, token_inserted_at}

      _ ->
        case scope_from_user_id(session) do
          %Scope{} = scope -> {scope, scope.user, nil}
          nil -> nil
        end
    end
  end

  defp scope_from_user_id(session) do
    case session_user_id(session) do
      nil ->
        nil

      user_id ->
        case Accounts.get_user(user_id) do
          %User{} = user -> Accounts.ensure_scope_for_user(user)
          nil -> nil
        end
    end
  end

  defp session_user_token(session, socket) do
    session["user_token"] || session[:user_token] || remember_me_token(socket)
  end

  defp session_user_id(session) do
    case session["user_id"] || session[:user_id] do
      id when is_integer(id) -> id
      id when is_binary(id) -> String.to_integer(id)
      _ -> nil
    end
  end

  defp remember_me_token(socket) do
    with %_{} <- socket,
         true <- Phoenix.LiveView.connected?(socket),
         cookies when is_map(cookies) <- connect_cookies(socket),
         token when is_binary(token) and token != "" <- Map.get(cookies, @remember_me_cookie) do
      token
    else
      _ -> nil
    end
  end

  defp connect_cookies(socket) do
    Phoenix.LiveView.get_connect_info(socket, :cookies)
  rescue
    _ -> nil
  end

  defp log_auth_failure(session, socket, context) do
    connected? = socket && Phoenix.LiveView.connected?(socket)

    Logger.warning(
      "auth failed context=#{context} connected=#{connected?} " <>
        "has_user_token=#{session_user_token(session, socket) != nil} " <>
        "has_user_id=#{session_user_id(session) != nil}"
    )
  end

  defp drop_flash(conn, key) do
    flash = Map.get(conn.assigns, :flash, %{})
    assign(conn, :flash, Map.drop(flash, [key, Atom.to_string(key)]))
  end
end
