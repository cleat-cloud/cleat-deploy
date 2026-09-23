defmodule CleatDeploy.Servers.Insights do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps
  alias CleatDeploy.Deployments
  alias CleatDeploy.Hetzner
  alias CleatDeploy.Repo
  alias CleatDeploy.Servers.Server
  alias CleatDeploy.Settings

  @deploy_days 14
  @metric_points 48

  def snapshot(%Scope{} = scope, opts \\ []) do
    server = active_server(scope)
    runtimes = Apps.count_by_runtime(scope, server)
    app_count = Apps.count_apps(scope, server)

    deploys =
      fill_deploy_days(Deployments.daily_status_counts(scope, @deploy_days, server), @deploy_days)

    metrics =
      if Keyword.get(opts, :metrics, true), do: remote_metrics(server), else: empty_metrics()

    wrap(server, app_count, runtimes, deploys, metrics)
  end

  defp wrap(server, app_count, runtimes, deploys, metrics) do
    %{
      server: server,
      app_count: app_count,
      runtimes: runtimes,
      deploys: deploys,
      metrics: metrics,
      cpu_now: last_value(metrics.cpu),
      net_in_now: last_value(metrics.network_in),
      net_out_now: last_value(metrics.network_out)
    }
  end

  # The server chosen on the dashboard wins while it still belongs to the
  # tenant; otherwise fall back to the running/oldest one.
  defp active_server(%Scope{} = scope) do
    case Settings.get_setting(scope).active_server_id do
      nil -> primary_server(scope)
      server_id -> get_tenant_server(scope, server_id) || primary_server(scope)
    end
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
