# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cleat_deploy, :scopes,
  user: [
    default: true,
    module: CleatDeploy.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: CleatDeploy.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :cleat_deploy,
  ecto_repos: [CleatDeploy.Repo],
  generators: [timestamp_type: :utc_datetime]

config :cleat_deploy, :lightsail_client, CleatDeploy.AWS.Lightsail.Stub
config :cleat_deploy, :hetzner_client, CleatDeploy.Hetzner.Stub
config :cleat_deploy, :runtime_logs, CleatDeploy.Apps.RuntimeLogsSsh
config :cleat_deploy, :runtime_memory, CleatDeploy.Apps.RuntimeLogsSsh
config :cleat_deploy, :idle_shutdown_runner, CleatDeploy.Apps.IdleShutdownSsh
config :cleat_deploy, :runtime_control_runner, CleatDeploy.Apps.RuntimeControlSsh

config :cleat_deploy, :auto_deploy_health_on_boot, true

# Git-less "drop" uploads (CLEAT_DROPS_DIR / CLEAT_DROP_MAX_BYTES override at runtime).
config :cleat_deploy, :drop_max_bytes, 52_428_800

# Failed token requests allowed per IP+email per 5-minute window.
config :cleat_deploy, :login_throttle_limit, 10

config :cleat_deploy, Oban,
  repo: CleatDeploy.Repo,
  engine: Oban.Engines.Lite,
  prefix: false,
  notifier: Oban.Notifiers.Isolated,
  peer: Oban.Peers.Isolated,
  # Two hosts × two concurrent builds each. Same-host cap lives in claim_running.
  queues: [deploys: 4, maintenance: 1],
  # Built-in Stager dies on Turso SQLITE_BUSY; SafeStager retries instead.
  stage_interval: :infinity,
  plugins: [
    Oban.Plugins.Pruner,
    CleatDeploy.Oban.SafeStager,
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", CleatDeploy.Workers.AutoDeployHealthWorker},
       {"*/5 * * * *", CleatDeploy.Workers.IdleShutdownWorker}
     ]}
  ],
  shutdown_grace_period: :timer.minutes(15)

# Configure the endpoint
config :cleat_deploy, CleatDeployWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CleatDeployWeb.ErrorHTML, json: CleatDeployWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CleatDeploy.PubSub,
  live_view: [signing_salt: "lEUtsEZC"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  cleat_deploy: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  cleat_deploy: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
