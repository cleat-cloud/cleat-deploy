defmodule CleatDeploy.Signals do
  @moduledoc """
  Corte 02 of Cleat Signals: health, metrics and alerts from stored panel data.

  The overview is computed from `log_events` and deployments in SQLite, so
  detecting a degraded app does not open SSH.
  """

  import Ecto.Query

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo

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

    Enum.map(apps, fn app ->
      cur = Map.get(current, app.id, 0)
      prev = Map.get(previous, app.id, 0)
      reasons = reasons(cur, prev, Map.get(latest, app.id), MapSet.member?(saturated, app.id))

      %{
        app_id: app.id,
        slug: app.slug,
        name: app.name,
        status: status(reasons),
        reasons: reasons,
        error_count: cur,
        previous_error_count: prev,
        preceding_release: Map.get(releases, app.id)
      }
    end)
  end

  defp reasons(current, previous, latest, saturated?) do
    []
    |> maybe_reason(:unavailability, match?(%{status: :failed}, latest))
    |> maybe_reason(:error_rate, error_rate?(current, previous))
    |> maybe_reason(:saturation, saturated?)
  end

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
end
