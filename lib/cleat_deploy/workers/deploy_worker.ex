defmodule CleatDeploy.Workers.DeployWorker do
  @moduledoc false
  use Oban.Worker, queue: :deploys, max_attempts: 3

  alias CleatDeploy.Deployments

  # Wait between attempts when this app is already deploying, or the host is at
  # its concurrent-build cap.
  @server_busy_snooze_seconds 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    deployment_id = Map.get(args, "deployment_id") || Map.get(args, :deployment_id)
    deployment = Deployments.get_deployment!(deployment_id)

    case Deployments.claim_running(deployment) do
      {:ok, running} ->
        run_deploy(running)

      {:error, :server_busy} ->
        {:snooze, @server_busy_snooze_seconds}

      {:error, :invalid_status} ->
        # Already finished or cancelled by another transition.
        :ok

      {:error, reason} ->
        _ = Deployments.mark_failed(deployment, format_error(reason))
        {:error, reason}
    end
  end

  defp run_deploy(running) do
    with {:ok, message} <- runner().deploy(running),
         {:ok, _success} <- Deployments.mark_success(running, message) do
      :ok
    else
      {:error, reason} -> fail(running, reason)
    end
  rescue
    error -> fail(running, Exception.message(error))
  catch
    kind, reason -> fail(running, "#{kind}: #{inspect(reason)}")
  end

  # A crashed worker must never leave the deployment in `:running` — that row
  # blocks every deploy of every app on the same server.
  defp fail(running, reason) do
    deployment = Deployments.get_deployment!(running.id)
    _ = Deployments.mark_failed(deployment, format_error(reason))
    {:error, reason}
  end

  defp runner do
    Application.get_env(:cleat_deploy, :deploy_runner, CleatDeploy.Deploy.FakeRunner)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
