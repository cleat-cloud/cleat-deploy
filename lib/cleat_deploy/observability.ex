defmodule CleatDeploy.Observability do
  @moduledoc """
  The Cleat log collector.

  Corte 01 of the observability study: journal lines are pulled from the
  server over the same SSH seam used for live logs, enriched with Cleat
  context (tenant, app, server, latest deployment, unit) and persisted as
  `log_events`. Reads are tenant-scoped and served from the store, so filters
  by app, release and severity become plain queries instead of SSH calls.

  The collector is the panel for now; swapping it for an OTLP receiver later
  does not change the stored shape or the API.
  """

  import Ecto.Query

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability.{Fingerprint, Journal, LogEvent, Query, Redact}
  alias CleatDeploy.Repo
  alias CleatDeploy.Repo.BusyRetry
  alias CleatDeploy.Servers.Server

  @ingest_tail 1000
  @ingest_overlap_seconds 300
  @retention_days 7
  @max_rows_per_tenant 50_000

  @type filters :: %{
          optional(:app_id) => integer() | nil,
          optional(:server_id) => integer() | nil,
          optional(:unit) => String.t() | nil,
          optional(:severity) => String.t() | nil,
          optional(:min_severity) => String.t() | nil,
          optional(:q) => String.t() | nil,
          optional(:since) => DateTime.t() | nil,
          optional(:until) => DateTime.t() | nil,
          optional(:limit) => pos_integer() | nil
        }

  # -- collection ------------------------------------------------------------

  @doc """
  Collects and persists the app's journal window.
  """
  @spec ingest_app(App.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def ingest_app(%App{} = app) do
    app = Repo.preload(app, :server)
    unit = app.systemd_unit || App.default_systemd_unit(app.slug, app.runtime || "phoenix")

    ingest(app.server, %{
      tenant_id: app.tenant_id,
      app_id: app.id,
      deployment_id: latest_deployment_id(app.id),
      source: "app",
      unit: unit,
      environment: app.branch || ""
    })
  end

  @doc """
  Collects and persists the server's journal window.

  With `unit` nil the whole host journal is read and each entry keeps its own
  systemd unit.
  """
  @spec ingest_server(Server.t(), String.t() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def ingest_server(%Server{} = server, unit \\ nil) do
    ingest(server, %{
      tenant_id: server.tenant_id,
      app_id: nil,
      deployment_id: nil,
      source: "server",
      unit: unit,
      environment: ""
    })
  end

  defp ingest(%Server{} = server, meta) do
    argv = Journal.argv(unit: meta.unit, tail: @ingest_tail, since: since_for(server, meta))

    case client().run(server, argv) do
      {:ok, output} ->
        {count, _} = insert_entries(server, meta, Journal.parse(output))
        {:ok, count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp since_for(server, meta) do
    case last_occurred_at({server, meta}) do
      nil ->
        nil

      last ->
        overlap = DateTime.add(DateTime.utc_now(:second), -@ingest_overlap_seconds, :second)

        last
        |> DateTime.add(-@ingest_overlap_seconds, :second)
        |> max_datetime(overlap)
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
    end
  end

  defp last_occurred_at({_server, %{app_id: app_id}}) when is_integer(app_id) do
    Repo.one(from(e in LogEvent, where: e.app_id == ^app_id, select: max(e.occurred_at)))
  end

  defp last_occurred_at({server, %{unit: unit}}) do
    Repo.one(
      from(e in LogEvent,
        where: e.server_id == ^server.id and e.unit == ^(unit || ""),
        select: max(e.occurred_at)
      )
    )
  end

  defp max_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  # ecto_libsql implements Connection.insert/7. Ecto 3.14's insert_all calls
  # insert/8, which crashes in production (`function insert/8 is undefined`).
  # Per-row Repo.insert matches the rest of the panel (accounts, settings).
  defp insert_entries(_server, _meta, []), do: {0, nil}

  defp insert_entries(server, meta, entries) do
    count =
      Enum.reduce(entries, 0, fn entry, acc ->
        message = Redact.message(entry.message)

        event = %LogEvent{
          tenant_id: meta.tenant_id,
          app_id: meta.app_id,
          server_id: server.id,
          deployment_id: meta.deployment_id,
          source: meta.source,
          unit: meta.unit || entry.unit || "",
          cursor: entry.cursor,
          severity: entry.severity,
          message: message,
          environment: meta.environment || "",
          fingerprint: Fingerprint.of(message),
          occurred_at: entry.occurred_at
        }

        case BusyRetry.call(fn ->
               Repo.insert(event,
                 on_conflict: :nothing,
                 conflict_target: [:server_id, :cursor]
               )
             end) do
          {:ok, %{id: id}} when is_integer(id) -> acc + 1
          _ -> acc
        end
      end)

    {count, nil}
  end

  defp latest_deployment_id(app_id) do
    Repo.one(
      from(d in Deployment,
        where: d.app_id == ^app_id,
        order_by: [desc: d.id],
        limit: 1,
        select: d.id
      )
    )
  end

  # -- search ----------------------------------------------------------------

  @doc """
  Searches persisted log events for a tenant scope, newest first.
  """
  @spec search(Scope.t(), filters()) :: [LogEvent.t()]
  def search(scope, filters \\ %{}), do: Query.search(scope, filters)

  @doc """
  Groups similar error/warning lines for the tenant.
  """
  def group_errors(scope, filters \\ %{}), do: Query.group_errors(scope, filters)

  @doc """
  Parses a search timestamp: ISO 8601, `YYYY-MM-DD[ HH:MM:SS]` or a relative
  window like `30m`, `2h`, `1d` (resolved against now).
  """
  @spec parse_time(String.t() | nil) :: {:ok, DateTime.t() | nil} | {:error, :invalid}
  def parse_time(nil), do: {:ok, nil}
  def parse_time(""), do: {:ok, nil}

  def parse_time(value) when is_binary(value) do
    cond do
      match = relative_seconds(value) ->
        {:ok, DateTime.add(DateTime.utc_now(:second), -match, :second)}

      true ->
        parse_absolute_time(value)
    end
  end

  def parse_time(_), do: {:error, :invalid}

  defp parse_absolute_time(value) do
    value = String.trim(value)

    with :error <- iso_time(value),
         :error <- date_time(value) do
      {:error, :invalid}
    else
      {:ok, datetime} -> {:ok, datetime}
    end
  end

  defp iso_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      _ -> :error
    end
  end

  defp date_time(value) do
    normalized = String.replace(value, " ", "T")

    normalized =
      if String.length(normalized) == 10, do: normalized <> "T00:00:00Z", else: normalized <> "Z"

    iso_time(normalized)
  end

  defp relative_seconds(value) do
    case Regex.run(~r/^-?(\d+)(s|m|h|d|w)$/, String.trim(value)) do
      [_, amount, unit] -> String.to_integer(amount) * unit_seconds(unit)
      _ -> nil
    end
  end

  defp unit_seconds("s"), do: 1
  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3_600
  defp unit_seconds("d"), do: 86_400
  defp unit_seconds("w"), do: 604_800

  @doc """
  Validates a search limit.
  """
  @spec parse_limit(term()) :: {:ok, pos_integer()} | {:error, :invalid}
  def parse_limit(value), do: Query.parse_limit(value)

  # -- retention -------------------------------------------------------------

  @doc """
  Drops entries older than the retention window and trims each tenant to the
  configured row cap.
  """
  @spec prune(keyword()) :: {:ok, non_neg_integer()}
  def prune(opts \\ []) do
    days = Keyword.get(opts, :retention_days, retention_days())
    max_rows = Keyword.get(opts, :max_rows_per_tenant, max_rows_per_tenant())
    cutoff = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

    {expired, _} = Repo.delete_all(from(e in LogEvent, where: e.occurred_at < ^cutoff))

    trimmed =
      LogEvent
      |> distinct(true)
      |> select([e], e.tenant_id)
      |> Repo.all()
      |> Enum.reduce(0, fn tenant_id, acc -> acc + trim_tenant(tenant_id, max_rows) end)

    {:ok, expired + trimmed}
  end

  defp trim_tenant(tenant_id, max_rows) do
    keep =
      LogEvent
      |> where([e], e.tenant_id == ^tenant_id)
      |> order_by([e], desc: e.id)
      |> limit(^max_rows)
      |> select([e], e.id)

    {deleted, _} =
      Repo.delete_all(
        from(e in LogEvent, where: e.tenant_id == ^tenant_id and e.id not in subquery(keep))
      )

    deleted
  end

  # -- config ----------------------------------------------------------------

  @doc "Whether the background collector is enabled for this instance."
  def collector_enabled?, do: Application.get_env(:cleat_deploy, :log_collector_enabled, false)

  defp retention_days,
    do: Application.get_env(:cleat_deploy, :log_retention_days, @retention_days)

  defp max_rows_per_tenant,
    do: Application.get_env(:cleat_deploy, :log_max_rows_per_tenant, @max_rows_per_tenant)

  defp client do
    Application.get_env(:cleat_deploy, :runtime_logs, CleatDeploy.Apps.RuntimeLogsSsh)
  end
end
