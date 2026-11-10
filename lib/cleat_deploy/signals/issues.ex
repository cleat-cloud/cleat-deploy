defmodule CleatDeploy.Signals.Issues do
  @moduledoc """
  Upserts error issues from collected log events and exposes resolve / ignore
  / reopen for the panel, CLI and MCP.
  """

  import Ecto.Query

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Observability.{Fingerprint, LogEvent}
  alias CleatDeploy.Repo
  alias CleatDeploy.Repo.BusyRetry
  alias CleatDeploy.Signals.Issue

  @error_severities ~w(emerg alert crit err warning)
  @default_limit 100

  @doc "Open or update the issue for an ingested error event."
  @spec record(LogEvent.t()) :: :ok
  def record(%LogEvent{app_id: nil}), do: :ok
  def record(%LogEvent{fingerprint: fingerprint}) when fingerprint in [nil, ""], do: :ok
  def record(%LogEvent{severity: severity}) when severity not in @error_severities, do: :ok

  def record(%LogEvent{} = event) do
    BusyRetry.call(fn -> persist(event) end)
    :ok
  end

  def record(_), do: :ok

  @doc "Tenant issues, newest last-seen first. Default status is unresolved."
  @spec list(Scope.t(), map()) :: [Issue.t()]
  def list(%Scope{} = scope, filters \\ %{}) do
    filters = if is_list(filters), do: Map.new(filters), else: filters
    status = filters[:status] || "unresolved"

    Issue
    |> where([i], i.tenant_id == ^scope.tenant.id)
    |> filter_status(status)
    |> filter_app(filters[:app_id])
    |> order_by([i], desc: i.last_seen_at, desc: i.id)
    |> limit(^(filters[:limit] || @default_limit))
    |> preload(:app)
    |> Repo.all()
  end

  @spec get(Scope.t(), integer()) :: {:ok, Issue.t()} | {:error, :not_found}
  def get(%Scope{tenant: tenant}, id) when is_integer(id) do
    case Repo.get_by(Issue, id: id, tenant_id: tenant.id) do
      nil -> {:error, :not_found}
      issue -> {:ok, Repo.preload(issue, [:app, :last_deployment])}
    end
  end

  def get(%Scope{}, _id), do: {:error, :not_found}

  @spec events(Scope.t(), Issue.t(), keyword()) :: [LogEvent.t()]
  def events(%Scope{tenant: tenant}, %Issue{} = issue, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Repo.all(
      from e in LogEvent,
        where:
          e.tenant_id == ^tenant.id and e.app_id == ^issue.app_id and
            e.fingerprint == ^issue.fingerprint,
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: ^limit
    )
  end

  @spec resolve(Scope.t(), integer()) ::
          {:ok, Issue.t()} | {:error, :not_found | :unauthorized}
  def resolve(scope, id), do: set_status(scope, id, "resolved")

  @spec ignore(Scope.t(), integer()) ::
          {:ok, Issue.t()} | {:error, :not_found | :unauthorized}
  def ignore(scope, id), do: set_status(scope, id, "ignored")

  @spec reopen(Scope.t(), integer()) ::
          {:ok, Issue.t()} | {:error, :not_found | :unauthorized}
  def reopen(scope, id), do: set_status(scope, id, "unresolved")

  defp persist(event) do
    key = [
      tenant_id: event.tenant_id,
      app_id: event.app_id,
      fingerprint: event.fingerprint
    ]

    case Repo.get_by(Issue, key) do
      nil ->
        insert_new(event)

      %Issue{status: "ignored"} = issue ->
        bump(issue, event)

      %Issue{status: "resolved"} = issue ->
        regress(issue, event)

      %Issue{} = issue ->
        bump(issue, event)
    end
  end

  defp insert_new(event) do
    occurred = event.occurred_at
    source = issue_source(event)

    attrs = %{
      tenant_id: event.tenant_id,
      app_id: event.app_id,
      fingerprint: event.fingerprint,
      status: "unresolved",
      severity: event.severity,
      sample: Fingerprint.title(event.message),
      count: 1,
      first_seen_at: occurred,
      last_seen_at: occurred,
      last_deployment_id: event.deployment_id,
      source: source
    }

    case attrs |> Issue.insert_changeset() |> Repo.insert() do
      {:ok, issue} ->
        notify(issue, "opened")
        issue

      {:error, _} ->
        persist(event)
    end
  end

  defp bump(issue, event) do
    issue
    |> Ecto.Changeset.change(%{
      count: issue.count + 1,
      last_seen_at: later(issue.last_seen_at, event.occurred_at),
      last_deployment_id: event.deployment_id || issue.last_deployment_id,
      severity: event.severity,
      sample: Fingerprint.title(event.message),
      source: issue_source(event)
    })
    |> Repo.update!()
  end

  defp regress(issue, event) do
    updated =
      issue
      |> Ecto.Changeset.change(%{
        status: "unresolved",
        count: issue.count + 1,
        last_seen_at: later(issue.last_seen_at, event.occurred_at),
        last_deployment_id: event.deployment_id || issue.last_deployment_id,
        severity: event.severity,
        sample: Fingerprint.title(event.message),
        source: issue_source(event)
      })
      |> Repo.update!()

    notify(updated, "regression")
    updated
  end

  defp set_status(%Scope{} = scope, id, status) do
    with :ok <- writable?(scope),
         {:ok, issue} <- get(scope, id) do
      issue
      |> Ecto.Changeset.change(%{status: status})
      |> Repo.update()
    end
  end

  defp filter_status(query, status) when status in [nil, "", "unresolved"],
    do: where(query, [i], i.status == "unresolved")

  defp filter_status(query, "all"), do: query

  defp filter_status(query, status) when is_binary(status),
    do: where(query, [i], i.status == ^status)

  defp filter_app(query, nil), do: query
  defp filter_app(query, app_id), do: where(query, [i], i.app_id == ^app_id)

  defp later(a, b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  defp issue_source(%LogEvent{source: "otlp"}), do: "otlp"
  defp issue_source(_), do: "journal"

  defp writable?(%Scope{} = scope) do
    if Scope.can_write?(scope), do: :ok, else: {:error, :unauthorized}
  end

  defp notify(issue, action) do
    case webhook_url() do
      nil ->
        issue

      url ->
        payload = %{
          "event" => "signal.issue",
          "action" => action,
          "issue" => %{
            "id" => issue.id,
            "app_id" => issue.app_id,
            "fingerprint" => issue.fingerprint,
            "status" => issue.status,
            "sample" => issue.sample,
            "count" => issue.count,
            "last_deployment_id" => issue.last_deployment_id
          }
        }

        opts = [json: payload] ++ webhook_req_options()
        _ = Req.post(url, opts)
        issue
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
end
