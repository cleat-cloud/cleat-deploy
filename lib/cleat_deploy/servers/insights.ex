defmodule CleatDeploy.Servers.Insights do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Analytics.Summary
  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments
  alias CleatDeploy.Hetzner
  alias CleatDeploy.Repo
  alias CleatDeploy.Servers.AccessCounts
  alias CleatDeploy.Servers.Server
  alias CleatDeploy.Settings

  @deploy_days 14
  @metric_points 48
  @visited_limit 20

  def snapshot(%Scope{} = scope, opts \\ []) do
    server = active_server(scope)
    runtimes = Apps.count_by_runtime(scope, server)

    deploys =
      fill_deploy_days(Deployments.daily_status_counts(scope, @deploy_days, server), @deploy_days)

    metrics? = Keyword.get(opts, :metrics, true)
    metrics = if metrics?, do: remote_metrics(server), else: empty_metrics()
    top_apps = if metrics?, do: AccessCounts.for_server(scope, server), else: []

    {top_visited, visited_stale} =
      if metrics?, do: visited_ranking(scope, server), else: {[], false}

    %{
      server: server,
      runtimes: runtimes,
      deploys: deploys,
      metrics: metrics,
      top_apps: top_apps,
      top_visited: top_visited,
      visited_stale: visited_stale,
      cpu_now: last_value(metrics.cpu),
      net_in_now: last_value(metrics.network_in),
      net_out_now: last_value(metrics.network_out)
    }
  end

  # The server chosen on the dashboard wins while it still belongs to the
  # tenant; otherwise fall back to the running/oldest one.
  def active_server(%Scope{} = scope) do
    case Settings.get_setting(scope).active_server_id do
      nil -> primary_server(scope)
      server_id -> get_tenant_server(scope, server_id) || primary_server(scope)
    end
  end

  @doc """
  Most requested apps (24h) on the active server, from Caddy's access log.

  Rows mirror the dashboard: `id`, `name`, `slug`, `host`, `requests`. A server
  without a local access log returns an empty list — no invented volume.
  """
  def requested_ranking(%Scope{} = scope) do
    server = active_server(scope)

    %{server: server, requested: AccessCounts.for_server(scope, server)}
  end

  defp get_tenant_server(%Scope{tenant: tenant}, server_id) do
    Repo.get_by(Server, id: server_id, tenant_id: tenant.id)
  end

  defp primary_server(%Scope{tenant: tenant}) do
    Repo.one(
      from s in Server,
        where: s.tenant_id == ^tenant.id,
        order_by: [
          asc: fragment("CASE WHEN ? = 'running' THEN 0 ELSE 1 END", s.instance_status),
          asc: s.id
        ],
        limit: 1
    )
  end

  defp remote_metrics(%Server{provider: "hetzner"} = server) do
    name = server.aws_instance_name || server.name
    finish = DateTime.utc_now(:second)
    start = DateTime.add(finish, -86_400, :second)

    case Hetzner.get_metrics(server.region || "fsn1", name, start, finish) do
      {:ok, metrics} ->
        %{
          cpu: normalize_cpu(downsample(metrics[:cpu] || metrics["cpu"] || [], @metric_points)),
          network_in: downsample(metrics[:network_in] || [], @metric_points),
          network_out: downsample(metrics[:network_out] || [], @metric_points)
        }

      {:error, _} ->
        empty_metrics()
    end
  end

  defp remote_metrics(_), do: empty_metrics()

  defp empty_metrics, do: %{cpu: [], network_in: [], network_out: []}

  defp downsample(series, _max_n) when not is_list(series), do: []
  defp downsample(series, max_n) when length(series) <= max_n, do: series

  defp downsample(series, max_n) do
    chunk = max(div(length(series), max_n), 1)

    series
    |> Enum.chunk_every(chunk)
    |> Enum.map(fn chunk ->
      avg = Enum.reduce(chunk, 0.0, fn %{v: v}, acc -> acc + v end) / length(chunk)
      %{t: hd(chunk).t, v: avg}
    end)
  end

  defp normalize_cpu([]), do: []

  defp normalize_cpu(series) do
    max_v = series |> Enum.map(& &1.v) |> Enum.max()

    if max_v <= 1.5 do
      Enum.map(series, fn point -> %{point | v: point.v * 100.0} end)
    else
      series
    end
  end

  defp last_value([]), do: nil
  defp last_value(series), do: List.last(series).v

  defp visited_ranking(_scope, nil), do: {[], false}

  defp visited_ranking(scope, %Server{} = server) do
    {rows, stale} =
      case Summary.visited(server) do
        {:ok, rows, stale: true} -> {List.wrap(rows), true}
        {:ok, rows} when is_list(rows) -> {rows, false}
        _ -> {[], false}
      end

    {rank_visited(tenant_apps(scope, server), rows), stale}
  end

  defp tenant_apps(%Scope{tenant: tenant}, server) do
    Repo.all(
      from a in App,
        where: a.tenant_id == ^tenant.id and a.server_id == ^server.id,
        select: %{id: a.id, name: a.name, slug: a.slug, host: a.host}
    )
  end

  defp rank_visited(apps, rows) do
    by_slug = Map.new(apps, &{&1.slug, &1})

    by_host =
      for app <- apps, host <- app_hosts(app), into: %{}, do: {host, app}

    rows
    |> Enum.reduce(%{}, fn row, acc -> add_visited_row(acc, row, by_slug, by_host) end)
    |> Map.values()
    |> Enum.filter(&(&1.pageviews > 0))
    |> Enum.sort_by(&{&1.pageviews, &1.slug}, :desc)
    |> Enum.take(@visited_limit)
  end

  defp add_visited_row(acc, row, by_slug, by_host) do
    case matched_app(row, by_slug, by_host) do
      nil ->
        acc

      app ->
        n = pageviews(row)

        Map.update(
          acc,
          app.id,
          %{id: app.id, name: app.name, slug: app.slug, pageviews: n},
          fn existing -> %{existing | pageviews: existing.pageviews + n} end
        )
    end
  end

  defp matched_app(row, by_slug, by_host) when is_map(row) do
    slug = string_field(row, :slug)
    host = row |> string_field(:host) |> normalize_host()

    cond do
      slug != "" and is_map_key(by_slug, slug) -> Map.fetch!(by_slug, slug)
      host != "" -> Map.get(by_host, host)
      true -> nil
    end
  end

  defp matched_app(_row, _by_slug, _by_host), do: nil

  defp pageviews(row) when is_map(row) do
    case Map.get(row, :pageviews) || Map.get(row, "pageviews") do
      n when is_integer(n) ->
        n

      n when is_float(n) ->
        trunc(n)

      n when is_binary(n) ->
        case Integer.parse(n) do
          {int, _} -> int
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp pageviews(_row), do: 0

  defp string_field(row, key) do
    case Map.get(row, key) || Map.get(row, Atom.to_string(key)) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp app_hosts(%{host: host}) when is_binary(host) do
    host
    |> String.split(",")
    |> Enum.map(&normalize_host/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp app_hosts(_), do: []

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("http://", "")
    |> String.replace_prefix("https://", "")
    |> String.split(":")
    |> hd()
  end

  defp normalize_host(_), do: ""

  defp fill_deploy_days(rows, days) do
    counts =
      Map.new(rows, fn {date, status, n} ->
        {{to_string(date), status}, n}
      end)

    today = Date.utc_today()

    Enum.map((days - 1)..0//-1, fn offset ->
      date = Date.add(today, -offset)
      key = Date.to_iso8601(date)

      %{
        date: key,
        label: Calendar.strftime(date, "%d"),
        success: Map.get(counts, {key, :success}, 0),
        failed: Map.get(counts, {key, :failed}, 0)
      }
    end)
  end
end
