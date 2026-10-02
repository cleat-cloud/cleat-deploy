defmodule CleatDeploy.Analytics.HostsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Analytics.Hosts
  alias CleatDeploy.TenancyFixtures

  test "includes only inject-on apps on that server" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    other = TenancyFixtures.server_fixture(scope)

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "nfe-facil",
      host: "nfe.gestaobem.com",
      port: 4033,
      runtime: "phoenix"
    })

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "memo",
      host: "memo.sites.gestaobem.com",
      port: 4011,
      runtime: "static"
    })

    TenancyFixtures.app_fixture(scope, other, %{
      slug: "chatwoot",
      host: "chat.example.com",
      port: 3000,
      runtime: "rails"
    })

    payload = Hosts.payload(server.id)

    assert payload["nfe.gestaobem.com"] == %{
             "slug" => "nfe-facil",
             "upstream" => "127.0.0.1:4033"
           }

    refute Map.has_key?(payload, "memo.sites.gestaobem.com")
    refute Map.has_key?(payload, "chat.example.com")
  end
end
