import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/cleat_deploy start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") && config_env() != :test do
  config :cleat_deploy, CleatDeployWeb.Endpoint, server: true
end

if config_env() != :test do
  config :cleat_deploy, CleatDeployWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]

  deploy_runner =
    case System.get_env("DEPLOY_RUNNER", "fake") do
      "ssh" -> CleatDeploy.Deploy.SshRunner
      _ -> CleatDeploy.Deploy.FakeRunner
    end

  config :cleat_deploy, :deploy_runner, deploy_runner

  lightsail_client =
    if System.get_env("AWS_ACCESS_KEY_ID") in [nil, ""] do
      CleatDeploy.AWS.Lightsail.Stub
    else
      CleatDeploy.AWS.Lightsail.ExAwsClient
    end

  config :cleat_deploy, :lightsail_client, lightsail_client

  hetzner_client =
    if System.get_env("HCLOUD_TOKEN") in [nil, ""] and
         System.get_env("HETZNER_API_TOKEN") in [nil, ""] do
      CleatDeploy.Hetzner.Stub
    else
      CleatDeploy.Hetzner.Client
    end

  config :cleat_deploy, :hetzner_client, hetzner_client
end

if config_env() == :prod do
  config :cleat_deploy,
         :allow_registration,
         System.get_env("ALLOW_REGISTRATION", "false") in ~w(1 true TRUE)

  config :cleat_deploy, CleatDeploy.Repo, CleatDeploy.Config.Turso.repo_config()

  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise "environment variable CLOAK_KEY is missing (32-byte base64 key)"

  config :cleat_deploy, CleatDeploy.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "v1", key: Base.decode64!(cloak_key)}
    ]

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :cleat_deploy, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :cleat_deploy, CleatDeployWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :cleat_deploy, CleatDeployWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :cleat_deploy, CleatDeployWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
