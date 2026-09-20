defmodule CleatDeploy.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CleatDeploy.Accounts` context.
  """

  import Ecto.Query

  alias CleatDeploy.Accounts
  alias CleatDeploy.Accounts.Scope

  def unique_user_email,
    do: "#{Faker.Internet.user_name()}#{System.unique_integer([:positive])}@example.com"

  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    attrs = Map.new(attrs)
    password = Map.get(attrs, :password, valid_user_password())

    %{
      email: Map.get(attrs, :email, unique_user_email()),
      password: password,
      password_confirmation: Map.get(attrs, :password_confirmation, password)
    }
    |> Map.merge(attrs)
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    email = Map.get(attrs, :email, unique_user_email())
    {:ok, user} = Accounts.register_user(%{email: email})

    Accounts.ensure_tenant_for_user(user, %{
      name: "Workspace",
      slug: "workspace-#{user.id}"
    })

    user
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, %{user: user}} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user_with_tenant()

    user
  end

  def user_scope_fixture do
    CleatDeploy.TenancyFixtures.scope_fixture()
  end

  def user_scope_fixture(user) do
    Accounts.get_scope_for_user(user) || Scope.for_user(user, nil)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    CleatDeploy.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    CleatDeploy.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    CleatDeploy.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
