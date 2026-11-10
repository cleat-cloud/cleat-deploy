defmodule CleatDeploy.Signals.IssuesTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability.{Fingerprint, LogEvent}
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals.Issues
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    %{scope: scope, server: server, app: app}
  end

  test "two events with the same fingerprint become one issue", ctx do
    event(ctx, %{message: "crash pid 1", cursor: "a"})
    event(ctx, %{message: "crash pid 2", cursor: "b"})

    assert [issue] = Issues.list(ctx.scope)
    assert issue.count == 2
    assert issue.status == "unresolved"
    assert issue.app_id == ctx.app.id
    assert issue.fingerprint == Fingerprint.of("crash pid 1")
    assert issue.sample =~ "crash pid"
  end

  test "info lines and host-wide events do not open an issue", ctx do
    event(ctx, %{severity: "info", message: "request completed"})
    event(ctx, %{app_id: nil, severity: "err", message: "disk full"})

    assert Issues.list(ctx.scope) == []
  end

  test "resolve hides the issue until a new event reopens it", ctx do
    release =
      Repo.insert!(%Deployment{app_id: ctx.app.id, git_sha: "abc1234", status: :success})

    first = event(ctx, %{message: "boom", cursor: "a", deployment_id: nil})
    opened = hd(Issues.list(ctx.scope))
    assert {:ok, resolved} = Issues.resolve(ctx.scope, opened.id)
    assert resolved.status == "resolved"
    assert Issues.list(ctx.scope) == []
    assert [%{status: "resolved"}] = Issues.list(ctx.scope, %{status: "resolved"})

    event(ctx, %{message: "boom", cursor: "b", deployment_id: release.id})

    assert [issue] = Issues.list(ctx.scope)
    assert issue.id == opened.id
    assert issue.status == "unresolved"
    assert issue.count == 2
    assert issue.last_deployment_id == release.id
    assert issue.fingerprint == first.fingerprint
  end

  test "ignore does not reopen on the next event", ctx do
    event(ctx, %{message: "timeout", cursor: "a"})
    assert {:ok, ignored} = Issues.ignore(ctx.scope, hd(Issues.list(ctx.scope)).id)
    assert ignored.status == "ignored"

    event(ctx, %{message: "timeout", cursor: "b"})

    assert Issues.list(ctx.scope) == []
    assert [issue] = Issues.list(ctx.scope, %{status: "ignored"})
    assert issue.count == 2
    assert issue.status == "ignored"

    assert {:ok, reopened} = Issues.reopen(ctx.scope, issue.id)
    assert reopened.status == "unresolved"
    assert [%{id: id}] = Issues.list(ctx.scope)
    assert id == issue.id
  end

  test "list filters by app and does not leak another tenant", ctx do
    other_app = TenancyFixtures.app_fixture(ctx.scope, ctx.server)
    event(ctx, %{message: "alpha", cursor: "a"})
    event(ctx, %{message: "beta", cursor: "b", app_id: other_app.id})

    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)
    other_app_b = TenancyFixtures.app_fixture(other, other_server)
    event(%{scope: other, server: other_server, app: other_app_b}, %{message: "secret"})

    slugs = Issues.list(ctx.scope) |> Enum.map(& &1.app.slug) |> Enum.sort()
    assert ctx.app.slug in slugs
    assert other_app.slug in slugs
    refute other_app_b.slug in slugs

    assert [%{app_id: app_id}] = Issues.list(ctx.scope, %{app_id: ctx.app.id})
    assert app_id == ctx.app.id
  end

  test "a member cannot resolve, ignore or reopen", ctx do
    event(ctx, %{message: "boom"})
    issue = hd(Issues.list(ctx.scope))
    member = %{ctx.scope | role: "member"}

    assert {:error, :unauthorized} = Issues.resolve(member, issue.id)
    assert {:error, :unauthorized} = Issues.ignore(member, issue.id)
    assert {:error, :unauthorized} = Issues.reopen(member, issue.id)
  end

  defp event(ctx, attrs) do
    message = Map.get(attrs, :message, "hello")

    defaults = %{
      tenant_id: ctx.scope.tenant.id,
      app_id: ctx.app.id,
      server_id: ctx.server.id,
      source: "app",
      unit: "phx-app.service",
      cursor: "cursor-#{System.unique_integer([:positive])}",
      severity: "err",
      message: message,
      fingerprint: Fingerprint.of(message),
      occurred_at: DateTime.utc_now(:second)
    }

    event = Repo.insert!(struct!(LogEvent, Map.merge(defaults, attrs)))
    Issues.record(event)
    event
  end
end
