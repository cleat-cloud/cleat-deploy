defmodule CleatDeploy.Observability.Query do
  @moduledoc false

  import Ecto.Query

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo

  @default_limit 200
  @max_limit 1000
  @search_bytes 200
  @error_severities ~w(emerg alert crit err warning)

  def search(%Scope{} = scope, filters \\ %{}) do
    filters = normalize(filters)

    LogEvent
    |> where([e], e.tenant_id == ^scope.tenant.id)
    |> apply_filters(filters)
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> limit(^(filters[:limit] || @default_limit))
    |> Repo.all()
  end

  def group_errors(%Scope{} = scope, filters \\ %{}) do
    filters = normalize(filters)

    LogEvent
    |> where([e], e.tenant_id == ^scope.tenant.id)
    |> where([e], e.severity in ^@error_severities)
    |> where([e], e.fingerprint != "")
    |> apply_filters(filters)
    |> group_by([e], [e.fingerprint, e.severity])
    |> select([e], %{
      fingerprint: e.fingerprint,
      severity: e.severity,
      count: count(e.id),
      sample: min(e.message),
      last_seen_at: max(e.occurred_at)
    })
    |> order_by([e], desc: count(e.id))
    |> limit(^(filters[:limit] || 50))
    |> Repo.all()
  end

  def parse_limit(nil), do: {:ok, @default_limit}

  def parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> parse_limit(int)
      _ -> {:error, :invalid}
    end
  end

  def parse_limit(value) when is_integer(value) and value >= 1 and value <= @max_limit,
    do: {:ok, value}

  def parse_limit(_), do: {:error, :invalid}

  defp apply_filters(query, filters) do
    query
    |> filter_app(filters[:app_id])
    |> filter_server(filters[:server_id])
    |> filter_unit(filters[:unit])
    |> filter_severity(filters[:severity], filters[:min_severity])
    |> filter_query(filters[:q])
    |> filter_release(filters[:release])
    |> filter_environment(filters[:environment])
    |> filter_since(filters[:since])
    |> filter_until(filters[:until])
  end

  defp normalize(filters) when is_list(filters), do: Map.new(filters)
  defp normalize(filters), do: filters

  defp filter_app(query, nil), do: query
  defp filter_app(query, app_id), do: where(query, [e], e.app_id == ^app_id)

  defp filter_server(query, nil), do: query
  defp filter_server(query, server_id), do: where(query, [e], e.server_id == ^server_id)

  defp filter_unit(query, nil), do: query
  defp filter_unit(query, unit), do: where(query, [e], e.unit == ^unit)

  defp filter_severity(query, nil, nil), do: query

  defp filter_severity(query, severity, _min) when is_binary(severity),
    do: where(query, [e], e.severity == ^severity)

  defp filter_severity(query, _severity, min) when is_binary(min),
    do: where(query, [e], e.severity in ^LogEvent.severities_at_least(min))

  defp filter_query(query, nil), do: query
  defp filter_query(query, ""), do: query

  defp filter_query(query, term) do
    term = term |> String.slice(0, @search_bytes) |> String.downcase()

    if term == "" do
      query
    else
      where(query, [e], like(fragment("lower(?)", e.message), ^("%" <> term <> "%")))
    end
  end

  defp filter_release(query, value) when value in [nil, ""], do: query

  defp filter_release(query, release) do
    case release_ids(release) do
      [] -> where(query, [e], false)
      ids -> where(query, [e], e.deployment_id in ^ids)
    end
  end

  defp release_ids(release) do
    case Integer.parse(release) do
      {id, ""} ->
        [id]

      _ ->
        like = release <> "%"
        Repo.all(from(d in Deployment, where: like(d.git_sha, ^like), select: d.id))
    end
  end

  defp filter_environment(query, value) when value in [nil, ""], do: query
  defp filter_environment(query, env), do: where(query, [e], e.environment == ^env)

  defp filter_since(query, nil), do: query
  defp filter_since(query, since), do: where(query, [e], e.occurred_at >= ^since)

  defp filter_until(query, nil), do: query
  defp filter_until(query, until), do: where(query, [e], e.occurred_at <= ^until)
end
