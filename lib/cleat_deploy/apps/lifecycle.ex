defmodule CleatDeploy.Apps.Lifecycle do
  @moduledoc """
  Create, update and delete apps, keeping remote resources in sync.
  """

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.{App, Policy, Ports, Webhooks}
  alias CleatDeploy.Repo

  def change_app(app, attrs \\ %{}) do
    App.changeset(app, attrs)
  end

  def change_branch(app, attrs \\ %{}) do
    App.branch_changeset(app, attrs)
  end

  def create_app(%Scope{tenant: tenant} = scope, attrs) do
    with :ok <- Policy.authorize_write(scope) do
      attrs =
        attrs
        |> stringify_keys()
        |> Map.put("tenant_id", tenant.id)
        |> inherit_webhook_secret(tenant)
        |> Ports.assign_free_port()

      with {:ok, app} <-
             %App{}
             |> App.changeset(attrs)
             |> Repo.insert() do
        {status, app} = Webhooks.sync_github_webhook(app)
        {:ok, app, status}
      end
    end
  end

  # The push hook lives on the repository, so a second instance of the same repo
  # signs its pushes with the secret the existing hook already carries.
  defp inherit_webhook_secret(%{"github_repo" => repo} = attrs, tenant)
       when is_binary(repo) and repo != "" do
    case attrs["webhook_secret"] do
      secret when is_binary(secret) and secret != "" ->
        attrs

      _ ->
        secret =
          Repo.one(
            from a in App,
              where: a.tenant_id == ^tenant.id and a.github_repo == ^repo,
              order_by: [asc: a.id],
              limit: 1,
              select: a.webhook_secret
          )

        if is_binary(secret), do: Map.put(attrs, "webhook_secret", secret), else: attrs
    end
  end

  defp inherit_webhook_secret(attrs, _tenant), do: attrs

  @doc """
  Updates an app. Only `:branch` is applied — other keys are ignored.
  """
  def update_app(%Scope{tenant: tenant} = scope, %App{tenant_id: tenant_id} = app, attrs)
      when tenant_id == tenant.id do
    with :ok <- Policy.authorize_write(scope) do
      app
      |> App.branch_changeset(Map.take(stringify_keys(attrs), ["branch"]))
      |> Repo.update()
    end
  end

  def update_app(%Scope{}, %App{}, _attrs), do: {:error, :unauthorized}

  @doc """
  Updates deploy settings (`:branch`, `:auto_deploy`, `:idle_shutdown_enabled`,
  `:indexable`, `:host`, `:port`).

  Other keys are ignored.
  """
  def update_app_settings(%Scope{tenant: tenant} = scope, %App{tenant_id: tenant_id} = app, attrs)
      when tenant_id == tenant.id do
    with :ok <- Policy.authorize_write(scope) do
      attrs = stringify_keys(attrs)
      previous_host = app.host
      previous_repo = app.github_repo
      previous_runtime = app.runtime
      previous_unit = app.systemd_unit

      app
      |> App.deploy_settings_changeset(
        Map.take(attrs, [
          "branch",
          "auto_deploy",
          "idle_shutdown_enabled",
          "indexable",
          "host",
          "port",
          "github_repo",
          "runtime",
          "runtime_apt_packages",
          "analytics_inject"
        ])
      )
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          prune_previous_host(updated, previous_host, attrs)
          Webhooks.refresh_after_repo_change(updated, previous_repo)
          prune_previous_unit(updated, previous_runtime, previous_unit)
          {:ok, updated}

        error ->
          error
      end
    end
  end

  def update_app_settings(%Scope{}, %App{}, _attrs), do: {:error, :unauthorized}

  def set_analytics_inject(
        %Scope{tenant: tenant} = scope,
        %App{tenant_id: tenant_id} = app,
        enabled
      )
      when tenant_id == tenant.id and is_boolean(enabled) do
    with :ok <- Policy.authorize_write(scope) do
      app
      |> App.analytics_inject_changeset(%{analytics_inject: enabled})
      |> Repo.update()
    end
  end

  def set_analytics_inject(%Scope{}, %App{}, _), do: {:error, :unauthorized}

  # Changing the runtime re-derives the systemd unit. The old unit keeps running
  # the previous process (and holding the port), so a later deploy of the new
  # unit can never bind and hits the restart limit. Remove it and its extra
  # process units (best-effort).
  defp prune_previous_unit(%App{}, _previous_runtime, previous_unit)
       when previous_unit in [nil, ""],
       do: :ok

  defp prune_previous_unit(%App{} = app, previous_runtime, previous_unit) do
    if app.runtime != previous_runtime and app.systemd_unit != previous_unit do
      app = Repo.preload(app, :server)

      Enum.each(previous_units(app, previous_unit), fn unit ->
        _ = CleatDeploy.Deploy.Teardown.remove_unit(app, unit)
      end)
    end

    :ok
  end

  # The app row already carries the new unit names, so the previous ones are
  # rebuilt from the unit that was in place before the change.
  defp previous_units(%App{} = app, previous_unit) do
    [previous_unit | Enum.map(App.extra_units(app), &"#{previous_unit}-#{&1}")]
  end

  @doc """
  Records the manifest summary resolved by the deploy runner (extra units and
  addons) so the teardown, the systemd probe and the app page know what the last
  deploy set up.
  """
  def record_deploy_manifest(%App{} = app, summary) when is_map(summary) do
    changeset = App.deploy_manifest_changeset(app, summary)

    changeset =
      case summary[:release_name] || summary["release_name"] do
        name when is_binary(name) and name != "" ->
          Ecto.Changeset.put_change(changeset, :release_name, name)

        _ ->
          changeset
      end

    Repo.update(changeset)
  end

  # Changing an app's host provisions a new Caddy site but leaves the old one
  # behind, so remove it (best-effort) once the new host is persisted.
  defp prune_previous_host(%App{} = app, previous_host, attrs) do
    if is_binary(attrs["host"]) and is_binary(previous_host) and previous_host != app.host do
      _ = CleatDeploy.Deploy.Teardown.remove_host(Repo.preload(app, :server), previous_host)
    end

    :ok
  end

  @doc """
  Deletes an app and its deployments/env vars. Best-effort removes the GitHub webhook.
  """
  def delete_app(%Scope{tenant: tenant} = scope, %App{tenant_id: tenant_id} = app)
      when tenant_id == tenant.id do
    with :ok <- Policy.authorize_write(scope) do
      # Best-effort remote cleanup (systemd unit, release dir, Caddy site) so the
      # CLI/API path does not leave orphans behind.
      _ = CleatDeploy.Deploy.Teardown.run(Repo.preload(app, :server))
      _ = Webhooks.delete_webhook(app)
      Repo.delete(app)
    end
  end

  def delete_app(%Scope{}, %App{}), do: {:error, :unauthorized}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
