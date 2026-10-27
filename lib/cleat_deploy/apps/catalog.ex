defmodule CleatDeploy.Apps.Catalog do
  @moduledoc """
  Queries over the app catalog: listing, filtering, sorting and counters.
  """

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Repo

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
      tenant.id
      |> filtered_query(opts)
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

  @doc """
  Every app matching the filters, name-ordered and with server preloaded.

  RAM, CPU, disk and On/Off only exist at runtime (async SSH probe), so they
  cannot be sorted in SQL: the index ranks the whole filtered set and paginates
  afterwards.
  """
  def filtered_apps(%Scope{tenant: tenant}, opts \\ []) do
    tenant.id
    |> filtered_query(opts)
    |> order_by([app: a], asc: a.name)
    |> preload([app: a, server: s], server: s)
    |> Repo.all()
  end

  defp filtered_query(tenant_id, opts) do
    from(a in App, as: :app, where: a.tenant_id == ^tenant_id)
    |> join(:inner, [app: a], s in assoc(a, :server), as: :server)
    |> filter_runtime(Keyword.get(opts, :runtime, :all))
    |> filter_idle(Keyword.get(opts, :idle, :all))
    |> filter_query(Keyword.get(opts, :query, ""))
  end

  defp filter_runtime(query, :all), do: query
  defp filter_runtime(query, :golang), do: where(query, [app: a], a.runtime == "golang")
  defp filter_runtime(query, :node), do: where(query, [app: a], a.runtime == "node")
  defp filter_runtime(query, :static), do: where(query, [app: a], a.runtime == "static")
  defp filter_runtime(query, :rails), do: where(query, [app: a], a.runtime == "rails")
  defp filter_runtime(query, :rust), do: where(query, [app: a], a.runtime == "rust")
  defp filter_runtime(query, :gleam), do: where(query, [app: a], a.runtime == "gleam")

  defp filter_runtime(query, :phoenix) do
    where(
      query,
      [app: a],
      a.runtime not in ["golang", "node", "static", "rails", "rust", "gleam"]
    )
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
           when 'gleam' then 'Gleam'
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
      {"static", n}, acc -> %{acc | static: n}
      {"gleam", n}, acc -> %{acc | gleam: n}
      {_runtime, n}, acc -> %{acc | elixir: acc.elixir + n}
    end)
  end

  defp empty_runtime_counts,
    do: %{elixir: 0, go: 0, node: 0, ruby: 0, rust: 0, static: 0, gleam: 0}

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
  True when `domain` is one of an app's hosts (comma-separated aliases included).

  Used by Caddy `on_demand_tls` ask: only registered hosts may mint a cert.
  """
  def host_registered?(domain) when is_binary(domain) do
    needle = normalize_ask_host(domain)

    if needle == "" do
      false
    else
      Repo.all(from a in App, select: a.host)
      |> Enum.any?(&host_matches?(&1, needle))
    end
  end

  def host_registered?(_), do: false

  defp host_matches?(host, needle) when is_binary(host) do
    host
    |> String.split(",")
    |> Enum.map(&normalize_ask_host/1)
    |> Enum.member?(needle)
  end

  defp host_matches?(_, _), do: false

  defp normalize_ask_host(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing(".")
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
end
