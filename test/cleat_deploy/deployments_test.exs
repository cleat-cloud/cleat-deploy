defmodule CleatDeploy.DeploymentsTest do
  use CleatDeploy.DataCase

  import Mox

  alias CleatDeploy.{Apps, Deployments}
  alias CleatDeploy.Deploy.RunnerMock
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Trip Planner",
        slug: "trip-planner",
        github_repo: "puppe1990/trip-planner-ia-phx",
        host: "trip.gestaobem.com",
        server_id: server.id
      })

    %{scope: scope, app: app}
  end

  describe "create_deployment/2" do
    test "starts in queued status", %{app: app} do
      assert {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "abc123"})
      assert deployment.status == :queued
    end
  end

  describe "enqueue/3" do
    test "rejects cross-tenant app", %{app: app} do
      other_scope = TenancyFixtures.scope_fixture()
      assert {:error, :unauthorized} = Deployments.enqueue(other_scope, app, %{git_sha: "abc"})
    end

    test "queues for scoped app", %{scope: scope, app: app} do
      assert {:ok, _job} = Deployments.enqueue(scope, app, %{git_sha: "abc123"})
    end
  end

  describe "status transitions" do
    setup %{app: app} do
      {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "abc123"})
      %{deployment: deployment}
    end

    test "mark_running/1 from queued", %{deployment: deployment} do
      assert {:ok, running} = Deployments.mark_running(deployment)
      assert running.status == :running
    end

    test "claim_running/1 rejects when another deploy is running on the same server", %{
      scope: scope,
      app: app,
      deployment: deployment
    } do
      {:ok, first} = Deployments.mark_running(deployment)
      assert first.status == :running

      {:ok, second} = Deployments.create_deployment(app, %{git_sha: "def456"})
      assert {:error, :app_fifo} = Deployments.claim_running(second)

      other_server = TenancyFixtures.server_fixture(scope)

      {:ok, other_app, _} =
        Apps.create_app(scope, %{
          name: "Other App",
          slug: "other-app",
          github_repo: "puppe1990/other-app",
          host: "other.gestaobem.com",
          server_id: other_server.id
        })

      {:ok, other_deploy} = Deployments.create_deployment(other_app, %{git_sha: "zzz"})
      assert {:ok, other_running} = Deployments.claim_running(other_deploy)
      assert other_running.status == :running
    end

    test "claim_running/1 runs two different apps on the same server at once", %{
      scope: scope,
      app: app,
      deployment: first
    } do
      {:ok, running} = Deployments.claim_running(first)
      assert running.status == :running

      {:ok, other_app, _} =
        Apps.create_app(scope, %{
          name: "Second App",
          slug: "second-app",
          github_repo: "puppe1990/second-app",
          host: "second.gestaobem.com",
          server_id: app.server_id
        })

      {:ok, second} = Deployments.create_deployment(other_app, %{git_sha: "parallel"})
      assert {:ok, second_running} = Deployments.claim_running(second)
      assert second_running.status == :running
    end

    test "claim_running/1 caps concurrent deploys on one server at two", %{
      scope: scope,
      app: app,
      deployment: first
    } do
      {:ok, _} = Deployments.claim_running(first)

      {:ok, second_app, _} =
        Apps.create_app(scope, %{
          name: "Second App",
          slug: "second-app",
          github_repo: "puppe1990/second-app",
          host: "second.gestaobem.com",
          server_id: app.server_id
        })

      {:ok, third_app, _} =
        Apps.create_app(scope, %{
          name: "Third App",
          slug: "third-app",
          github_repo: "puppe1990/third-app",
          host: "third.gestaobem.com",
          server_id: app.server_id
        })

      {:ok, second} = Deployments.create_deployment(second_app, %{git_sha: "two"})
      {:ok, third} = Deployments.create_deployment(third_app, %{git_sha: "three"})

      assert {:ok, _} = Deployments.claim_running(second)
      assert {:error, :server_busy} = Deployments.claim_running(third)
    end

    test "claim_running/1 enforces FIFO for queued deploys of the same app", %{
      app: app,
      deployment: older
    } do
      {:ok, newer} = Deployments.create_deployment(app, %{git_sha: "newer"})

      assert {:error, :app_fifo} = Deployments.claim_running(newer)
      assert {:ok, running_older} = Deployments.claim_running(older)
      assert running_older.status == :running

      {:ok, _} = Deployments.mark_success(running_older, "done")
      assert {:ok, running_newer} = Deployments.claim_running(newer)
      assert running_newer.status == :running
    end

    test "wait_reason/1 is :app_fifo when an older deploy of the same app is ahead", %{
      app: app,
      deployment: older
    } do
      {:ok, newer} = Deployments.create_deployment(app, %{git_sha: "newer"})

      assert Deployments.wait_reason(newer) == :app_fifo
      assert Deployments.wait_reason(older) == nil
      assert Deployments.wait_reason_message(newer) =~ "earlier deploy"
    end

    test "wait_reason/1 is :server_cap when the host is already at two running builds", %{
      scope: scope,
      app: app,
      deployment: first
    } do
      {:ok, _} = Deployments.claim_running(first)

      {:ok, second_app, _} =
        Apps.create_app(scope, %{
          name: "Second App",
          slug: "second-app",
          github_repo: "puppe1990/second-app",
          host: "second.gestaobem.com",
          server_id: app.server_id
        })

      {:ok, third_app, _} =
        Apps.create_app(scope, %{
          name: "Third App",
          slug: "third-app",
          github_repo: "puppe1990/third-app",
          host: "third.gestaobem.com",
          server_id: app.server_id
        })

      {:ok, second} = Deployments.create_deployment(second_app, %{git_sha: "two"})
      {:ok, _} = Deployments.claim_running(second)

      {:ok, third} = Deployments.create_deployment(third_app, %{git_sha: "three"})
      running = Deployments.get_deployment!(first.id)

      assert Deployments.wait_reason(third) == :server_cap
      assert Deployments.wait_reason_message(third) =~ "2-build cap"
      assert Deployments.wait_reason(running) == nil
    end

    test "mark_success/1 sets finished_at", %{deployment: deployment} do
      {:ok, running} = Deployments.mark_running(deployment)
      assert {:ok, success} = Deployments.mark_success(running, "deploy ok")
      assert success.status == :success
    end

    test "mark_failed/1 appends log", %{deployment: deployment} do
      {:ok, running} = Deployments.mark_running(deployment)
      assert {:ok, failed} = Deployments.mark_failed(running, "boom")
      assert failed.log =~ "boom"
    end
  end

  describe "cancel/2" do
    test "rejects a cross-tenant app", %{app: app} do
      other_scope = TenancyFixtures.scope_fixture()
      assert {:error, :unauthorized} = Deployments.cancel(other_scope, app)
    end

    test "fails the active deployment and cancels its pending job", %{scope: scope, app: app} do
      {:ok, job} = Deployments.enqueue(scope, app, %{git_sha: "cancel-me"})
      [deployment] = Deployments.for_app(scope, app)

      assert {:ok, cancelled} = Deployments.cancel(scope, app)
      assert cancelled.id == deployment.id
      assert cancelled.status == :failed
      assert cancelled.log =~ "Cancelled by operator"
      assert cancelled.finished_at
      refute Deployments.deploying?(scope, app)

      assert CleatDeploy.Repo.get!(Oban.Job, job.id).state == "cancelled"
    end

    test "cancels the oldest deployment when several are queued", %{scope: scope, app: app} do
      {:ok, _} = Deployments.enqueue(scope, app, %{git_sha: "first"})
      {:ok, _} = Deployments.enqueue(scope, app, %{git_sha: "second"})

      [oldest | _] = Deployments.for_app(scope, app) |> Enum.reverse()

      assert {:ok, cancelled} = Deployments.cancel(scope, app)
      assert cancelled.id == oldest.id
      assert Deployments.deploying?(scope, app)
    end

    test "reports when nothing is active", %{scope: scope, app: app} do
      assert {:error, :no_active_deployment} = Deployments.cancel(scope, app)

      {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "done"})
      {:ok, running} = Deployments.mark_running(deployment)
      {:ok, _success} = Deployments.mark_success(running, "deploy ok")

      assert {:error, :no_active_deployment} = Deployments.cancel(scope, app)
      assert Deployments.get_deployment!(deployment.id).status == :success
    end

    test "interrupts a running build and unblocks the next enqueue", %{scope: scope, app: app} do
      {:ok, job} = Deployments.enqueue(scope, app, %{git_sha: "abcdef1running"})
      [deployment] = Deployments.for_app(scope, app)
      {:ok, _running} = Deployments.mark_running(deployment)

      job
      |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.utc_now())
      |> CleatDeploy.Repo.update!()

      parent = self()

      stub(RunnerMock, :interrupt, fn interrupted_app, interrupted ->
        send(parent, {:interrupted, interrupted_app.id, interrupted.id})
        :ok
      end)

      assert {:ok, cancelled} = Deployments.cancel(scope, app)
      assert cancelled.status == :failed
      assert_received {:interrupted, app_id, deployment_id}
      assert app_id == app.id
      assert deployment_id == deployment.id
      refute Deployments.deploying?(scope, app)

      {:ok, _next_job} = Deployments.enqueue(scope, app, %{git_sha: "next-after-cancel"})
      next = hd(Deployments.for_app(scope, app))
      assert {:ok, claimed} = Deployments.claim_running(next)
      assert claimed.status == :running
    end
  end

  describe "oban cron" do
    test "recovers orphaned deploys every minute" do
      plugins = Application.get_env(:cleat_deploy, Oban)[:plugins]
      {_mod, opts} = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      assert {"* * * * *", CleatDeploy.Workers.AutoDeployHealthWorker} in opts[:crontab]
    end
  end

  describe "recover_orphaned_running/1" do
    test "fails a running deployment whose worker job is gone", %{app: app} do
      {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "zombie"})
      {:ok, _running} = Deployments.mark_running(deployment)

      assert [recovered] = Deployments.recover_orphaned_running(DateTime.utc_now(:second))
      assert recovered.id == deployment.id
      assert recovered.status == :failed
      assert recovered.log =~ "orphaned"
    end

    test "keeps a running deployment that still has a queued job", %{scope: scope, app: app} do
      {:ok, _job} = Deployments.enqueue(scope, app, %{git_sha: "alive"})
      [deployment] = Deployments.for_app(scope, app)
      {:ok, _running} = Deployments.mark_running(deployment)

      assert Deployments.recover_orphaned_running(DateTime.utc_now(:second)) == []
      assert Deployments.get_deployment!(deployment.id).status == :running
    end

    test "fails a deployment whose job was attempted before this boot", %{scope: scope, app: app} do
      {:ok, job} = Deployments.enqueue(scope, app, %{git_sha: "dead-worker"})
      [deployment] = Deployments.for_app(scope, app)
      {:ok, _running} = Deployments.mark_running(deployment)

      attempted_at = DateTime.add(DateTime.utc_now(), -600, :second)

      job
      |> Ecto.Changeset.change(state: "executing", attempted_at: attempted_at)
      |> CleatDeploy.Repo.update!()

      assert [recovered] = Deployments.recover_orphaned_running(DateTime.utc_now(:second))
      assert recovered.id == deployment.id
    end

    test "keeps a deployment whose job is executing since this boot", %{scope: scope, app: app} do
      {:ok, job} = Deployments.enqueue(scope, app, %{git_sha: "live-worker"})
      [deployment] = Deployments.for_app(scope, app)
      {:ok, _running} = Deployments.mark_running(deployment)

      booted_at = DateTime.add(DateTime.utc_now(:second), -60, :second)

      job
      |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.utc_now())
      |> CleatDeploy.Repo.update!()

      assert Deployments.recover_orphaned_running(booted_at) == []
      assert Deployments.get_deployment!(deployment.id).status == :running
    end

    test "re-enqueues a queued deployment whose Oban job is gone", %{app: app} do
      {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "lost-job"})

      assert [requeued] = Deployments.recover_orphaned_queued()
      assert requeued.id == deployment.id
      assert requeued.status == :queued

      jobs =
        CleatDeploy.Repo.all(
          from j in Oban.Job,
            where: j.worker == "CleatDeploy.Workers.DeployWorker"
        )

      assert Enum.any?(jobs, fn job -> job.args["deployment_id"] == deployment.id end)
    end

    test "leaves a queued deployment that still has an Oban job", %{scope: scope, app: app} do
      {:ok, _job} = Deployments.enqueue(scope, app, %{git_sha: "still-queued"})

      assert Deployments.recover_orphaned_queued() == []
    end
  end

  describe "for_app/2" do
    test "orders by newest first", %{scope: scope, app: app} do
      {:ok, older} = Deployments.create_deployment(app, %{git_sha: "old"})
      {:ok, newer} = Deployments.create_deployment(app, %{git_sha: "new"})

      ids = Enum.map(Deployments.for_app(scope, app), & &1.id)
      assert ids == [newer.id, older.id]
    end

    test "omits log bodies from the history list", %{scope: scope, app: app} do
      {:ok, queued} = Deployments.create_deployment(app, %{git_sha: "sha-log"})
      {:ok, running} = Deployments.mark_running(queued)
      {:ok, done} = Deployments.mark_success(running, String.duplicate("build ok\n", 40))

      [listed] = Deployments.for_app(scope, app)
      assert listed.id == done.id
      assert listed.git_sha == "sha-log"
      assert listed.status == :success
      assert listed.log in [nil, ""]

      loaded = Deployments.get_with_log!(app, done.id)
      assert loaded.log =~ "build ok"
    end
  end

  describe "page_for_app/3" do
    test "returns 10 newest deployments on the first page", %{scope: scope, app: app} do
      deployments =
        for i <- 1..11 do
          {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "sha-#{i}"})
          deployment
        end

      oldest = List.first(deployments)
      newest = List.last(deployments)
      page = Deployments.page_for_app(scope, app, 1)

      assert page.page == 1
      assert page.page_size == 10
      assert page.total == 11
      assert page.total_pages == 2

      assert Enum.map(page.entries, & &1.id) ==
               deployments |> Enum.reverse() |> Enum.take(10) |> Enum.map(& &1.id)

      assert newest.id in Enum.map(page.entries, & &1.id)
      refute oldest.id in Enum.map(page.entries, & &1.id)
    end

    test "returns the remaining deployments on page 2", %{scope: scope, app: app} do
      deployments =
        for i <- 1..11 do
          {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "sha-#{i}"})
          deployment
        end

      oldest = List.first(deployments)
      newest = List.last(deployments)
      page = Deployments.page_for_app(scope, app, 2)

      assert page.page == 2
      assert Enum.map(page.entries, & &1.id) == [oldest.id]
      refute newest.id in Enum.map(page.entries, & &1.id)
    end

    test "clamps out-of-range pages to the last page", %{scope: scope, app: app} do
      for i <- 1..11 do
        {:ok, _} = Deployments.create_deployment(app, %{git_sha: "sha-#{i}"})
      end

      page = Deployments.page_for_app(scope, app, 99)
      assert page.page == 2
      assert length(page.entries) == 1
    end

    test "returns an empty page for a cross-tenant scope", %{app: app} do
      {:ok, _} = Deployments.create_deployment(app, %{git_sha: "sha-x"})
      other_scope = TenancyFixtures.scope_fixture()
      page = Deployments.page_for_app(other_scope, app, 1)

      assert page.entries == []
      assert page.total == 0
      assert page.page == 1
    end
  end

  describe "deploying?/2" do
    test "is true only while a deploy is queued or running", %{scope: scope, app: app} do
      refute Deployments.deploying?(scope, app)

      {:ok, queued} = Deployments.create_deployment(app, %{git_sha: "sha-active"})
      assert Deployments.deploying?(scope, app)

      {:ok, running} = Deployments.mark_running(queued)
      assert Deployments.deploying?(scope, app)

      {:ok, _done} = Deployments.mark_success(running, "ok")
      refute Deployments.deploying?(scope, app)
    end
  end

  describe "duration/1" do
    setup %{app: app} do
      {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "abc123"})
      %{deployment: deployment}
    end

    test "returns nil for queued deployment", %{deployment: deployment} do
      assert Deployments.duration(deployment) == nil
      assert Deployments.format_duration(nil) == "—"
    end

    test "computes elapsed seconds for running deployment", %{deployment: deployment} do
      started_at = ~U[2026-06-29 10:00:00Z]
      now = ~U[2026-06-29 10:02:15Z]

      {:ok, running} =
        deployment
        |> Ecto.Changeset.change(%{status: :running, started_at: started_at})
        |> CleatDeploy.Repo.update()

      assert Deployments.duration(running, now) == 135
      assert Deployments.format_duration(135) == "2m 15s"
    end

    test "computes finished duration", %{deployment: deployment} do
      started_at = ~U[2026-06-29 10:00:00Z]
      finished_at = ~U[2026-06-29 10:00:45Z]

      {:ok, finished} =
        deployment
        |> Ecto.Changeset.change(%{
          status: :success,
          started_at: started_at,
          finished_at: finished_at
        })
        |> CleatDeploy.Repo.update()

      assert Deployments.duration(finished) == 45
      assert Deployments.format_duration(45) == "45s"
    end
  end
end
