defmodule CleatDeployWeb.Router do
  use CleatDeployWeb, :router

  import CleatDeployWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CleatDeployWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug CleatDeployWeb.Plugs.ApiAuth
  end

  pipeline :api_admin do
    plug CleatDeployWeb.Plugs.ApiRole, roles: ["owner", "admin"]
  end

  pipeline :github_webhook do
    plug :accepts, ["json"]
  end

  scope "/api/v1", CleatDeployWeb.Api do
    pipe_through :api

    post "/auth/tokens", AuthController, :create
  end

  scope "/api/v1", CleatDeployWeb.Api do
    pipe_through [:api, :api_auth]

    get "/me", AuthController, :me
    delete "/auth/tokens", AuthController, :delete

    get "/servers", ServerController, :index
    get "/servers/:id", ServerController, :show
    get "/servers/:id/logs", ServerController, :logs
    get "/servers/:id/resize-options", ServerController, :resize_options

    get "/apps", AppController, :index
    get "/apps/:id", AppController, :show

    get "/apps/:app_id/env", EnvController, :index
    get "/apps/:app_id/logs", AppController, :logs
    get "/apps/:app_id/deployments", DeploymentController, :index
    get "/deployments/:id", DeploymentController, :show
  end

  scope "/api/v1", CleatDeployWeb.Api do
    pipe_through [:api, :api_auth, :api_admin]

    post "/apps", AppController, :create
    patch "/apps/:id", AppController, :update
    delete "/apps/:id", AppController, :delete

    post "/servers", ServerController, :create
    post "/servers/provision", ServerController, :provision
    delete "/servers/:id", ServerController, :delete
    post "/servers/:id/sync", ServerController, :sync
    post "/servers/:id/start", ServerController, :start
    post "/servers/:id/stop", ServerController, :stop
    post "/servers/:id/resize", ServerController, :resize

    post "/apps/:app_id/deployments", DeploymentController, :create
    post "/apps/:app_id/cancel", DeploymentController, :cancel
    post "/apps/:app_id/drops", DropController, :create

    put "/apps/:app_id/env", EnvController, :update
    delete "/apps/:app_id/env/:key", EnvController, :delete
  end

  scope "/webhooks", CleatDeployWeb do
    pipe_through :github_webhook

    post "/github", GithubWebhookController, :create
  end

  scope "/", CleatDeployWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: [
        {CleatDeployWeb.UserAuth, :mount_current_scope},
        {CleatDeployWeb.UserAuth, :require_authenticated},
        {CleatDeployWeb.PaasMount, :default}
      ] do
      live "/", DashboardLive, :index
      live "/servers", ServerLive.Index, :index
      live "/servers/new", ServerLive.Index, :new
      live "/servers/:id", ServerLive.Show, :show
      live "/apps", AppLive.Index, :index
      live "/apps/new", AppLive.Index, :new
      live "/apps/:id", AppLive.Show, :show
      live "/apps/:app_id/deployments", AppLive.Deployments, :index
    end
  end

  if Application.compile_env(:cleat_deploy, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CleatDeployWeb.Telemetry
    end
  end

  ## Authentication routes

  scope "/", CleatDeployWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", CleatDeployWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", CleatDeployWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
