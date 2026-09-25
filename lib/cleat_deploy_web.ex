defmodule CleatDeployWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use CleatDeployWeb, :controller
      use CleatDeployWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths,
    do: ~w(assets fonts images favicon.ico favicon.png robots.txt manifest.webmanifest sw.js)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: CleatDeployWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: CleatDeployWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import CleatDeployWeb.CoreComponents
      import CleatDeployWeb.PaasComponents
      import CleatDeployWeb.PaasComponents.Badges
      import CleatDeployWeb.PaasComponents.Copy
      import CleatDeployWeb.PaasComponents.Charts
      import CleatDeployWeb.PaasComponents.Bars
      import CleatDeployWeb.PaasComponents.Terminal
      import CleatDeployWeb.PaasComponents.RepoPicker

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias CleatDeployWeb.Layouts
      alias CleatDeployWeb.PaasShell

      import CleatDeployWeb.AssetHelpers, only: [asset_path: 1]

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: CleatDeployWeb.Endpoint,
        router: CleatDeployWeb.Router,
        statics: CleatDeployWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
