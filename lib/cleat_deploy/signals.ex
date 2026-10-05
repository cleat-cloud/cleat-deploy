defmodule CleatDeploy.Signals do
  @moduledoc """
  Corte 02 of Cleat Signals: health, metrics and alerts from stored panel data.

  The overview is computed from `log_events` and deployments in SQLite, so
  detecting a degraded app does not open SSH.
  """

  import Ecto.Query

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals.Alert

  @error_severities ~w(emerg alert crit err)
  @error_rate_min 5
  @error_rate_factor 3
  @default_window 3_600
  @saturation ~r/out of memory|oom[- ]killed|enospc|no space left|cannot allocate memory|killed process/i

  @doc """
  Tenant-scoped health rows, one per app, ordered by name.

  Options:
    * `:now` — freeze the clock (`DateTime`)
    * `:window_seconds` — current vs previous window (default 3600)
  """
  def health_overview(%Scope{} = scope, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    window = Keyword.get(opts, :window_seconds, @default_window)
    current_start = DateTime.add(now, -window, :second)
    previous_start = DateTime.add(now, -2 * window, :second)

    current = error_counts(scope.tenant.id, current_start, now)
    previous = error_counts(scope.tenant.id, previous_start, current_start)
    first_error = first_error_at(scope.tenant.id, current_start, now)
    saturated = saturated_apps(scope.tenant.id, current_start, now)
    apps = Apps.list_apps(scope)
    app_ids = Enum.map(apps, & &1.id)
    deploys = finished_deploys(app_ids)
    latest = latest_by_app(deploys)
    releases = preceding_releases(deploys, app_ids, first_error, now)
    last_events = last_event_at_by_app(scope.tenant.id)
    ingest = Observability.ingest_status(now: now)

    Enum.map(apps, fn app ->
      cur = Map.get(current, app.id, 0)
      prev = Map.get(previous, app.id, 0)

      reasons =
        reasons(
          cur,
          prev,
          Map.get(latest, app.id),
          MapSet.member?(saturated, app.id),
          now,
          window
        )

      %{
        app_id: app.id,
        slug: app.slug,
        name: app.name,
        runtime: app.runtime,
        status: status(reasons),
        reasons: reasons,
        error_count: cur,
        previous_error_count: prev,
        last_event_at: Map.get(last_events, app.id),
        ingest: ingest,
        preceding_release: Map.get(releases, app.id)
      }
    end)
  end

  defp last_event_at_by_app(tenant_id) do
    from(e in LogEvent,
      where: e.tenant_id == ^tenant_id and not is_nil(e.app_id),
      group_by: e.app_id,
      select: {e.app_id, max(e.occurred_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp reasons(current, previous, latest, saturated?, now, window) do
    []
    |> maybe_reason(:deploy_failed, recent_failed_deploy?(latest, now, window))
    |> maybe_reason(:error_rate, error_rate?(current, previous))
    |> maybe_reason(:saturation, saturated?)
  end

  defp recent_failed_deploy?(%{status: :failed, finished_at: at}, now, window)
       when not is_nil(at) and is_integer(window) do
    DateTime.diff(now, at, :second) <= window
  end

  defp recent_failed_deploy?(_latest, _now, _window), do: false

  defp maybe_reason(reasons, reason, true), do: reasons ++ [reason]
  defp maybe_reason(reasons, _reason, false), do: reasons

  defp error_rate?(current, previous) do
    current >= @error_rate_min and current >= @error_rate_factor * max(previous, 1)
  end

  defp status(reasons) do
    cond do
      :unavailability in reasons -> :down
      reasons != [] -> :degraded
      true -> :healthy
    end
  end

  defp error_counts(tenant_id, since, until) do
    tenant_id
    |> error_query(since, until)
    |> group_by([e], e.app_id)
    |> select([e], {e.app_id, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp first_error_at(tenant_id, since, until) do
    tenant_id
    |> error_query(since, until)
    |> group_by([e], e.app_id)
    |> select([e], {e.app_id, min(e.occurred_at)})
    |> Repo.all()
    |> Map.new()
  end

  defp error_query(tenant_id, since, until) do
    from e in LogEvent,
      where:
        e.tenant_id == ^tenant_id and e.severity in ^@error_severities and not is_nil(e.app_id) and
          e.occurred_at > ^since and e.occurred_at <= ^until
  end

  defp saturated_apps(tenant_id, since, until) do
    Repo.all(
      from e in LogEvent,
        where:
          e.tenant_id == ^tenant_id and not is_nil(e.app_id) and e.occurred_at > ^since and
            e.occurred_at <= ^until,
        select: {e.app_id, e.message}
    )
    |> Enum.reduce(MapSet.new(), fn {app_id, message}, acc ->
      if Regex.match?(@saturation, message), do: MapSet.put(acc, app_id), else: acc
    end)
  end

  defp finished_deploys([]), do: []

  defp finished_deploys(app_ids) do
    Repo.all(
      from d in Deployment,
        where: d.app_id in ^app_ids and not is_nil(d.finished_at),
        order_by: [desc: d.finished_at, desc: d.id]
    )
  end

  defp latest_by_app(deploys) do
    Enum.reduce(deploys, %{}, fn deploy, acc ->
      Map.put_new(acc, deploy.app_id, deploy)
    end)
  end

  defp preceding_releases(deploys, app_ids, first_error, now) do
    Enum.reduce(app_ids, %{}, fn app_id, acc ->
      cutoff = Map.get(first_error, app_id, now)

      case Enum.find(deploys, &precedes?(&1, app_id, cutoff)) do
        nil -> acc
        deploy -> Map.put(acc, app_id, release_ref(deploy))
      end
    end)
  end

  defp precedes?(%Deployment{} = deploy, app_id, cutoff) do
    deploy.app_id == app_id and DateTime.compare(deploy.finished_at, cutoff) != :gt
  end

  defp release_ref(%Deployment{} = deploy) do
    %{
      id: deploy.id,
      git_sha: deploy.git_sha,
      git_ref: deploy.git_ref,
      status: deploy.status,
      finished_at: deploy.finished_at
    }
  end

  @restart ~r/watchdog|restarted|scheduled restart/i

  @doc """
  RED + host snapshot for one app, plus deploy markers in the window.

  Host CPU/memory/disk stay nil here: those probes are SSH. Restarts are
  inferred from collected logs.
  """
  def metrics(scope, app, opts \\ [])

  def metrics(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app, opts)
      when tenant.id == tenant_id do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    range = Keyword.get(opts, :range, "1h") |> normalize_range()
    window = range_seconds(range)
    since = DateTime.add(now, -window, :second)

    events = app_events(tenant.id, app.id, since, now)
    errors = Enum.count(events, &(&1.severity in @error_severities))
    logs = length(events)

    {:ok,
     %{
       app_id: app.id,
       slug: app.slug,
       range: range,
       red: %{
         requests: logs,
         errors: errors,
         logs: logs,
         error_rate: error_ratio(errors, logs),
         latency_ms: nil
       },
       host: %{cpu: nil, memory: nil, disk: nil, restarts: Enum.count(events, &restart?/1)},
       series: series(events, since, now),
       deploy_markers: markers(app.id, since, now)
     }}
  end

  def metrics(%Scope{}, %App{}, _opts), do: {:error, :not_found}

  defp normalize_range(range) when range in ["1h", "6h", "24h", "1d"], do: range
  defp normalize_range(_), do: "1h"

  defp range_seconds("1h"), do: 3_600
  defp range_seconds("6h"), do: 21_600
  defp range_seconds("24h"), do: 86_400
  defp range_seconds("1d"), do: 86_400

  defp app_events(tenant_id, app_id, since, until) do
    Repo.all(
      from e in LogEvent,
        where:
          e.tenant_id == ^tenant_id and e.app_id == ^app_id and e.occurred_at > ^since and
            e.occurred_at <= ^until,
        order_by: [asc: e.occurred_at]
    )
  end

  defp error_ratio(_errors, 0), do: 0.0
  defp error_ratio(errors, logs), do: errors / logs

  defp restart?(event), do: Regex.match?(@restart, event.message)

  defp series(events, since, now) do
    buckets = 12
    span = max(DateTime.diff(now, since, :second), 1)
    size = max(div(span, buckets), 1)

    Enum.flat_map(0..(buckets - 1), fn i ->
      start = DateTime.add(since, i * size, :second)
      finish = if i == buckets - 1, do: now, else: DateTime.add(since, (i + 1) * size, :second)
      slice = Enum.filter(events, &in_bucket?(&1.occurred_at, start, finish))

      point = %{
        t: finish,
        errors: Enum.count(slice, &(&1.severity in @error_severities)),
        logs: length(slice)
      }

      if point.logs == 0, do: [], else: [point]
    end)
  end

  defp in_bucket?(at, start, finish) do
    DateTime.compare(at, start) == :gt and DateTime.compare(at, finish) != :gt
  end

  defp markers(app_id, since, now) do
    Repo.all(
      from d in Deployment,
        where:
          d.app_id == ^app_id and not is_nil(d.finished_at) and d.finished_at > ^since and
            d.finished_at <= ^now,
        order_by: [asc: d.finished_at]
    )
    |> Enum.map(&release_ref/1)
  end

  @doc """
  Opens default alerts for degraded/down apps and resolves ones that recovered.

  D-007: the first outbound channel is a webhook (`SIGNALS_WEBHOOK_URL` /
  `:signals_webhook_url`). Alerts always persist in-app so CLI/MCP can list
  them even when no webhook is configured.
  """
  def evaluate_alerts(%Scope{} = scope, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    rows = health_overview(scope, opts)
    open = open_alerts(scope.tenant.id)
    desired = desired_alerts(rows) |> put_ingest_stale(rows)
    desired_keys = MapSet.new(Map.keys(desired))

    opened =
      desired
      |> Enum.reject(fn {key, _row} -> Map.has_key?(open, key) end)
      |> Enum.flat_map(fn {{app_id, rule}, row} -> open_alert(scope, app_id, rule, row, now) end)

    open
    |> Enum.filter(fn {key, alert} ->
      alert.status == "firing" and not MapSet.member?(desired_keys, key)
    end)
    |> Enum.each(fn {_key, alert} -> resolve_alert(alert, now) end)

    {:ok, opened}
  end

  # A stale collector is tenant-wide: it has no app and only fires while the
  # collector is enabled, so an explicit opt-out is not treated as a fault.
  defp put_ingest_stale(desired, rows) do
    ingest = rows |> List.first() |> then(&(&1 && &1.ingest))

    if ingest && ingest.stale && Enum.any?(rows, &(&1.runtime != "static")) do
      Map.put(desired, {nil, "ingest_stale"}, %{ingest: ingest})
    else
      desired
    end
  end

  def list_alerts(%Scope{tenant: tenant}) do
    Repo.all(
      from a in Alert,
        where: a.tenant_id == ^tenant.id and a.status in ["firing", "acked"],
        order_by: [desc: a.fired_at, desc: a.id],
        preload: [:app]
    )
  end

  def ack_alert(%Scope{tenant: tenant}, id) when is_integer(id) do
    case Repo.get_by(Alert, id: id, tenant_id: tenant.id) do
      %Alert{status: "firing"} = alert ->
        alert
        |> Ecto.Changeset.change(%{status: "acked", acked_at: DateTime.utc_now(:second)})
        |> Repo.update()
        |> preload_alert_app()

      nil ->
        {:error, :not_found}

      _alert ->
        {:error, :invalid_status}
    end
  end

  def ack_alert(%Scope{}, _id), do: {:error, :not_found}

  defp preload_alert_app({:ok, alert}), do: {:ok, Repo.preload(alert, :app)}
  defp preload_alert_app(other), do: other

  def incident(scope, app, opts \\ [])

  def incident(%Scope{tenant: tenant} = scope, %App{tenant_id: tenant_id} = app, opts)
      when tenant.id == tenant_id do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    range = opts |> Keyword.get(:range, "24h") |> normalize_range()
    since = DateTime.add(now, -range_seconds(range), :second)

    events =
      (incident_deploys(app.id, since, now) ++
         incident_alerts(app.id, since) ++
         incident_groups(scope, app.id, since))
      |> Enum.sort_by(& &1.at, {:desc, DateTime})

    {:ok, %{app_id: app.id, slug: app.slug, events: events}}
  end

  def incident(%Scope{}, %App{}, _opts), do: {:error, :not_found}

  defp desired_alerts(rows) do
    for row <- rows, reason <- row.reasons, into: %{} do
      {{row.app_id, Atom.to_string(reason)}, row}
    end
  end

  defp open_alerts(tenant_id) do
    Repo.all(
      from a in Alert,
        where: a.tenant_id == ^tenant_id and a.status in ["firing", "acked"]
    )
    |> Map.new(&{{&1.app_id, &1.rule}, &1})
  end

  defp open_alert(scope, app_id, rule, row, now) do
    attrs = %{
      tenant_id: scope.tenant.id,
      app_id: app_id,
      rule: rule,
      status: "firing",
      message: alert_message(rule, row),
      payload: alert_payload(rule, row),
      channel: if(webhook_url(), do: "webhook", else: "in_app"),
      fired_at: now
    }

    case attrs |> Alert.insert_changeset() |> Repo.insert() do
      {:ok, alert} -> [deliver_alert(alert, row)]
      {:error, _changeset} -> []
    end
  end

  defp resolve_alert(alert, now) do
    alert
    |> Ecto.Changeset.change(%{status: "resolved", resolved_at: now})
    |> Repo.update()
  end

  defp alert_message("unavailability", row), do: "Aplicação #{row.slug} indisponível"
  defp alert_message("deploy_failed", row), do: "Deploy falhou em #{row.slug}"
  defp alert_message("error_rate", row), do: "Taxa de erro subiu em #{row.slug}"
  defp alert_message("saturation", row), do: "Saturação em #{row.slug}"
  defp alert_message("ingest_stale", %{ingest: ingest}), do: ingest_message(ingest)
  defp alert_message(_rule, row), do: "Alerta em #{row.slug}"

  defp ingest_message(%{enabled: false}),
    do: "Coletor de logs desligado — os sinais podem estar desatualizados"

  defp ingest_message(%{last_run_at: nil}),
    do: "Coletor de logs nunca executou — os sinais podem estar desatualizados"

  defp ingest_message(%{last_run_at: at}),
    do: "Coletor de logs sem executar desde #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}"

  defp alert_payload("ingest_stale", row) do
    %{
      "event" => "signal.alert",
      "rule" => "ingest_stale",
      "status" => "firing",
      "message" => alert_message("ingest_stale", row),
      "ingest" => json_ingest(row.ingest)
    }
  end

  defp alert_payload(rule, row) do
    %{
      "event" => "signal.alert",
      "rule" => rule,
      "status" => "firing",
      "message" => alert_message(rule, row),
      "app" => %{"id" => row.app_id, "slug" => row.slug, "name" => row.name},
      "preceding_release" => json_release(row.preceding_release)
    }
  end

  defp json_ingest(ingest) do
    %{
      enabled: ingest.enabled,
      last_run_at: ingest.last_run_at,
      last_failures: ingest.last_failures,
      failed_apps: ingest.failed_apps
    }
  end

  defp json_release(nil), do: nil

  defp json_release(release) do
    %{
      "id" => release.id,
      "git_sha" => release.git_sha,
      "git_ref" => release.git_ref,
      "status" => to_string(release.status),
      "finished_at" => release.finished_at
    }
  end

  defp deliver_alert(alert, row) do
    case webhook_url() do
      nil ->
        alert

      url ->
        opts = [json: alert_payload(alert.rule, row)] ++ webhook_req_options()

        case Req.post(url, opts) do
          {:ok, %{status: status}} when status in 200..299 ->
            alert
            |> Ecto.Changeset.change(%{
              channel: "webhook",
              delivered_at: DateTime.utc_now(:second)
            })
            |> Repo.update!()

          _other ->
            alert
        end
    end
  end

  defp webhook_url do
    case Application.get_env(:cleat_deploy, :signals_webhook_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp webhook_req_options do
    Application.get_env(:cleat_deploy, :signals_req_options, [])
  end

  defp incident_deploys(app_id, since, now) do
    Enum.map(markers(app_id, since, now), fn marker ->
      %{
        at: marker.finished_at,
        kind: :deploy,
        summary: marker.git_sha,
        payload: marker
      }
    end)
  end

  defp incident_alerts(app_id, since) do
    Repo.all(from a in Alert, where: a.app_id == ^app_id and a.fired_at > ^since)
    |> Enum.map(fn alert ->
      %{
        at: alert.fired_at,
        kind: :alert,
        summary: alert.message,
        payload: %{id: alert.id, rule: alert.rule, status: alert.status}
      }
    end)
  end

  defp incident_groups(scope, app_id, since) do
    Observability.group_errors(scope, %{app_id: app_id, min_severity: "err", since: since})
    |> Enum.map(fn group ->
      %{
        at: group.last_seen_at,
        kind: :error_group,
        summary: group.sample,
        payload: %{fingerprint: group.fingerprint, count: group.count, severity: group.severity}
      }
    end)
  end
end
