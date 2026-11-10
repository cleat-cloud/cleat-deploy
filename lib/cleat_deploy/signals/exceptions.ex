defmodule CleatDeploy.Signals.Exceptions do
  @moduledoc """
  Corte 04c of Cleat Signals: opt-in OTLP JSON exceptions.

  Accepts `resourceLogs` with `exception.*` attributes and `resourceSpans`
  with `exception` events. Sampling is per application
  (`apps.exception_sample_rate`, default 0). Rate 0 stores nothing.
  """

  import Ecto.Query

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability.{Fingerprint, LogEvent, Redact}
  alias CleatDeploy.Repo
  alias CleatDeploy.Repo.BusyRetry
  alias CleatDeploy.Signals.Issues

  @doc """
  Ingest OTLP JSON logs (`resourceLogs`) or exception span events
  (`resourceSpans`). Records without `exception.*` are ignored.
  """
  @spec ingest(Scope.t(), App.t(), map()) ::
          {:ok, %{accepted: non_neg_integer(), dropped: non_neg_integer()}}
          | {:error, :invalid_payload | :not_found}
  def ingest(%Scope{} = scope, %App{} = app, payload) when is_map(payload) do
    with :ok <- owned?(scope, app),
         {:ok, records} <- extract(payload) do
      {:ok, insert_records(scope, Repo.get!(App, app.id), records)}
    end
  end

  def ingest(%Scope{}, %App{}, _), do: {:error, :invalid_payload}

  defp insert_records(scope, app, records) do
    rate = sample_rate(app.exception_sample_rate)
    deployment_id = latest_deployment_id(app.id)

    Enum.reduce(records, %{accepted: 0, dropped: 0}, fn record, acc ->
      tally(acc, persist(scope, app, record, rate, deployment_id))
    end)
  end

  defp tally(acc, :accepted), do: %{acc | accepted: acc.accepted + 1}
  defp tally(acc, :dropped), do: %{acc | dropped: acc.dropped + 1}
  defp tally(acc, :duplicate), do: acc

  defp extract(%{"resourceLogs" => logs} = payload) when is_list(logs) do
    from_logs = Enum.flat_map(logs, &flatten_resource_logs/1)
    from_spans = payload |> Map.get("resourceSpans") |> flatten_resource_spans()
    {:ok, from_logs ++ from_spans}
  end

  defp extract(%{"resourceSpans" => spans}) when is_list(spans) do
    {:ok, flatten_resource_spans(spans)}
  end

  defp extract(_), do: {:error, :invalid_payload}

  defp persist(scope, app, record, rate, deployment_id) do
    message = record |> assemble() |> Redact.message()
    fingerprint = Fingerprint.of(message)
    occurred_at = occurred_at(record.time_unix_nano)

    cond do
      message == "" ->
        :dropped

      not sampled?(fingerprint, rate) ->
        :dropped

      true ->
        insert_event(scope, app, record, message, fingerprint, occurred_at, deployment_id)
    end
  end

  defp insert_event(scope, app, record, message, fingerprint, occurred_at, deployment_id) do
    event = %LogEvent{
      tenant_id: scope.tenant.id,
      app_id: app.id,
      server_id: app.server_id,
      deployment_id: deployment_id,
      source: "otlp",
      unit: record.service_name,
      cursor: cursor(app, occurred_at, message),
      severity: "err",
      message: message,
      environment: app.branch || "",
      fingerprint: fingerprint,
      occurred_at: occurred_at
    }

    case BusyRetry.call(fn ->
           Repo.insert(event, on_conflict: :nothing, conflict_target: [:server_id, :cursor])
         end) do
      {:ok, %{id: id} = inserted} when is_integer(id) ->
        Issues.record(inserted)
        :accepted

      _ ->
        :duplicate
    end
  end

  defp assemble(record) do
    type = String.trim(record.type || "")
    message = String.trim(record.message || "")
    stack = String.trim(record.stack || "")

    cond do
      stack != "" and Fingerprint.exception?(stack) -> stack
      stack != "" -> join_nonempty([headline(type, message), stack])
      true -> headline(type, message)
    end
  end

  defp headline("", message), do: message
  defp headline(type, message) when message == "", do: type

  defp headline(type, message) do
    cond do
      String.starts_with?(message, "** (") -> message
      String.starts_with?(message, type <> ":") -> message
      String.starts_with?(message, type <> " ") -> message
      true -> "#{type}: #{message}"
    end
  end

  defp join_nonempty(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")

  defp flatten_resource_logs(resource) when is_map(resource) do
    service = resource_service(resource)

    resource
    |> Map.get("scopeLogs", [])
    |> List.wrap()
    |> Enum.flat_map(fn scope -> scope |> Map.get("logRecords", []) |> List.wrap() end)
    |> Enum.map(&normalize_log(&1, service))
    |> Enum.reject(&is_nil/1)
  end

  defp flatten_resource_logs(_), do: []

  defp flatten_resource_spans(spans) when is_list(spans) do
    Enum.flat_map(spans, fn resource ->
      service = resource_service(resource)

      resource
      |> Map.get("scopeSpans", [])
      |> List.wrap()
      |> Enum.flat_map(fn scope -> scope |> Map.get("spans", []) |> List.wrap() end)
      |> Enum.flat_map(&span_exceptions(&1, service))
    end)
  end

  defp flatten_resource_spans(_), do: []

  defp normalize_log(record, service) when is_map(record) do
    attrs = flatten_attrs(Map.get(record, "attributes"))
    type = attrs["exception.type"]
    message = attrs["exception.message"] || body_string(Map.get(record, "body"))
    stack = attrs["exception.stacktrace"]

    if exception_record?(type, message, stack) do
      %{
        service_name: service,
        type: type || "",
        message: message || "",
        stack: stack || "",
        time_unix_nano:
          to_int(Map.get(record, "timeUnixNano") || Map.get(record, "time_unix_nano"))
      }
    end
  end

  defp normalize_log(_, _), do: nil

  defp span_exceptions(span, service) when is_map(span) do
    span
    |> Map.get("events", [])
    |> List.wrap()
    |> Enum.filter(&(event_name(&1) == "exception"))
    |> Enum.map(&normalize_event(&1, service))
    |> Enum.reject(&is_nil/1)
  end

  defp span_exceptions(_, _), do: []

  defp normalize_event(event, service) when is_map(event) do
    attrs = flatten_attrs(Map.get(event, "attributes"))
    type = attrs["exception.type"]
    message = attrs["exception.message"]
    stack = attrs["exception.stacktrace"]

    if exception_record?(type, message, stack) do
      %{
        service_name: service,
        type: type || "",
        message: message || "",
        stack: stack || "",
        time_unix_nano: to_int(Map.get(event, "timeUnixNano") || Map.get(event, "time_unix_nano"))
      }
    end
  end

  defp normalize_event(_, _), do: nil

  defp exception_record?(type, message, stack) do
    [type, message, stack]
    |> Enum.any?(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp event_name(%{"name" => name}) when is_binary(name), do: name
  defp event_name(_), do: ""

  defp resource_service(%{"resource" => %{"attributes" => attrs}}) when is_list(attrs) do
    Enum.find_value(attrs, "", fn
      %{"key" => "service.name", "value" => value} -> attr_value(value)
      _ -> nil
    end) || ""
  end

  defp resource_service(_), do: ""

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
  defp attr_value(%{"intValue" => value}) when is_integer(value), do: Integer.to_string(value)
  defp attr_value(%{"intValue" => value}) when is_binary(value), do: value
  defp attr_value(_), do: nil

  defp body_string(%{"stringValue" => value}) when is_binary(value), do: value
  defp body_string(value) when is_binary(value), do: value
  defp body_string(_), do: ""

  defp occurred_at(ns) when is_integer(ns) and ns > 0 do
    ns
    |> div(1_000_000_000)
    |> DateTime.from_unix!()
    |> DateTime.truncate(:second)
  end

  defp occurred_at(_), do: DateTime.utc_now(:second)

  defp cursor(app, occurred_at, message) do
    material = "#{app.id}|#{DateTime.to_iso8601(occurred_at)}|#{message}"

    hash =
      :sha256
      |> :crypto.hash(material)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 32)

    "otlp:#{hash}"
  end

  defp latest_deployment_id(app_id) do
    Repo.one(
      from d in Deployment,
        where: d.app_id == ^app_id,
        order_by: [desc: d.id],
        limit: 1,
        select: d.id
    )
  end

  defp sample_rate(rate) when is_number(rate), do: rate / 1
  defp sample_rate(_), do: 0.0

  defp sampled?(_key, rate) when rate <= 0, do: false
  defp sampled?(_key, rate) when rate >= 1, do: true

  defp sampled?(key, rate) do
    <<n::unsigned-32, _rest::binary>> = :crypto.hash(:sha256, key)
    n < trunc(rate * 4_294_967_296)
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp owned?(%Scope{tenant: %{id: id}}, %App{tenant_id: id}), do: :ok
  defp owned?(%Scope{}, %App{}), do: {:error, :not_found}
end
