defmodule CleatDeploy.Workers.AutoDeployHealthWorker do
  @moduledoc false
  # Do not set `unique:` — Oban Lite unique SQL is rejected by Turso/libSQL.
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias CleatDeploy.Apps
  alias CleatDeploy.Deploy.Target
  alias CleatDeploy.Deployments
  alias CleatDeploy.Servers

  @impl Oban.Worker
  def perform(_job) do
    webhooks = Apps.sync_all_github_webhooks()
    ips = Target.reconcile_server_ips()
    inventory = Servers.sync_all_inventories()
    recovered = Deployments.recover_orphaned_running(booted_at())
    requeued = Deployments.recover_orphaned_queued()

    Logger.info(
      "auto_deploy_health webhooks=#{inspect(webhooks)} server_ips=#{inspect(ips)} inventory=#{inventory_log(inventory)} recovered=#{length(recovered)} requeued=#{length(requeued)}"
    )

    :ok
  end

  defp inventory_log(result) do
    "running=#{length(result.updated)} missing=#{length(result.missing)} private=#{length(result.private)} new=#{length(result.discovered)}"
  end

  # `:wall_clock` reports how long this VM has been running, so a job attempted
  # before that instant belongs to a previous boot and cannot still be working.
  defp booted_at do
    {uptime_ms, _since_last_call} = :erlang.statistics(:wall_clock)

    DateTime.add(DateTime.utc_now(:second), -div(uptime_ms, 1_000), :second)
  end
end
