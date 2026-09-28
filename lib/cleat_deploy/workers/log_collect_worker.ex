defmodule CleatDeploy.Workers.LogCollectWorker do
  @moduledoc """
  Periodically collects journal windows for every non-static app and trims the
  log store.

  Collection is opt-in: nothing runs unless `:log_collector_enabled` is set
  (see `LOG_COLLECTOR_ENABLED`), so enabling the collector is a deliberate
  decision per instance.
  """

  use Oban.Worker, queue: :logs, max_attempts: 3

  import Ecto.Query

  require Logger

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Observability
  alias CleatDeploy.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Observability.collector_enabled?() do
      collect()
      Observability.prune()
    end

    :ok
  end

  defp collect do
    App
    |> where([a], a.runtime != "static" and not is_nil(a.tenant_id))
    |> Repo.all()
    |> Enum.each(&collect_app/1)
  end

  defp collect_app(app) do
    case Observability.ingest_app(app) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.debug("log collect failed for #{app.slug}: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("log collect crashed for #{app.slug}: #{Exception.message(error)}")
  end
end
