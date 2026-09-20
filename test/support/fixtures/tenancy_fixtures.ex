defmodule CleatDeploy.TenancyFixtures do
  @moduledoc false

  alias CleatDeploy.{Apps, Servers}
  alias CleatDeploy.Accounts
  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.AccountsFixtures

  def scope_fixture(attrs \\ %{}) do
    {:ok, %{user: user, tenant: tenant}} =
      attrs
      |> AccountsFixtures.valid_user_attributes()
      |> Accounts.register_user_with_tenant()

    Scope.for_user(user, tenant, "owner")
  end

  def server_fixture(scope, attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      name: "#{Faker.Company.name()} #{suffix}",
      host_ip: Faker.Internet.ip_v4_address(),
      ssh_user: "ubuntu",
      region: "us-east-1"
    }

    {:ok, server} = Servers.create_server(scope, Map.merge(defaults, attrs))
    server
  end

  def app_fixture(scope, server, attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      name: Faker.Company.name(),
      slug: "app-#{suffix}",
      github_repo: "#{Faker.Internet.user_name()}/#{Faker.Internet.slug()}-#{suffix}",
      host: "#{Faker.Internet.slug()}-#{suffix}.example.com",
      server_id: server.id
    }

    {:ok, app, _webhook_status} = Apps.create_app(scope, Map.merge(defaults, attrs))
    Apps.get_app!(scope, app.id)
  end
end
