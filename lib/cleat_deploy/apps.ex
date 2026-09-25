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

  @page_size 10

  def page_size, do: @page_size

  @doc """
  One page of apps for the apps index: filter and sort in SQL, preload server.
  """
  def page_apps(%Scope{tenant: tenant}, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, @page_size) |> max(1)
    sort = Keyword.get(opts, :sort, :name)
    dir = Keyword.get(opts, :dir, :asc)

    filtered =
      from(a in App, as: :app, where: a.tenant_id == ^tenant.id)
      |> join(:inner, [app: a], s in assoc(a, :server), as: :server)
      |> filter_runtime(Keyword.get(opts, :runtime, :all))
      |> filter_idle(Keyword.get(opts, :idle, :all))
      |> filter_query(Keyword.get(opts, :query, ""))
      |> sort_apps(sort, dir)

    total = Repo.aggregate(exclude(filtered, :order_by), :count, :id)
    total_pages = max(div(total + page_size - 1, page_size), 1)
    page = opts |> Keyword.get(:page, 1) |> max(1) |> min(total_pages)
    offset = (page - 1) * page_size

    entries =
      filtered
      |> limit(^page_size)
      |> offset(^offset)
      |> preload([app: a, server: s], server: s)
      |> Repo.all()

    %{entries: entries, page: page, page_size: page_size, total: total, total_pages: total_pages}
  end

  defp filter_runtime(query, :all), do: query
  defp filter_runtime(query, :golang), do: where(query, [app: a], a.runtime == "golang")
  defp filter_runtime(query, :node), do: where(query, [app: a], a.runtime == "node")
  defp filter_runtime(query, :static), do: where(query, [app: a], a.runtime == "static")
  defp filter_runtime(query, :rails), do: where(query, [app: a], a.runtime == "rails")
  defp filter_runtime(query, :rust), do: where(query, [app: a], a.runtime == "rust")

  defp filter_runtime(query, :phoenix) do
    where(query, [app: a], a.runtime not in ["golang", "node", "static", "rails", "rust"])
  end

  defp filter_runtime(query, _), do: query

  defp filter_idle(query, :all), do: query
  defp filter_idle(query, :on), do: where(query, [app: a], a.idle_shutdown_enabled == true)
  defp filter_idle(query, :off), do: where(query, [app: a], a.idle_shutdown_enabled == false)
  defp filter_idle(query, _), do: query

  defp filter_query(query, needle) when needle in [nil, ""], do: query

  defp filter_query(query, needle) do
    pat = "%" <> String.downcase(String.trim(to_string(needle))) <> "%"

    where(
      query,
      [app: a, server: s],
      like(fragment("lower(?)", a.name), ^pat) or
        like(fragment("lower(?)", a.slug), ^pat) or
        like(fragment("lower(?)", a.host), ^pat) or
        like(fragment("lower(?)", a.runtime), ^pat) or
        like(fragment("lower(?)", s.name), ^pat)
    )
  end

  defp sort_apps(query, :host, dir), do: order_by(query, [app: a], [{^dir, a.host}])

  defp sort_apps(query, :idle, dir),
    do: order_by(query, [app: a], [{^dir, a.idle_shutdown_enabled}])

  defp sort_apps(query, :server, dir), do: order_by(query, [server: s], [{^dir, s.name}])

  defp sort_apps(query, :language, dir) do
    order_by(query, [app: a], [
      {^dir,
       fragment(
         """
         case ?
           when 'golang' then 'Go'
           when 'static' then 'Static'
           when 'node' then 'JavaScript'
           when 'rails' then 'Ruby'
           when 'rust' then 'Rust'
           else 'Elixir'
         end
         """,
         a.runtime
       )}
    ])
  end

  defp sort_apps(query, _sort, dir), do: order_by(query, [app: a], [{^dir, a.name}])

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

  def count_apps(%Scope{}, nil), do: 0

  def count_apps(%Scope{tenant: tenant}, %{id: server_id}) when is_integer(server_id) do
    Repo.aggregate(
      from(a in App, where: a.tenant_id == ^tenant.id and a.server_id == ^server_id),
      :count,
      :id
    )
  end

  def count_by_runtime(%Scope{tenant: tenant}) do
    count_by_runtime_query(from(a in App, where: a.tenant_id == ^tenant.id))
  end

  def count_by_runtime(%Scope{}, nil), do: empty_runtime_counts()

  def count_by_runtime(%Scope{tenant: tenant}, %{id: server_id}) when is_integer(server_id) do
    count_by_runtime_query(
      from(a in App, where: a.tenant_id == ^tenant.id and a.server_id == ^server_id)
    )
  end

  defp count_by_runtime_query(query) do
    from(a in query, group_by: a.runtime, select: {a.runtime, count(a.id)})
    |> Repo.all()
    |> Enum.reduce(empty_runtime_counts(), fn
      {"golang", n}, acc -> %{acc | go: n}
      {"node", n}, acc -> %{acc | node: n}
      {"rails", n}, acc -> %{acc | ruby: n}
      {"rust", n}, acc -> %{acc | rust: n}
      {_runtime, n}, acc -> %{acc | elixir: acc.elixir + n}
    end)
  end

  defp empty_runtime_counts, do: %{elixir: 0, go: 0, node: 0, ruby: 0, rust: 0}

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

  @doc """
  Returns one app of a repository.

  A repository can hold several instances (one per branch), so the oldest app is
  returned; use `list_apps_by_repo/1` when all of them matter.
  """
  def get_app_by_repo(github_repo) when is_binary(github_repo) do
    Repo.one(from a in App, where: a.github_repo == ^github_repo, order_by: [asc: a.id], limit: 1)
  end

  def get_app_by_slug!(%Scope{tenant: tenant}, slug) when is_binary(slug) do
    Repo.one!(
      from a in App,
        where: a.tenant_id == ^tenant.id and a.slug == ^slug,
        preload: [:server, :env_vars]
    )
  end

  def list_apps_by_repo(github_repo) when is_binary(github_repo) do
    Repo.all(from a in App, where: a.github_repo == ^github_repo, order_by: [asc: a.id])
  end

  @doc """
  Other instances of the same project: apps of the tenant deploying the same
  repository from a different branch.
  """
  def list_app_instances(%Scope{tenant: tenant}, %App{} = app) do
    Repo.all(
      from a in App,
        where:
          a.tenant_id == ^tenant.id and a.github_repo == ^app.github_repo and
            a.github_repo != "" and a.id != ^app.id,
        order_by: [asc: a.branch],
        preload: [:server]
    )
  end

  def list_all_with_servers do
    Repo.all(from a in App, order_by: [asc: a.slug], preload: [:server])
  end

  @doc """
  Apps that opted into idle shutdown, for one tenant.

  Static sites have no process to stop, so they are left out.
  """
  def list_idle_candidates(tenant_id) when is_integer(tenant_id) do
    Repo.all(
      from a in App,
        where:
          a.tenant_id == ^tenant_id and a.idle_shutdown_enabled == true and
            a.runtime != "static",
        order_by: [asc: a.id],
        preload: [:server]
    )
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
      |> inherit_webhook_secret(tenant)
      |> assign_free_port()

    with {:ok, app} <-
           %App{}
           |> App.changeset(attrs)
           |> Repo.insert() do
      {status, app} = sync_github_webhook(app)
      {:ok, app, status}
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
  Updates deploy settings (`:branch`, `:auto_deploy`, `:idle_shutdown_enabled`,
  `:indexable`, `:host`, `:port`).

  Other keys are ignored.
  """
  def update_app_settings(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app, attrs)
      when tenant_id == tenant.id do
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
        "runtime_apt_packages"
      ])
    )
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        prune_previous_host(updated, previous_host, attrs)
        sync_repo_change(updated, previous_repo)
        prune_previous_unit(updated, previous_runtime, previous_unit)
        {:ok, updated}

      error ->
        error
    end
  end

  def update_app_settings(%Scope{}, %App{}, _attrs), do: {:error, :unauthorized}

  # Repointing an app at another repo should refresh its push webhook.
  defp sync_repo_change(%App{} = app, previous_repo) do
    if is_binary(app.github_repo) and app.github_repo != "" and app.github_repo != previous_repo do
      _ = sync_github_webhook(Repo.preload(app, :server))
    end

    :ok
  end

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

  def change_env_var(%App{} = app, attrs \\ %{}) do
    AppEnvVar.changeset(%AppEnvVar{app_id: app.id}, attrs)
  end

  @doc """
  Creates or updates a variable, scoped to a branch (`"*"` by default).
  """
  def put_env_var(%App{} = app, key, value, branch \\ AppEnvVar.all_branches())
      when is_binary(key) and is_binary(value) do
    branch = AppEnvVar.normalize(branch)

    %AppEnvVar{}
    |> AppEnvVar.changeset(%{key: key, value: value, app_id: app.id, branch: branch})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:app_id, :key, :branch]
    )
  end

  @doc """
  Deletes an environment variable from an app.

  Returns `:ok` or `{:error, :not_found}` when the key does not exist for that
  branch scope.
  """
  def delete_env_var(%App{} = app, key, branch \\ AppEnvVar.all_branches())
      when is_binary(key) do
    branch = AppEnvVar.normalize(branch)

    {count, _} =
      Repo.delete_all(
        from v in AppEnvVar,
          where: v.app_id == ^app.id and v.key == ^key and v.branch == ^branch
      )

    if count > 0, do: :ok, else: {:error, :not_found}
  end

  @doc """
  Environment of an app as it is written to the server's env file.

  Without a branch every stored variable is returned. With one, the variables
  scoped to all branches are returned and the branch-specific ones override them
  by key.
  """
  def env_map(%App{} = app), do: env_map(app, nil)

  def env_map(%App{} = app, branch) do
    # Force a reload: the deploy path writes env vars (addon credentials) after
    # the struct was loaded and must see them right away.
    vars =
      app
      |> Repo.preload(:env_vars, force: true)
      |> Map.fetch!(:env_vars)
      |> Enum.filter(&(branch == nil or AppEnvVar.applies_to?(&1.branch, branch)))
      |> Enum.sort_by(fn %{branch: scope} ->
        {if(AppEnvVar.all_branches?(scope), do: 0, else: 1), scope}
      end)
      |> Map.new(fn %{key: key, value: value} -> {key, value} end)

    Map.put(vars, "PHX_HOST", app.host)
  end

  @sensitive_markers ~w(SECRET TOKEN PASSWORD _KEY)
  # Connection strings carry the addon password in the userinfo.
  @sensitive_keys ~w(DATABASE_URL REDIS_URL)

  def sensitive_env_key?(key) when is_binary(key) do
    upper = String.upcase(key)

    upper in @sensitive_keys or
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
    |> Enum.map(fn %{key: key, value: value, branch: branch} ->
      %{key: key, value: value, branch: branch, sensitive?: sensitive_env_key?(key)}
    end)
    |> Enum.sort_by(fn %{key: key, branch: branch} -> {key, branch} end)
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
