defmodule CleatDeployWeb.PageControllerTest do
  use CleatDeployWeb.ConnCase

  import CleatDeployWeb.ConnCase, only: [log_in_user: 2]
  import CleatDeploy.AccountsFixtures

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "GET / renders dashboard when authenticated", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/")

    assert html_response(conn, 200) =~ "Cleat"
  end

  test "serves the manifest that makes the panel open fullscreen", %{conn: conn} do
    manifest = conn |> get(~p"/manifest.webmanifest") |> json_response(200)

    assert manifest["display"] == "fullscreen"
    assert manifest["start_url"] == "/"
    assert manifest["scope"] == "/"
    assert Enum.any?(manifest["icons"], &(&1["sizes"] == "192x192"))
    assert Enum.any?(manifest["icons"], &(&1["sizes"] == "512x512"))
  end

  test "serves the pass-through service worker", %{conn: conn} do
    conn = get(conn, ~p"/sw.js")

    assert response(conn, 200) =~ "addEventListener(\"fetch\""
  end

  test "links the manifest and the iOS standalone meta tags", %{conn: conn} do
    conn =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/")

    response = html_response(conn, 200)

    assert response =~ ~s(rel="manifest")
    assert response =~ ~s(name="mobile-web-app-capable")
    assert response =~ ~s(name="apple-mobile-web-app-capable")
  end

  # `~p` (and `asset_path/static_path`) turns a static path into
  # `/<name>-<digest>?vsn=d` as soon as the release ships a cache manifest, which
  # only happens in a digested build — and `Plug.Static` refuses a digested name
  # whose first segment is not in the `:only` list, so
  # `/manifest-<digest>.webmanifest` answers 404. The rendered HTML cannot catch
  # it in test env, hence the template assertion.
  test "keeps the manifest link out of the asset digest" do
    template = File.read!("lib/cleat_deploy_web/components/layouts/root.html.heex")

    assert template =~ ~s(href="/manifest.webmanifest")
    refute template =~ ~s(~p"/manifest.webmanifest")
  end
end
