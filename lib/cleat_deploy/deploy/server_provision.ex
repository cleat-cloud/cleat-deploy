defmodule CleatDeploy.Deploy.ServerProvision do
  @moduledoc """
  Public entrypoint for the server-side provision scripts.

  Dispatches to the `CleatDeploy.Deploy.Provision.*` modules and keeps the API
  used by the deploy runners stable.
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Provision.{Account, Caddy, Golang, Phoenix, Release, Service, Static}

  @doc false
  def provision_script(%App{} = app, config, %AppManifest{runtime: "golang"} = manifest),
    do: Golang.provision_script(app, config, manifest)

  def provision_script(%App{} = app, config, %AppManifest{runtime: "static"} = manifest),
    do: Static.provision_script(app, config, manifest)

  def provision_script(%App{} = app, config, %AppManifest{runtime: runtime} = manifest)
      when runtime in ["node", "rails", "rust", "gleam"],
      do: Service.provision_script(app, config, manifest)

  def provision_script(%App{} = app, config, %AppManifest{runtime: "phoenix"} = manifest),
    do: Phoenix.provision_script(app, config, manifest)

  def provision_script(%App{} = app, config, %AppManifest{} = manifest),
    do: Phoenix.default_provision_script(app, config, manifest)

  defdelegate phoenix_ownership_script(app, config, manifest), to: Account
  defdelegate service_ownership_script(app, config, manifest), to: Account
  defdelegate service_user(slug), to: Account
  defdelegate phoenix_service_user(slug), to: Account

  defdelegate restart_units_script(config, manifest), to: Service
  defdelegate extra_start_commands(manifest, config), to: Service
  defdelegate start_script(), to: Service

  defdelegate caddy_strip_awk(), to: Caddy, as: :strip_awk

  defdelegate migrate_script(config), to: Release
  defdelegate release_command_script(app, config, manifest), to: Release
  defdelegate prune_releases_script(release_path), to: Release
  defdelegate prune_releases_keep_script(release_path, keep \\ 5), to: Release
  defdelegate clean_release_script(release_path), to: Release
  defdelegate reload_caddy_script(), to: Release
end
