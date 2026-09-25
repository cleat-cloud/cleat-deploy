defmodule CleatDeployWeb.UserRegistrationControllerTest do
  use CleatDeployWeb.ConnCase

  import CleatDeploy.AccountsFixtures

  describe "GET /users/register" do
    test "renders signup page with form and branding", %{conn: conn} do
      conn = get(conn, ~p"/users/register")
      response = html_response(conn, 200)

      assert response =~ "Create your account"
      assert response =~ "Cleat"
      assert response =~ ~s(id="signup-form")
      assert response =~ ~s(type="email")
      assert response =~ ~s(type="password")
      assert response =~ "Password"
      assert response =~ "Confirm password"
      refute response =~ "magic link"
      assert response =~ "Create account"
      assert response =~ ~p"/users/log-in"
    end

    test "renders link to log in for existing users", %{conn: conn} do
      conn = get(conn, ~p"/users/register")
      response = html_response(conn, 200)

      assert response =~ "Already have an account?"
      assert response =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/users/register")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /users/register" do
    test "creates account and logs the user in", %{conn: conn} do
      email = unique_user_email()
      password = valid_user_password()

      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{
            "email" => email,
            "password" => password,
            "password_confirmation" => password
          }
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert conn.assigns.flash["info"] =~ "Account created successfully"
    end

    test "renders errors for invalid email", %{conn: conn} do
      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{
            "email" => "with spaces",
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      response = html_response(conn, 200)
      assert response =~ "Create your account"
      assert response =~ ~s(id="signup-form")
      assert response =~ "must have the @ sign and no spaces"
    end

    test "renders errors for short password", %{conn: conn} do
      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{
            "email" => unique_user_email(),
            "password" => "short",
            "password_confirmation" => "short"
          }
        })

      response = html_response(conn, 200)
      assert response =~ "should be at least 12 character(s)"
    end

    test "renders errors for password mismatch", %{conn: conn} do
      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{
            "email" => unique_user_email(),
            "password" => valid_user_password(),
            "password_confirmation" => "different password!"
          }
        })

      response = html_response(conn, 200)
      assert response =~ "does not match password"
    end

    test "renders errors for duplicate email", %{conn: conn} do
      %{email: email} = user_fixture()

      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{
            "email" => email,
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      response = html_response(conn, 200)
      assert response =~ "Create your account"
      assert response =~ "has already been taken"
    end

    test "preserves email on validation error", %{conn: conn} do
      email = "invalid-email"

      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{
            "email" => email,
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      response = html_response(conn, 200)

      assert response =~ ~s(value="#{email}")
    end
  end

  describe "when registration is disabled" do
    setup do
      previous = Application.get_env(:cleat_deploy, :allow_registration)
      Application.put_env(:cleat_deploy, :allow_registration, false)

      on_exit(fn ->
        Application.put_env(:cleat_deploy, :allow_registration, previous)
      end)

      :ok
    end

    test "GET /users/register redirects to log in", %{conn: conn} do
      conn = get(conn, ~p"/users/register")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "disabled"
    end

    test "POST /users/register does not create a user or tenant", %{conn: conn} do
      alias CleatDeploy.Repo
      alias CleatDeploy.Accounts.{Tenant, User}

      email = unique_user_email()
      password = valid_user_password()
      users_before = Repo.aggregate(User, :count)
      tenants_before = Repo.aggregate(Tenant, :count)

      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{
            "email" => email,
            "password" => password,
            "password_confirmation" => password
          }
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      assert Repo.aggregate(User, :count) == users_before
      assert Repo.aggregate(Tenant, :count) == tenants_before
      refute CleatDeploy.Accounts.get_user_by_email(email)
    end
  end
end
