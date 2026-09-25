defmodule CleatDeployWeb.UserSessionControllerTest do
  use CleatDeployWeb.ConnCase

  import CleatDeploy.AccountsFixtures
  alias CleatDeploy.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "GET /users/log-in" do
    test "renders login page", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in")
      response = html_response(conn, 200)
      assert response =~ "Log in"
      assert response =~ ~p"/users/register"
      assert response =~ ~s(id="login_form")
      assert response =~ "Password"
      assert response =~ ~s(data-password-toggle)
      assert response =~ "hero-eye"
      refute response =~ "Log in with email"
      assert response =~ ~s(id="signup-link")
      assert response =~ "Create account"
      assert response =~ ~s(id="theme-toggle-auth")
    end

    test "hides signup when registration is disabled", %{conn: conn} do
      previous = Application.get_env(:cleat_deploy, :allow_registration)
      Application.put_env(:cleat_deploy, :allow_registration, false)

      on_exit(fn ->
        Application.put_env(:cleat_deploy, :allow_registration, previous)
      end)

      conn = get(conn, ~p"/users/log-in")
      response = html_response(conn, 200)

      refute response =~ ~p"/users/register"
      refute response =~ ~s(id="signup-link")
    end

    test "clears stale welcome flash when session expired", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> put_flash(:info, "Welcome back!")
        |> put_flash(:error, "You must log in to access this page.")

      html = get(conn, ~p"/users/log-in") |> html_response(200)

      refute html =~ "Welcome back!"
      assert html =~ "You must log in to access this page."
    end

    test "renders login page with email filled in (sudo mode)", %{conn: conn, user: user} do
      html =
        conn
        |> log_in_user(user)
        |> get(~p"/users/log-in")
        |> html_response(200)

      assert html =~ "You need to reauthenticate"
      refute html =~ "Sign up"
      refute html =~ "Log in with email"

      assert html =~
               ~s(<input type="email" name="user[email]" id="user_email" value="#{user.email}" class="paas-input w-full" required readonly)
    end
  end

  describe "GET /users/log-in/:token" do
    test "renders confirmation page for unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      conn = get(conn, ~p"/users/log-in/#{token}")
      assert html_response(conn, 200) =~ "Confirm and stay logged in"
    end

    test "renders login page for confirmed user", %{conn: conn, user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      conn = get(conn, ~p"/users/log-in/#{token}")
      html = html_response(conn, 200)
      refute html =~ "Confirm my account"
      assert html =~ "Keep me logged in on this device"
    end

    test "raises error for invalid token", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in/invalid-token")
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Magic link is invalid or it has expired."
    end
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/settings?tab=account"
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_cleat_deploy_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "emits error message with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      response = html_response(conn, 200)
      assert response =~ "Log in"
      assert response =~ "Invalid email or password"
    end

    test "a PWA resubmit after a successful login redirects instead of 403", %{
      conn: conn,
      user: user
    } do
      user = set_password(user)

      login_page = conn |> with_csrf() |> get(~p"/users/log-in")
      csrf = csrf_token(html_response(login_page, 200))

      logged_in =
        login_page
        |> with_csrf()
        |> post(~p"/users/log-in", %{
          "_csrf_token" => csrf,
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(logged_in) == ~p"/"
      assert get_session(logged_in, :user_token)

      # Same form POST as the PWA restore: new session cookie, old CSRF token.
      resent =
        logged_in
        |> recycle()
        |> with_csrf()
        |> post(~p"/users/log-in", %{
          "_csrf_token" => csrf,
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      refute resent.status == 403
      assert redirected_to(resent) == ~p"/"
      assert get_session(resent, :user_token)
    end

    test "a stale CSRF token still 403s when the session is anonymous", %{conn: conn, user: user} do
      user = set_password(user)

      login_page = conn |> with_csrf() |> get(~p"/users/log-in")
      csrf = csrf_token(html_response(login_page, 200))

      assert_error_sent 403, fn ->
        conn
        |> with_csrf()
        |> post(~p"/users/log-in", %{
          "_csrf_token" => csrf,
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })
      end
    end
  end

  describe "POST /users/log-in - magic link token" do
    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/settings?tab=account"
      assert response =~ ~p"/users/log-out"
    end

    test "confirms unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "User confirmed successfully."

      assert Accounts.get_user!(user.id).confirmed_at

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/settings?tab=account"
      assert response =~ ~p"/users/log-out"
    end

    test "emits error message when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert html_response(conn, 200) =~ "The link is invalid or it has expired."
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end

  defp with_csrf(conn) do
    %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}
  end

  defp csrf_token(html) do
    %{"token" => token} =
      Regex.named_captures(~r/name="_csrf_token"[^>]*value="(?<token>[^"]+)"/, html)

    token
  end
end
