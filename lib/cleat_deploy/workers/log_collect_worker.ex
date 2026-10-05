defmodule CleatDeploy.Workers.LogCollectWorker do
  @moduledoc """
  Periodically collects journal windows for every non-static app, records a
  sweep heartbeat and trims the log store.

  Collection is opt-in: nothing runs unless `:log_collector_enabled` is set
  (see `LOG_COLLECTOR_ENABLED`), so enabling the collector is a deliberate
  decision per instance. Sweep failures are logged at warning level and
  persisted in the `collector_runs` heartbeat, so a stopped collector is
  visible in Signals instead of reading as "0 errors".
  """

  use Oban.Worker, queue: :logs, max_attempts: 3

  import Ecto.Query

  require Logger

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Observability
  alias CleatDeploy.Repo

  @failed_slugs_limit 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if Observability.collector_enabled?() do
      maybe_record(collect(args), args)
      maybe_prune(args)
    end

    :ok
  end

  defp maybe_record({:ok, stats}, _args), do: Observability.record_collect(stats)
  defp maybe_record(_result, _args), do: :ok

  # Per-app ingest (after a deploy) must not run the tenant trim. The quadratic
  # NOT IN prune on Turso billed 8.5B row reads; even the cheap range trim is
  # reserved for the periodic sweep.
  defp maybe_prune(%{"app_id" => _}), do: :ok
  defp maybe_prune(_args), do: Observability.prune()

  defp collect(%{"app_id" => app_id}) do
    case Repo.get(App, app_id) do
      %App{} = app -> collect_app(app)
      _ -> :ok
    end
  end

  defp collect(_args), do: collect()

  defp collect do
    apps =
      App
      |> where([a], a.runtime != "static" and not is_nil(a.tenant_id))
      |> Repo.all()

    results = Enum.map(apps, fn app -> {app.slug, collect_app(app)} end)
    failures = for {slug, :error} <- results, do: slug

    if failures != [] do
      Logger.warning(
        "log collect: #{length(failures)}/#{length(results)} apps failed: #{Enum.join(failures, ", ")}"
      )
    end

    {:ok,
     %{
       apps: length(results),
       failures: length(failures),
       failed_slugs: %{"slugs" => Enum.take(failures, @failed_slugs_limit)}
     }}
  end

  defp collect_app(app) do
    case Observability.ingest_app(app) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("log collect failed for #{app.slug}: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("log collect crashed for #{app.slug}: #{Exception.message(error)}")
      :error
  end
end
