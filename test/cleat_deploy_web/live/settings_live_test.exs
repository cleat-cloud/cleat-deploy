defmodule CleatDeployWeb.SettingsLiveTest do
  use CleatDeployWeb.ConnCase, async: false

  import CleatDeploy.AccountsFixtures
  import Phoenix.LiveViewTest

  alias CleatDeploy.Accounts
  alias CleatDeploy.Settings
  alias CleatDeploy.TenancyFixtures

  setup :register_and_log_in_user

  describe "tabs" do
    test "lands on the platform tab by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#settings-tabs")
      assert has_element?(view, "#settings-tab-platform[aria-selected]")
      refute has_element?(view, "#settings-tab-account[aria-selected]")
      assert has_element?(view, "#settings-platform")
      refute has_element?(view, "#settings-account")
    end

    test "both tabs live on the same route", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, ~s(#settings-tab-platform[href="/settings?tab=platform"]))
      assert has_element?(view, ~s(#settings-tab-account[href="/settings?tab=account"]))

      view |> element("#settings-tab-account") |> render_click()

      assert_redirect(view, ~p"/settings?tab=account")
    end

    test "renders the account tab from the URL", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings?tab=account")

      assert has_element?(view, "#settings-tab-account[aria-selected]")
      refute has_element?(view, "#settings-tab-platform[aria-selected]")
      assert has_element?(view, "#update_email")
      assert has_element?(view, "#update_password")
      assert html =~ "Update password"
      assert html =~ "Send confirmation link"
      assert html =~ "Signed in as"
      refute has_element?(view, "#settings-platform")
    end

    test "unknown tabs fall back to the platform tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?tab=nope")

      assert has_element?(view, "#settings-platform")
      refute has_element?(view, "#settings-account")
    end
  end

  describe "platform tab" do
    test "renders auto sleep disabled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#nav-settings")
      assert has_element?(view, "#idle-shutdown-form")
      refute has_element?(view, "#idle-shutdown-enabled[checked]")
      assert has_element?(view, ~s(#idle-shutdown-minutes[value="60"]))
    end

    test "saves the idle window for the tenant", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#idle-shutdown-form", %{
          setting: %{idle_shutdown_enabled: true, idle_shutdown_minutes: "15"}
        })
        |> render_submit()

      assert html =~ "Settings saved"
      assert has_element?(view, "#idle-shutdown-enabled[checked]")

      setting = Settings.get_setting(scope)
      assert setting.idle_shutdown_enabled
      assert setting.idle_shutdown_minutes == 15
    end

    test "rejects a window below the minimum", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#idle-shutdown-form", %{
          setting: %{idle_shutdown_enabled: true, idle_shutdown_minutes: "2"}
        })
        |> render_submit()

      assert html =~ "must be greater than or equal to 5"
      refute Settings.get_setting(scope).idle_shutdown_enabled
    end

    test "counts the apps that opted in", %{conn: conn, scope: scope} do
      server = TenancyFixtures.server_fixture(scope)

      TenancyFixtures.app_fixture(scope, server, %{idle_shutdown_enabled: true})
      TenancyFixtures.app_fixture(scope, server)

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#idle-shutdown-hint", "1 app has")
    end
  end

  describe "account tab" do
    test "updates the password and keeps the current browser session", %{
      conn: conn,
      user: user
    } do
      other_token = Accounts.generate_user_session_token(user)
      current_token = get_session(conn, :user_token)

      {:ok, view, _html} = live(conn, ~p"/settings?tab=account")

      html =
        view
        |> form("#update_password", %{
          user: %{password: "new valid password", password_confirmation: "new valid password"}
        })
        |> render_submit()

      assert html =~ "Password updated successfully"
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
      refute Accounts.get_user_by_session_token(other_token)
      assert Accounts.get_user_by_session_token(current_token)
    end

    test "does not update the password on invalid data", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings?tab=account")

      html =
        view
        |> form("#update_password", %{
          user: %{password: "too short", password_confirmation: "does not match"}
        })
        |> render_submit()

      assert html =~ "should be at least 12 character(s)"
      assert html =~ "does not match password"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    @tag :capture_log
    test "sends a confirmation link for the new email", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings?tab=account")

      html =
        view
        |> form("#update_email", user: %{email: unique_user_email()})
        |> render_submit()

      assert html =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "does not update the email on invalid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?tab=account")

      html = view |> form("#update_email", user: %{email: "with spaces"}) |> render_submit()

      assert html =~ "must have the @ sign and no spaces"
    end
  end
end
