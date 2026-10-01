defmodule CleatDeploy.Signals.Traces do
  @moduledoc """
  Corte 03 of Cleat Signals: opt-in OTLP JSON traces stored in panel SQLite.

  Sampling is per application (`apps.trace_sample_rate`, default 0) and
  deterministic on the trace id, so a rate of 0 stores nothing.
  """

  import Ecto.Query

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.Repo.BusyRetry
  alias CleatDeploy.Signals.Span

  @doc "Current sampling for an app owned by the scope."
  def get_sampling(%Scope{} = scope, %App{} = app) do
    with :ok <- owned?(scope, app) do
      app = Repo.get!(App, app.id)
      {:ok, sampling(app)}
    end
  end

  @doc "Set sampling in `0.0..1.0`. Rate 0 disables ingest."
  def set_sampling(%Scope{} = scope, %App{} = app, rate) do
    with :ok <- owned?(scope, app) do
      case app |> App.sampling_changeset(%{trace_sample_rate: rate}) |> Repo.update() do
        {:ok, updated} -> {:ok, sampling(updated)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Ingest an OTLP JSON export (`resourceSpans`).

  Spans of a trace are accepted or dropped together. Duplicates of
  `(tenant, trace_id, span_id)` are ignored.
  """
  def ingest(%Scope{} = scope, %App{} = app, %{"resourceSpans" => resource_spans})
      when is_list(resource_spans) do
    with :ok <- owned?(scope, app) do
      rate = sample_rate(Repo.get!(App, app.id))
      parsed = Enum.flat_map(resource_spans, &flatten_resource/1)

      {accepted, dropped} =
        parsed
        |> Enum.group_by(& &1.trace_id)
        |> Enum.reduce({0, 0}, fn {trace_id, spans}, {acc, drop} ->
          if sampled?(trace_id, rate) do
            {acc + insert_spans(scope, app, spans), drop}
          else
            {acc, drop + length(spans)}
          end
        end)

      {:ok, %{accepted: accepted, dropped: dropped}}
    end
  end

  def ingest(%Scope{}, %App{}, _payload), do: {:error, :invalid_payload}

  @doc "Trace summaries for an app, newest first. Option `:service` filters by service name."
  def list(%Scope{} = scope, %App{} = app, opts \\ []) do
    service = Keyword.get(opts, :service)

    scope
    |> load_spans(app)
    |> Enum.group_by(& &1.trace_id)
    |> Enum.map(fn {trace_id, spans} -> summarize(trace_id, spans) end)
    |> Enum.filter(&matches_service?(&1, service))
    |> Enum.sort_by(& &1.started_at_unix_nano, :desc)
  end

  @doc "Spans of one trace, parent before children, with `:depth`."
  def waterfall(%Scope{} = scope, %App{} = app, trace_id) do
    case load_spans(scope, app, normalize_id(trace_id)) do
      [] -> {:error, :not_found}
      spans -> {:ok, %{trace_id: normalize_id(trace_id), spans: with_depth(spans)}}
    end
  end

  @doc "Dependency graph from parent/child services and `peer.service` attributes."
  def service_map(%Scope{} = scope, %App{} = app, opts \\ []) do
    spans = load_spans(scope, app, Keyword.get(opts, :trace_id))
    service = Keyword.get(opts, :service)

    traces =
      if is_binary(service) and service != "",
        do: Enum.filter(spans, &(&1.service_name == service)),
        else: spans

    trace_ids = traces |> Enum.map(& &1.trace_id) |> MapSet.new()
    selected = Enum.filter(spans, &MapSet.member?(trace_ids, &1.trace_id))
    by_id = Map.new(selected, &{&1.span_id, &1})

    parent_edges =
      for child <- selected,
          parent = Map.get(by_id, child.parent_span_id),
          is_map(parent),
          parent.service_name != child.service_name,
          do: {parent.service_name, child.service_name}

    peer_edges =
      for span <- selected,
          peer when is_binary(peer) <- [peer_service(span.attributes)],
          peer != span.service_name,
          do: {span.service_name, peer}

    edges =
      (parent_edges ++ peer_edges)
      |> Enum.frequencies()
      |> Enum.map(fn {{from, to}, count} -> %{from: from, to: to, count: count} end)

    nodes =
      selected
      |> Enum.flat_map(fn span -> [span.service_name, peer_service(span.attributes)] end)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&%{service: &1})

    %{nodes: nodes, edges: edges}
  end

  @doc "Log events whose message contains the hex trace id."
  def logs(%Scope{} = scope, %App{} = app, trace_id) do
    hex = normalize_id(trace_id)
    pattern = "%#{hex}%"

    Repo.all(
      from e in LogEvent,
        where:
          e.tenant_id == ^scope.tenant.id and e.app_id == ^app.id and like(e.message, ^pattern),
        order_by: [asc: e.occurred_at, asc: e.id]
    )
  end

  defp sampling(%App{} = app) do
    %{app_id: app.id, slug: app.slug, trace_sample_rate: sample_rate(app)}
  end

  defp sample_rate(%App{trace_sample_rate: rate}) when is_number(rate), do: rate / 1
  defp sample_rate(_), do: 0.0

  defp owned?(%Scope{tenant: %{id: id}}, %App{tenant_id: id}), do: :ok
  defp owned?(%Scope{}, %App{}), do: {:error, :not_found}

  defp sampled?(_trace_id, rate) when rate <= 0, do: false
  defp sampled?(_trace_id, rate) when rate >= 1, do: true

  defp sampled?(trace_id, rate) do
    <<n::unsigned-32, _rest::binary>> = :crypto.hash(:sha256, trace_id)
    n < trunc(rate * 4_294_967_296)
  end

  defp flatten_resource(resource) when is_map(resource) do
    service = resource_service(resource)

    resource
    |> Map.get("scopeSpans", [])
    |> List.wrap()
    |> Enum.flat_map(fn scope -> scope |> Map.get("spans", []) |> List.wrap() end)
    |> Enum.map(&normalize_span(&1, service))
    |> Enum.reject(&is_nil/1)
  end

  defp flatten_resource(_), do: []

  defp resource_service(%{"resource" => %{"attributes" => attrs}}) when is_list(attrs) do
    Enum.find_value(attrs, "", fn
      %{"key" => "service.name", "value" => value} -> attr_value(value)
      _ -> nil
    end) || ""
  end

  defp resource_service(_), do: ""

  defp normalize_span(span, service) when is_map(span) do
    start_ns = to_int(Map.get(span, "startTimeUnixNano") || Map.get(span, "start_time_unix_nano"))
    end_ns = to_int(Map.get(span, "endTimeUnixNano") || Map.get(span, "end_time_unix_nano"))
    trace_id = normalize_id(Map.get(span, "traceId") || Map.get(span, "trace_id"))
    span_id = normalize_id(Map.get(span, "spanId") || Map.get(span, "span_id"))

    if trace_id == "" or span_id == "" do
      nil
    else
      %{
        trace_id: trace_id,
        span_id: span_id,
        parent_span_id:
          normalize_id(Map.get(span, "parentSpanId") || Map.get(span, "parent_span_id")),
        name: to_string(Map.get(span, "name") || ""),
        kind: kind(Map.get(span, "kind")),
        service_name: service,
        status_code: status_code(Map.get(span, "status")),
        start_time_unix_nano: start_ns,
        end_time_unix_nano: end_ns,
        duration_ns: max(end_ns - start_ns, 0),
        attributes: flatten_attrs(Map.get(span, "attributes"))
      }
    end
  end

  defp normalize_span(_, _), do: nil

  defp insert_spans(scope, app, spans) do
    Enum.reduce(spans, 0, fn attrs, acc ->
      changeset =
        Span.insert_changeset(Map.merge(attrs, %{tenant_id: scope.tenant.id, app_id: app.id}))

      case BusyRetry.call(fn ->
             Repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: [:tenant_id, :trace_id, :span_id]
             )
           end) do
        {:ok, %{id: id}} when is_integer(id) -> acc + 1
        _ -> acc
      end
    end)
  end

  defp load_spans(scope, app, trace_id \\ nil) do
    query =
      from s in Span,
        where: s.tenant_id == ^scope.tenant.id and s.app_id == ^app.id,
        order_by: [asc: s.start_time_unix_nano, asc: s.id]

    query =
      if is_binary(trace_id) and trace_id != "",
        do: where(query, [s], s.trace_id == ^trace_id),
        else: query

    Repo.all(query)
  end

  defp summarize(trace_id, spans) do
    sorted = Enum.sort_by(spans, &{&1.start_time_unix_nano, &1.id})
    start_ns = hd(sorted).start_time_unix_nano
    end_ns = Enum.max_by(spans, & &1.end_time_unix_nano).end_time_unix_nano
    root = Enum.find(sorted, &(&1.parent_span_id in [nil, ""])) || hd(sorted)

    %{
      trace_id: trace_id,
      root_name: root.name,
      services: spans |> Enum.map(& &1.service_name) |> Enum.uniq(),
      started_at_unix_nano: start_ns,
      duration_ns: max(end_ns - start_ns, 0),
      span_count: length(spans),
      error: Enum.any?(spans, &(&1.status_code == "error"))
    }
  end

  defp matches_service?(_trace, service) when service in [nil, ""], do: true
  defp matches_service?(trace, service), do: service in trace.services

  defp with_depth(spans) do
    by_parent = Enum.group_by(spans, & &1.parent_span_id)
    ids = MapSet.new(Enum.map(spans, & &1.span_id))

    roots =
      spans
      |> Enum.filter(
        &(&1.parent_span_id in [nil, ""] or not MapSet.member?(ids, &1.parent_span_id))
      )
      |> Enum.sort_by(&{&1.start_time_unix_nano, &1.id})

    Enum.flat_map(roots, &walk(&1, 0, by_parent))
  end

  defp walk(span, depth, by_parent) do
    children =
      by_parent
      |> Map.get(span.span_id, [])
      |> Enum.sort_by(&{&1.start_time_unix_nano, &1.id})

    [
      Map.put(span_map(span), :depth, depth)
      | Enum.flat_map(children, &walk(&1, depth + 1, by_parent))
    ]
  end

  defp span_map(span) do
    %{
      trace_id: span.trace_id,
      span_id: span.span_id,
      parent_span_id: span.parent_span_id,
      name: span.name,
      kind: span.kind,
      service_name: span.service_name,
      status_code: span.status_code,
      start_time_unix_nano: span.start_time_unix_nano,
      duration_ns: span.duration_ns,
      attributes: span.attributes
    }
  end

  defp peer_service(%{"peer.service" => value}) when is_binary(value), do: value
  defp peer_service(_), do: nil

  defp flatten_attrs(list) when is_list(list) do
    Enum.reduce(list, %{}, fn
      %{"key" => key, "value" => value}, acc when is_binary(key) ->
        Map.put(acc, key, attr_value(value))

      _, acc ->
        acc
    end)
  end

  defp flatten_attrs(_), do: %{}

  defp attr_value(%{"stringValue" => value}) when is_binary(value), do: value
  defp attr_value(%{"intValue" => value}) when is_integer(value), do: value
  defp attr_value(%{"intValue" => value}) when is_binary(value), do: value
  defp attr_value(%{"boolValue" => value}) when is_boolean(value), do: value
  defp attr_value(%{"doubleValue" => value}) when is_number(value), do: value
  defp attr_value(_), do: nil

  defp kind(1), do: "internal"
  defp kind(2), do: "server"
  defp kind(3), do: "client"
  defp kind(4), do: "producer"
  defp kind(5), do: "consumer"
  defp kind(value) when is_binary(value), do: String.downcase(value)
  defp kind(_), do: "unspecified"

  defp status_code(%{"code" => 1}), do: "ok"
  defp status_code(%{"code" => 2}), do: "error"
  defp status_code(_), do: "unset"

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp normalize_id(nil), do: ""
  defp normalize_id(id) when is_binary(id), do: id |> String.trim() |> String.downcase()
  defp normalize_id(_), do: ""
end
