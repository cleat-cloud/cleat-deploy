defmodule CleatDeploy.Workers.IdleShutdownWorker do
  @moduledoc false
  # Do not set `unique:` — Oban Lite unique SQL is rejected by Turso/libSQL.
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.IdleShutdown
  alias CleatDeploy.Settings

  @impl Oban.Worker
  def perform(_job) do
    # No row with the feature enabled means the sweeper is a no-op, which is
    # also the default for every tenant.
    Enum.each(Settings.list_idle_shutdown(), fn {tenant_id, minutes} ->
      result = tenant_id |> Apps.list_idle_candidates() |> IdleShutdown.sweep(minutes)

      Logger.info(
        "idle_shutdown tenant=#{tenant_id} minutes=#{minutes} stopped=#{inspect(result.stopped)} skipped=#{length(result.skipped)}"
      )
    end)

    :ok
  end
end
