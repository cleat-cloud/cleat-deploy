import Config

config :swoosh, :api_client, false

config :cleat_deploy, CleatDeploy.Mailer, adapter: Swoosh.Adapters.Test

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cleat_deploy, CleatDeploy.Repo,
  database: Path.expand("../cleat_deploy_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  busy_timeout: 10_000,
  journal_mode: :wal

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cleat_deploy, CleatDeployWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3l7wR1Z+aIhEaOKcl7otQbgdMIK7pDQRgLvpCCd0DcS/5eQoze+H+FQKo603DYKu",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :cleat_deploy, :auto_deploy_health_on_boot, false
config :cleat_deploy, :dns_resolver, CleatDeploy.Deploy.DnsStub

config :cleat_deploy, Oban,
  engine: Oban.Engines.Lite,
  testing: :manual,
  notifier: Oban.Notifiers.Isolated

config :cleat_deploy, :deploy_runner, CleatDeploy.Deploy.RunnerMock
config :cleat_deploy, :lightsail_client, CleatDeploy.AWS.LightsailMock
config :cleat_deploy, :hetzner_client, CleatDeploy.HetznerMock
config :cleat_deploy, :runtime_logs, CleatDeploy.Apps.RuntimeLogsMock
config :cleat_deploy, :runtime_memory, CleatDeploy.Apps.RuntimeMemoryStub
config :cleat_deploy, :addons, CleatDeploy.Deploy.AddonsStub
config :cleat_deploy, :idle_shutdown_runner, CleatDeploy.Apps.IdleShutdownMock
config :cleat_deploy, :runtime_control_runner, CleatDeploy.Apps.RuntimeControlMock

config :cleat_deploy, CleatDeploy.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "v1", key: :crypto.hash(:sha256, "phoenix-paas-test-vault-v1")
    }
  ]
