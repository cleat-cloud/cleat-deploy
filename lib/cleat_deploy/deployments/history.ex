defmodule CleatDeploy.Deployments.History do
  @moduledoc """
  Deployment history, pagination and status counters.
  """

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Repo

  def get_deployment!(id), do: Repo.get!(Deployment, id) |> Repo.preload(:app)

  def get_with_log!(id), do: Repo.get!(Deployment, id)

  def get_with_log!(%App{} = app, id) do
    Repo.one!(from d in Deployment, where: d.app_id == ^app.id and d.id == ^id)
  end

  @history_fields [
    :id,
    :git_sha,
    :git_ref,
    :status,
    :triggered_by,
    :started_at,
    :finished_at,
    :inserted_at,
    :updated_at,
    :app_id
  ]

  @history_page_size 10

  def history_page_size, do: @history_page_size

  def for_app(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app)
      when tenant_id == tenant.id do
    list_for_app(app)
  end

  def for_app(%Scope{}, %App{}), do: []

  def for_app(%App{} = app), do: list_for_app(app)

  def page_for_app(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app, page)
      when tenant_id == tenant.id and is_integer(page) do
    list_page_for_app(app, page)
  end

  def page_for_app(%Scope{}, %App{}, _page), do: empty_history_page()

  def page_for_app(%App{} = app, page) when is_integer(page) do
    list_page_for_app(app, page)
  end

  def page_for_tenant(%Scope{tenant: tenant}, page, opts \\ []) when is_integer(page) do
    list_page_for_tenant(tenant.id, page, opts)
  end

  def deploying_for_tenant?(%Scope{tenant: tenant}) do
    Repo.exists?(
      from d in Deployment,
        join: a in App,
        on: a.id == d.app_id,
        where: a.tenant_id == ^tenant.id and d.status in [:queued, :running]
    )
  end

  def deploying?(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app)
      when tenant_id == tenant.id do
    deploying?(app)
  end

  def deploying?(%Scope{}, %App{}), do: false

  def deploying?(%App{} = app) do
    Repo.exists?(
      from d in Deployment,
        where: d.app_id == ^app.id and d.status in [:queued, :running]
    )
  end

  def daily_status_counts(%Scope{tenant: tenant}, days) when is_integer(days) and days > 0 do
    daily_status_counts_query(tenant.id, days, nil)
  end

  def daily_status_counts(%Scope{}, days, nil) when is_integer(days) and days > 0, do: []

  def daily_status_counts(%Scope{tenant: tenant}, days, %{id: server_id})
      when is_integer(days) and days > 0 and is_integer(server_id) do
    daily_status_counts_query(tenant.id, days, server_id)
  end

  defp daily_status_counts_query(tenant_id, days, server_id) do
    since = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

    query =
      from(d in Deployment,
        join: a in App,
        on: a.id == d.app_id,
        where: a.tenant_id == ^tenant_id and d.inserted_at >= ^since,
        group_by: [fragment("date(?)", d.inserted_at), d.status],
        select: {fragment("date(?)", d.inserted_at), d.status, count(d.id)}
      )

    query =
      if is_integer(server_id) do
        from([d, a] in query, where: a.server_id == ^server_id)
      else
        query
      end

    Repo.all(query)
  end

  defp list_for_app(%App{} = app) do
    Repo.all(history_query(app))
  end

  defp list_page_for_app(%App{} = app, page) do
    total = Repo.aggregate(from(d in Deployment, where: d.app_id == ^app.id), :count, :id)
    total_pages = history_total_pages(total)
    page = page |> max(1) |> min(total_pages)
    offset = (page - 1) * @history_page_size

    entries =
      Repo.all(
        from d in history_query(app),
          limit: ^@history_page_size,
          offset: ^offset
      )

    %{
      entries: entries,
      page: page,
      page_size: @history_page_size,
      total: total,
      total_pages: total_pages
    }
  end

  defp history_query(%App{} = app) do
    from d in Deployment,
      where: d.app_id == ^app.id,
      order_by: [desc: d.inserted_at, desc: d.id],
      select: struct(d, ^@history_fields)
  end

  defp list_page_for_tenant(tenant_id, page, opts) do
    filtered = tenant_history_query(tenant_id, opts)
    total = filtered |> select([deployment: d], count(d.id)) |> Repo.one()
    total_pages = history_total_pages(total)
    page = page |> max(1) |> min(total_pages)
    offset = (page - 1) * @history_page_size

    entries =
      filtered
      |> order_by([deployment: d], desc: d.inserted_at, desc: d.id)
      |> select([deployment: d], struct(d, ^@history_fields))
      |> limit(^@history_page_size)
      |> offset(^offset)
      |> Repo.all()
      |> Repo.preload(:app)

    %{
      entries: entries,
      page: page,
      page_size: @history_page_size,
      total: total,
      total_pages: total_pages
    }
  end

  defp tenant_history_query(tenant_id, opts) do
    from(d in Deployment, as: :deployment)
    |> join(:inner, [deployment: d], a in App, on: a.id == d.app_id, as: :app)
    |> where([app: a], a.tenant_id == ^tenant_id)
    |> filter_app_query(Keyword.get(opts, :query, ""))
    |> filter_status(Keyword.get(opts, :status, :all))
  end

  defp filter_app_query(query, needle) when needle in [nil, ""], do: query

  defp filter_app_query(query, needle) do
    pat = "%" <> String.downcase(String.trim(to_string(needle))) <> "%"

    where(
      query,
      [app: a],
      like(fragment("lower(?)", a.name), ^pat) or
        like(fragment("lower(?)", a.slug), ^pat) or
        like(fragment("lower(?)", a.host), ^pat)
    )
  end

  defp filter_status(query, :all), do: query

  defp filter_status(query, status) when status in [:queued, :running, :success, :failed] do
    where(query, [deployment: d], d.status == ^status)
  end

  defp filter_status(query, _), do: query

  defp history_total_pages(0), do: 1

  defp history_total_pages(total) when is_integer(total) and total > 0 do
    div(total + @history_page_size - 1, @history_page_size)
  end

  defp empty_history_page do
    %{
      entries: [],
      page: 1,
      page_size: @history_page_size,
      total: 0,
      total_pages: 1
    }
  end
end
