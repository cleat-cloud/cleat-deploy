defmodule CleatDeploy.Deployments.Transitions do
  @moduledoc """
  Terminal statuses, cancellation and orphan recovery for deployments.
  """

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.{Deployment, Notifications, Policy, Queue}
  alias CleatDeploy.Repo

  @pending_job_states ~w(available scheduled retryable)
  @live_job_states ~w(available scheduled executing retryable)
  @deploy_worker "CleatDeploy.Workers.DeployWorker"
  @cancelled_message "Cancelled by operator"
  @orphaned_message "Deployment orphaned — no deploy worker is running it (auto-recovery)"

  def mark_success(%Deployment{id: id}, message) when is_binary(message) do
    case Repo.get(Deployment, id) do
      %Deployment{status: :running} = deployment ->
        deployment
        |> Deployment.changeset(%{
          status: :success,
          finished_at: DateTime.utc_now(:second),
          log: append_log(deployment.log, message)
        })
        |> Repo.update()
        |> Notifications.broadcast_change()

      %Deployment{} ->
        {:error, :invalid_status}

      nil ->
        {:error, :invalid_status}
    end
  end

  def mark_failed(%Deployment{id: id}, message) when is_binary(message) do
    case Repo.get(Deployment, id) do
      %Deployment{status: status} = deployment when status in [:queued, :running] ->
        deployment
        |> Deployment.changeset(%{
          status: :failed,
          finished_at: DateTime.utc_now(:second),
          log: append_log(deployment.log, message)
        })
        |> Repo.update()
        |> Notifications.broadcast_change()

      %Deployment{} ->
        {:error, :invalid_status}

      nil ->
        {:error, :invalid_status}
    end
  end

  @doc """
  Cancels the active deployment of an app — the running one, or the oldest
  queued one when nothing is running yet.

  The deployment is marked failed and its pending Oban job is cancelled so it
  never starts. A build already running on the server is interrupted via the
  deploy runner.
  """
  def cancel(%Scope{tenant: tenant} = scope, %App{tenant_id: tenant_id} = app)
      when tenant_id == tenant.id do
    with :ok <- Policy.authorize_write(scope), do: cancel(app)
  end

  def cancel(%Scope{}, %App{}), do: {:error, :unauthorized}

  def cancel(%App{} = app) do
    case active_deployment(app) do
      nil ->
        {:error, :no_active_deployment}

      %Deployment{status: :running} = deployment ->
        _ = interrupt_running(app, deployment)
        cancel_pending_jobs(deployment.id)
        mark_failed(deployment, @cancelled_message)

      %Deployment{} = deployment ->
        cancel_pending_jobs(deployment.id)
        mark_failed(deployment, @cancelled_message)
    end
  end

  @doc """
  Fails running deployments that nothing will ever finish.

  A deployment is orphaned when its Oban job is gone, or when the job was last
  attempted before this node booted — the worker died with a previous boot and
  the deployment would otherwise block every deploy on its server forever.
  """
  def recover_orphaned_running(booted_at) do
    jobs = deploy_jobs(@live_job_states)

    from(d in Deployment, where: d.status == :running)
    |> Repo.all()
    |> Enum.filter(&orphaned?(&1, jobs, booted_at))
    |> Enum.flat_map(fn deployment ->
      case mark_failed(deployment, @orphaned_message) do
        {:ok, failed} -> [failed]
        {:error, _reason} -> []
      end
    end)
  end

  @doc """
  Re-inserts an Oban job for queued deployments whose worker job is gone.

  A `queued` row with no live job never starts: FIFO per app waits on it, and
  cancel is the only manual way out. The health worker puts it back on the
  queue so the stager can pick it up after a SQLITE_BUSY crash.
  """
  def recover_orphaned_queued do
    jobs = deploy_jobs(@live_job_states)

    from(d in Deployment, where: d.status == :queued, preload: [:app])
    |> Repo.all()
    |> Enum.filter(
      &(Enum.find(jobs, fn job -> deploy_job_deployment_id(job) == &1.id end) == nil)
    )
    |> Enum.flat_map(fn deployment ->
      case Queue.insert_deploy_job(deployment.app, deployment) do
        {:ok, _job} -> [deployment]
        {:error, _reason} -> []
      end
    end)
  end

  defp interrupt_running(app, deployment) do
    runner = Application.get_env(:cleat_deploy, :deploy_runner, CleatDeploy.Deploy.FakeRunner)
    runner.interrupt(app, deployment)
  end

  defp active_deployment(%App{} = app) do
    Repo.one(
      from d in Deployment,
        where: d.app_id == ^app.id and d.status in [:running, :queued],
        order_by: [asc: d.id],
        limit: 1
    )
  end

  defp cancel_pending_jobs(deployment_id) do
    @pending_job_states
    |> deploy_jobs()
    |> Enum.filter(&(deploy_job_deployment_id(&1) == deployment_id))
    |> Enum.each(&Oban.cancel_job(&1.id))
  end

  defp deploy_jobs(states) do
    Repo.all(
      from j in Oban.Job,
        where: j.worker == ^@deploy_worker and j.state in ^states
    )
  end

  defp orphaned?(%Deployment{} = deployment, jobs, booted_at) do
    case Enum.find(jobs, &(deploy_job_deployment_id(&1) == deployment.id)) do
      nil ->
        true

      %Oban.Job{state: "executing", attempted_at: %DateTime{} = attempted_at} ->
        DateTime.compare(attempted_at, booted_at) == :lt

      %Oban.Job{} ->
        false
    end
  end

  defp deploy_job_deployment_id(%Oban.Job{args: args}), do: Map.get(args, "deployment_id")

  defp append_log(existing, message) do
    [existing, message]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end
end
