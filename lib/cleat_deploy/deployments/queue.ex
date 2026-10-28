defmodule CleatDeploy.Deployments.Queue do
  @moduledoc """
  Creating deployments, enqueuing their Oban jobs and claiming a build slot.
  """

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.{Deployment, Notifications, Policy}
  alias CleatDeploy.Repo

  @doc false
  def create_deployment(%App{} = app, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:triggered_by, "manual")
      |> Map.put(:app_id, app.id)

    %Deployment{}
    |> Deployment.changeset(attrs)
    |> Repo.insert()
    |> Notifications.broadcast_change()
  end

  def enqueue(%Scope{tenant: tenant} = scope, %App{tenant_id: tenant_id} = app, attrs)
      when tenant_id == tenant.id do
    with :ok <- Policy.authorize_write(scope), do: enqueue(app, attrs)
  end

  def enqueue(%Scope{}, %App{}, _attrs), do: {:error, :unauthorized}

  def enqueue(%App{} = app, attrs) do
    with {:ok, deployment} <- create_deployment(app, attrs),
         {:ok, job} <- insert_deploy_job(app, deployment) do
      {:ok, job}
    end
  end

  @doc """
  Like `enqueue/3` but also returns the created deployment, so API callers can
  report its id and status.
  """
  def enqueue_deployment(%Scope{tenant: tenant} = scope, %App{tenant_id: tenant_id} = app, attrs)
      when tenant_id == tenant.id do
    with :ok <- Policy.authorize_write(scope), do: enqueue_deployment(app, attrs)
  end

  def enqueue_deployment(%Scope{}, %App{}, _attrs), do: {:error, :unauthorized}

  def enqueue_deployment(%App{} = app, attrs) do
    with {:ok, deployment} <- create_deployment(app, attrs),
         {:ok, job} <- insert_deploy_job(app, deployment) do
      {:ok, deployment, job}
    end
  end

  @doc false
  def insert_deploy_job(%App{} = app, %Deployment{} = deployment) do
    %{deployment_id: deployment.id, server_id: app.server_id}
    |> CleatDeploy.Workers.DeployWorker.new()
    |> Oban.insert()
  end

  @doc """
  Enqueues a git-less "drop" deploy from an uploaded artifact.
  """
  def enqueue_drop(%Scope{tenant: tenant} = scope, %App{tenant_id: tenant_id} = app, attrs)
      when tenant_id == tenant.id do
    with :ok <- Policy.authorize_write(scope), do: enqueue_drop(app, attrs)
  end

  def enqueue_drop(%Scope{}, %App{}, _attrs), do: {:error, :unauthorized}

  def enqueue_drop(%App{} = app, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:triggered_by, "drop")
      |> Map.put_new(:git_sha, "drop")
      |> Map.put(:app_id, app.id)

    with {:ok, deployment} <- create_drop_deployment(attrs),
         {:ok, job} <- insert_deploy_job(app, deployment) do
      {:ok, deployment, job}
    end
  end

  defp create_drop_deployment(attrs) do
    %Deployment{}
    |> Deployment.drop_changeset(attrs)
    |> Repo.insert()
    |> Notifications.broadcast_change()
  end

  # One mix/npm build on a CX33 is the ceiling: a single Phoenix compile already
  # hits ~330% (Hetzner 100% = 1 vCPU) and starves Caddy on :443. Compile steps
  # are also wrapped in CPUQuota=150%; this cap stops two of those overlapping.
  @max_running_per_server 1

  def max_running_per_server, do: @max_running_per_server

  @doc """
  Transitions a queued deployment to running when a slot is free.

  Returns:
  - `{:ok, deployment}` when claimed
  - `{:error, :app_fifo}` when this app already has a running or older queued deploy
  - `{:error, :server_busy}` when the server is already at
    `#{@max_running_per_server}` concurrent deploys
  - `{:error, :invalid_status}` when the deployment is not queued
  """
  def claim_running(%Deployment{id: id}) do
    case CleatDeploy.Repo.BusyRetry.call(fn ->
           Repo.transaction(fn -> do_claim_running(id) end)
         end) do
      {:ok, deployment} ->
        Notifications.broadcast_change({:ok, deployment})

      {:error, :app_fifo} ->
        {:error, :app_fifo}

      {:error, :server_busy} ->
        {:error, :server_busy}

      {:error, :invalid_status} ->
        {:error, :invalid_status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def mark_running(%Deployment{} = deployment) do
    claim_running(deployment)
  end

  defp do_claim_running(id) do
    deployment =
      Deployment
      |> Repo.get!(id)
      |> Repo.preload(:app)

    cond do
      deployment.status != :queued ->
        Repo.rollback(:invalid_status)

      app_has_blocking_deploy?(deployment) ->
        Repo.rollback(:app_fifo)

      concurrent_running_on_server_count(deployment) >= @max_running_per_server ->
        Repo.rollback(:server_busy)

      true ->
        case deployment
             |> Deployment.changeset(%{
               status: :running,
               started_at: DateTime.utc_now(:second)
             })
             |> Repo.update() do
          {:ok, running} ->
            if concurrent_running_on_server_count(running) > @max_running_per_server do
              _ =
                running
                |> Deployment.changeset(%{status: :queued, started_at: nil})
                |> Repo.update()

              Repo.rollback(:server_busy)
            else
              running
            end

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  @doc false
  def app_has_blocking_deploy?(%Deployment{id: id, app_id: app_id}) do
    Repo.exists?(
      from d in Deployment,
        where: d.app_id == ^app_id and d.id != ^id,
        where: d.status == :running or (d.status == :queued and d.id < ^id)
    )
  end

  @doc """
  Why a queued deploy has not claimed a slot yet.

  `:app_fifo` — this app already has a running or older queued deploy.
  `:server_cap` — the host is at `max_running_per_server/0` concurrent builds.
  """
  def wait_reason(%Deployment{status: :queued} = deployment) do
    cond do
      app_has_blocking_deploy?(deployment) -> :app_fifo
      concurrent_running_on_server_count(deployment) >= @max_running_per_server -> :server_cap
      true -> nil
    end
  end

  def wait_reason(%Deployment{}), do: nil

  def wait_reason_message(deployment) do
    case wait_reason(deployment) do
      :app_fifo ->
        "Waiting for this app's earlier deploy"

      :server_cap ->
        "Waiting: this server is at the #{@max_running_per_server}-build cap"

      nil ->
        nil
    end
  end

  defp concurrent_running_on_server_count(%Deployment{app_id: app_id}) do
    server_id =
      from(a in App, where: a.id == ^app_id, select: a.server_id)
      |> Repo.one!()

    Repo.aggregate(
      from(d in Deployment,
        join: a in App,
        on: a.id == d.app_id,
        where: a.server_id == ^server_id and d.status == :running
      ),
      :count,
      :id
    )
  end
end
