defmodule CleatDeployWeb.FeaturesLiveTest do
  use CleatDeployWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "anonymous visitors" do
    test "renders the public landing page without the panel shell", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/features")

      assert html =~ "Features"
      assert has_element?(view, "#features")
      assert has_element?(view, "#features-apps")
      assert has_element?(view, "#features-sleep")
      assert has_element?(view, "#features-servers")
      assert has_element?(view, "#features-settings")
      assert has_element?(view, "#features-api")

      # Public page: no panel sidebar, and a way in.
      refute has_element?(view, "#app-sidebar")
      refute has_element?(view, "#nav-features")
      assert has_element?(view, "#features-cta")
      assert has_element?(view, ~s(#features-cta a[href="/users/register"]))
      assert has_element?(view, ~s(#features-cta a[href="/users/log-in"]))
      assert has_element?(view, "#theme-toggle-landing")
    end

    test "links each feature to where it lives", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/features")

      assert has_element?(view, ~s(#feature-register-app-open[href="/apps/new"]))
      assert has_element?(view, ~s(#feature-app-list-open[href="/apps"]))
      assert has_element?(view, ~s(#feature-idle-window-open[href="/settings?tab=platform"]))
      assert has_element?(view, ~s(#feature-settings-account-open[href="/settings?tab=account"]))

      # Features without their own page are documented without a link.
      assert has_element?(view, "#feature-wake-on-request")
      assert has_element?(view, "#feature-sweeper")
      refute has_element?(view, "#feature-sweeper-open")
    end

    test "documents the api surface the CLI uses", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/features")

      assert has_element?(view, "#feature-api-auth", "POST /auth/tokens")
      assert has_element?(view, "#feature-api-apps-write", "PATCH /apps/:id")
      assert has_element?(view, "#feature-api-deploys", "POST /apps/:app_id/deployments")
      assert has_element?(view, "#feature-api-servers", "POST /servers/provision")
      assert has_element?(view, "#feature-webhook", "POST /webhooks/github")
    end
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "offers the panel instead of signing up", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/features")

      assert has_element?(view, "#features-cta", "Open panel")
      refute has_element?(view, ~s(#features-cta a[href="/users/register"]))
      assert has_element?(view, "#theme-toggle-landing")
    end
  end
end
