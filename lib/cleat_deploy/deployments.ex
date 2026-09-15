defmodule CleatDeploy.Deployments do
  @moduledoc """
  Deployment history and status transitions.
  """

  import Ecto.Query, warn: false
  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Repo

  @deploy_worker "CleatDeploy.Workers.DeployWorker"
  @pending_job_states ~w(available scheduled retryable)
  @live_job_states ~w(available scheduled executing retryable)
  @cancelled_message "Cancelled by operator (a build already running on the server is not interrupted)"
  @orphaned_message "Deployment orphaned — no deploy worker is running it (auto-recovery)"

  def topic(app_id) when is_integer(app_id), do: "deployments:#{app_id}"

  def subscribe(%App{id: app_id}), do: subscribe(app_id)

  def subscribe(app_id) when is_integer(app_id) do
    Phoenix.PubSub.subscribe(CleatDeploy.PubSub, topic(app_id))
  end

  def create_deployment(%App{} = app, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:triggered_by, "manual")
      |> Map.put(:app_id, app.id)

    %Deployment{}
    |> Deployment.changeset(attrs)
    |> Repo.insert()
    |> broadcast_change()
  end

  def enqueue(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app, attrs)
      when tenant_id == tenant.id do
    enqueue(app, attrs)
  end

  def enqueue(%Scope{}, %App{}, _attrs), do: {:error, :unauthorized}

  def enqueue(%App{} = app, attrs) do
    with {:ok, deployment} <- create_deployment(app, attrs),
         {:ok, job} <-
           %{deployment_id: deployment.id, server_id: app.server_id}
           |> CleatDeploy.Workers.DeployWorker.new()
           |> Oban.insert() do
      {:ok, job}
    end
  end

  def get_deployment!(id), do: Repo.get!(Deployment, id) |> Repo.preload(:app)

  def get_with_log!(id), do: Repo.get!(Deployment, id)

  def get_with_log!(%App{} = app, id) do
    Repo.one!(from d in Deployment, where: d.app_id == ^app.id and d.id == ^id)
  end

  @history_fields [
    :id,
    :git_sha,
    :git_ref,
    :status,
    :triggered_by,
    :started_at,
    :finished_at,
    :inserted_at,
    :updated_at,
    :app_id
  ]

  @history_page_size 10

  def history_page_size, do: @history_page_size

  def for_app(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app)
      when tenant_id == tenant.id do
    list_for_app(app)
  end

  def for_app(%Scope{}, %App{}), do: []

  def for_app(%App{} = app), do: list_for_app(app)

  def page_for_app(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app, page)
      when tenant_id == tenant.id and is_integer(page) do
    list_page_for_app(app, page)
  end

  def page_for_app(%Scope{}, %App{}, _page), do: empty_history_page()

  def page_for_app(%App{} = app, page) when is_integer(page) do
    list_page_for_app(app, page)
  end

  def deploying?(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app)
      when tenant_id == tenant.id do
    deploying?(app)
  end

  def deploying?(%Scope{}, %App{}), do: false

  def deploying?(%App{} = app) do
    Repo.exists?(
      from d in Deployment,
        where: d.app_id == ^app.id and d.status in [:queued, :running]
    )
  end

  def daily_status_counts(%Scope{tenant: tenant}, days) when is_integer(days) and days > 0 do
    since = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

    from(d in Deployment,
      join: a in App,
      on: a.id == d.app_id,
      where: a.tenant_id == ^tenant.id and d.inserted_at >= ^since,
      group_by: [fragment("date(?)", d.inserted_at), d.status],
      select: {fragment("date(?)", d.inserted_at), d.status, count(d.id)}
    )
    |> Repo.all()
  end

  defp list_for_app(%App{} = app) do
    Repo.all(history_query(app))
  end

  defp list_page_for_app(%App{} = app, page) do
    total = Repo.aggregate(from(d in Deployment, where: d.app_id == ^app.id), :count, :id)
    total_pages = history_total_pages(total)
    page = page |> max(1) |> min(total_pages)
    offset = (page - 1) * @history_page_size

    entries =
      Repo.all(
        from d in history_query(app),
          limit: ^@history_page_size,
          offset: ^offset
      )

    %{
      entries: entries,
      page: page,
      page_size: @history_page_size,
      total: total,
      total_pages: total_pages
    }
  end

  defp history_query(%App{} = app) do
    from d in Deployment,
      where: d.app_id == ^app.id,
      order_by: [desc: d.inserted_at, desc: d.id],
      select: struct(d, ^@history_fields)
  end

  defp history_total_pages(0), do: 1

  defp history_total_pages(total) when is_integer(total) and total > 0 do
    div(total + @history_page_size - 1, @history_page_size)
  end

  defp empty_history_page do
    %{
      entries: [],
      page: 1,
      page_size: @history_page_size,
      total: 0,
      total_pages: 1
    }
  end

  @doc """
  Transitions a queued deployment to running when the target server is free.

  Returns:
  - `{:ok, deployment}` when claimed
  - `{:error, :server_busy}` when another deploy is already running on the same
    server, or an older queued deploy is still waiting (FIFO per server)
  - `{:error, :invalid_status}` when the deployment is not queued
  """
  def claim_running(%Deployment{id: id}) do
    case Repo.transaction(fn -> do_claim_running(id) end) do
      {:ok, deployment} ->
        broadcast_change({:ok, deployment})

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

      server_has_blocking_deploy?(deployment) ->
        Repo.rollback(:server_busy)

      true ->
        case deployment
             |> Deployment.changeset(%{
               status: :running,
               started_at: DateTime.utc_now(:second)
             })
             |> Repo.update() do
          {:ok, running} ->
            if concurrent_running_on_server_count(running) > 1 do
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
  def server_has_blocking_deploy?(%Deployment{id: id, app: %App{server_id: server_id}}) do
    Repo.exists?(
      from d in Deployment,
        join: a in App,
        on: a.id == d.app_id,
        where: a.server_id == ^server_id and d.id != ^id,
        where: d.status == :running or (d.status == :queued and d.id < ^id)
    )
  end

  def server_has_blocking_deploy?(%Deployment{id: id}) do
    id
    |> then(&Repo.get!(Deployment, &1))
    |> Repo.preload(:app)
    |> server_has_blocking_deploy?()
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
        |> broadcast_change()

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
        |> broadcast_change()

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
  never starts. A build already running on the server is not interrupted.
  """
  def cancel(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app)
      when tenant_id == tenant.id do
    cancel(app)
  end

  def cancel(%Scope{}, %App{}), do: {:error, :unauthorized}

  def cancel(%App{} = app) do
    case active_deployment(app) do
      nil ->
        {:error, :no_active_deployment}

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

  defp broadcast_change({:ok, %Deployment{} = deployment} = result) do
    Phoenix.PubSub.broadcast(
      CleatDeploy.PubSub,
      topic(deployment.app_id),
      {:deployment_changed, deployment.app_id}
    )

    result
  end

  defp broadcast_change(other), do: other

  defp append_log(existing, message) do
    [existing, message]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @doc """
  Returns deploy duration in seconds, or `nil` when not started or still queued.
  For running deployments, pass `now` (defaults to UTC now) to compute elapsed time.
  """
  def duration(%Deployment{} = deployment, now \\ DateTime.utc_now(:second)) do
    started = deployment.started_at

    cond do
      is_nil(started) ->
        nil

      deployment.status == :queued ->
        nil

      deployment.status == :running ->
        max(DateTime.diff(now, started, :second), 0)

      not is_nil(deployment.finished_at) ->
        max(DateTime.diff(deployment.finished_at, started, :second), 0)

      true ->
        nil
    end
  end

  def format_duration(nil), do: "—"

  def format_duration(seconds) when is_integer(seconds) and seconds >= 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 ->
        "#{hours}h #{minutes}m #{secs}s"

      minutes > 0 ->
        "#{minutes}m #{secs}s"

      true ->
        "#{secs}s"
    end
  end
end
