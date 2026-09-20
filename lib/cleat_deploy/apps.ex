defmodule CleatDeploy.Apps do
  @moduledoc """
  Manages Phoenix apps registered for deployment.
  """

  import Ecto.Query, warn: false
  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Repo
  alias CleatDeploy.Apps.{App, AppEnvVar, Provisioning}
  alias CleatDeploy.Github

  require Logger

  # Ports handed out to apps. Kept below the Linux ephemeral range
  # (32768-60999) so an app never fights with an outgoing connection.
  @port_range 4000..32_767

  def list_apps(%Scope{tenant: tenant}) do
    Repo.all(
      from a in App,
        where: a.tenant_id == ^tenant.id,
        order_by: [asc: a.name],
        preload: [:server]
    )
  end

  def list_app_choices(%Scope{tenant: tenant}) do
    Repo.all(
      from a in App,
        where: a.tenant_id == ^tenant.id,
        order_by: [asc: a.name],
        select: struct(a, [:id, :name, :branch])
    )
  end

  def count_apps(%Scope{tenant: tenant}) do
    Repo.aggregate(from(a in App, where: a.tenant_id == ^tenant.id), :count, :id)
  end

  def count_by_runtime(%Scope{tenant: tenant}) do
    from(a in App,
      where: a.tenant_id == ^tenant.id,
      group_by: a.runtime,
      select: {a.runtime, count(a.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{elixir: 0, go: 0, node: 0, ruby: 0}, fn
      {"golang", n}, acc -> %{acc | go: n}
      {"node", n}, acc -> %{acc | node: n}
      {"rails", n}, acc -> %{acc | ruby: n}
      {_runtime, n}, acc -> %{acc | elixir: acc.elixir + n}
    end)
  end

  def get_app!(id) when is_integer(id) do
    Repo.get!(App, id) |> Repo.preload([:server, :env_vars])
  end

  def get_app!(%Scope{tenant: tenant}, id) do
    Repo.one!(
      from a in App,
        where: a.tenant_id == ^tenant.id and a.id == ^id,
        preload: [:server, :env_vars]
    )
  end

  def get_app_by_repo(github_repo) when is_binary(github_repo) do
    Repo.get_by(App, github_repo: github_repo)
  end

  def get_app_by_slug!(%Scope{tenant: tenant}, slug) when is_binary(slug) do
    Repo.one!(
      from a in App,
        where: a.tenant_id == ^tenant.id and a.slug == ^slug,
        preload: [:server, :env_vars]
    )
  end

  def list_apps_by_repo(github_repo) when is_binary(github_repo) do
    Repo.all(from a in App, where: a.github_repo == ^github_repo)
  end

  def list_all_with_servers do
    Repo.all(from a in App, order_by: [asc: a.slug], preload: [:server])
  end

  def count_apps_by_server_id(%Scope{tenant: tenant}) do
    from(a in App,
      where: a.tenant_id == ^tenant.id,
      group_by: a.server_id,
      select: {a.server_id, count(a.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def create_app(%Scope{tenant: tenant}, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("tenant_id", tenant.id)
      |> assign_free_port()

    with {:ok, app} <-
           %App{}
           |> App.changeset(attrs)
           |> Repo.insert() do
      {status, app} = sync_github_webhook(app)
      {:ok, app, status}
    end
  end

  @doc """
  Returns a port that is free on `server_id`.

  `preferred` is kept when it is already free; otherwise the lowest free port in
  `#{inspect(@port_range)}` is used. This prevents a new app from being assigned
  a port already bound by another app on the same server (EADDRINUSE).
  """
  def allocate_port(server_id, preferred \\ nil) when is_integer(server_id) do
    used = used_ports(server_id)

    if is_integer(preferred) and preferred in @port_range and preferred not in used do
      preferred
    else
      Enum.find(@port_range, &(&1 not in used))
    end
  end

  defp assign_free_port(%{"server_id" => server_id} = attrs) do
    case to_integer(server_id) do
      nil -> attrs
      id -> Map.put(attrs, "port", allocate_port(id, to_integer(attrs["port"])))
    end
  end

  defp assign_free_port(attrs), do: attrs

  defp used_ports(server_id) do
    from(a in App, where: a.server_id == ^server_id, select: a.port)
    |> Repo.all()
    |> MapSet.new()
    |> MapSet.put(panel_port())
  end

  # The panel itself listens on this host's PORT; it is not in the apps table
  # and must never be handed out to an app.
  defp panel_port do
    case System.get_env("PORT") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {port, ""} -> port
          _ -> nil
        end
    end
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_integer(_value), do: nil

  @doc """
  Updates an app. Only `:branch` is applied — other keys are ignored.
  """
  def update_app(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app, attrs)
      when tenant_id == tenant.id do
    app
    |> App.branch_changeset(Map.take(stringify_keys(attrs), ["branch"]))
    |> Repo.update()
  end

  def update_app(%Scope{}, %App{}, _attrs), do: {:error, :unauthorized}

  @doc """
  Updates deploy settings (`:branch`, `:auto_deploy`, `:host`, `:port`).

  Other keys are ignored.
  """
  def update_app_settings(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app, attrs)
      when tenant_id == tenant.id do
    attrs = stringify_keys(attrs)
    previous_host = app.host

    app
    |> App.deploy_settings_changeset(Map.take(attrs, ["branch", "auto_deploy", "host", "port"]))
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        prune_previous_host(updated, previous_host, attrs)
        {:ok, updated}

      error ->
        error
    end
  end

  def update_app_settings(%Scope{}, %App{}, _attrs), do: {:error, :unauthorized}

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
  def delete_app(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app)
      when tenant_id == tenant.id do
    # Best-effort remote cleanup (systemd unit, release dir, Caddy site) so the
    # CLI/API path does not leave orphans behind.
    _ = CleatDeploy.Deploy.Teardown.run(Repo.preload(app, :server))
    _ = Github.delete_webhook(app)
    Repo.delete(app)
  end

  def delete_app(%Scope{}, %App{}), do: {:error, :unauthorized}

  @doc """
  Provisions (or updates) the GitHub push webhook for an app.

  Returns `{status, app}` where status is `:synced`, `:no_token`, or `{:error, message}`.
  """
  def sync_github_webhook(%App{github_repo: repo} = app) when repo in [nil, ""] do
    {:skipped, app}
  end

  def sync_github_webhook(%App{} = app) do
    case Github.ensure_webhook(app) do
      :ok ->
        {:synced, app}

      {:error, :missing_token} ->
        Logger.warning("GitHub webhook not synced for #{app.slug}: GITHUB_TOKEN is not set")
        {:no_token, app}

      {:error, reason} ->
        message = if is_binary(reason), do: reason, else: inspect(reason)
        Logger.warning("GitHub webhook not synced for #{app.slug}: #{message}")
        {{:error, message}, app}
    end
  end

  @doc """
  Provisions GitHub push webhooks for every registered app.

  Returns a list of `{slug, status}` tuples where status is `:synced`, `:no_token`,
  or `{:error, message}`.
  """
  def sync_all_github_webhooks do
    Repo.all(App)
    |> Enum.map(fn app ->
      {status, _app} = sync_github_webhook(app)
      {app.slug, status}
    end)
  end

  def change_app(app, attrs \\ %{}) do
    App.changeset(app, attrs)
  end

  def change_branch(app, attrs \\ %{}) do
    App.branch_changeset(app, attrs)
  end

  def provision_from_repo(github_repo, servers \\ []) do
    Provisioning.preset_from_repo(github_repo, servers)
  end

  def put_env_var(%App{} = app, key, value) when is_binary(key) and is_binary(value) do
    %AppEnvVar{}
    |> AppEnvVar.changeset(%{key: key, value: value, app_id: app.id})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:app_id, :key]
    )
  end

  @doc """
  Deletes an environment variable from an app.

  Returns `:ok` or `{:error, :not_found}` when the key does not exist.
  """
  def delete_env_var(%App{} = app, key) when is_binary(key) do
    {count, _} =
      Repo.delete_all(from v in AppEnvVar, where: v.app_id == ^app.id and v.key == ^key)

    if count > 0, do: :ok, else: {:error, :not_found}
  end

  def env_map(%App{} = app) do
    vars =
      app
      |> Repo.preload(:env_vars)
      |> Map.fetch!(:env_vars)
      |> Map.new(fn %{key: key, value: value} -> {key, value} end)

    Map.put(vars, "PHX_HOST", app.host)
  end

  @sensitive_markers ~w(SECRET TOKEN PASSWORD _KEY)

  def sensitive_env_key?(key) when is_binary(key) do
    upper = String.upcase(key)

    Enum.any?(@sensitive_markers, fn marker ->
      String.contains?(upper, marker)
    end)
  end

  def display_env_value(key, value, reveal?) when is_binary(key) and is_binary(value) do
    if reveal? or not sensitive_env_key?(key) do
      value
    else
      mask_env_value(value)
    end
  end

  def list_env_vars_for_display(%App{} = app) do
    app = Repo.preload(app, :env_vars)

    app.env_vars
    |> Enum.map(fn %{key: key, value: value} ->
      %{key: key, value: value, sensitive?: sensitive_env_key?(key)}
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp mask_env_value(value) do
    len = String.length(value)

    cond do
      len <= 4 ->
        String.duplicate("•", len)

      len <= 8 ->
        String.duplicate("•", 8)

      true ->
        String.slice(value, 0, 2) <>
          String.duplicate("•", min(16, len - 4)) <> String.slice(value, -2, 2)
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
