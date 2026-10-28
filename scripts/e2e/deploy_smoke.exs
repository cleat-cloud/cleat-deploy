# Real deploy smoke test against a disposable server.
#
# Run through scripts/e2e/run.sh (it provisions and destroys the server).
# The harness drives the same code path as a production SSH deploy: it creates
# a tenant, registers the disposable server and a static reference app, then
# runs SshRunner for an initial deploy, an update and two failure refs, checking
# that HTTP keeps serving the last good release when a deploy fails.
#
# It never prints the SSH key, the panel database or raw deploy logs; the
# deploy log can echo the clone URL and must not reach the CI output.

defmodule CleatE2E.DeploySmoke do
  alias CleatDeploy.{Accounts, Apps, Deployments, Repo, Servers, Vault}
  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Deploy.SshRunner

  @runtime "static"

  def run do
    summary_path = System.get_env("E2E_SUMMARY_PATH", "e2e-summary.json")

    env = %{
      ip: env!("E2E_SERVER_IP"),
      repo: env!("E2E_REPO"),
      key_path: env!("E2E_SSH_PRIVATE_KEY_PATH"),
      ref: System.get_env("E2E_REF", "main"),
      update_ref: System.get_env("E2E_UPDATE_REF", System.get_env("E2E_REF", "main")),
      fail_build_ref: System.get_env("E2E_FAIL_BUILD_REF", "cleat-e2e-missing-ref"),
      fail_release_ref: System.get_env("E2E_FAIL_RELEASE_REF", ""),
      http_timeout: String.to_integer(System.get_env("E2E_HTTP_TIMEOUT_S", "300"))
    }

    db_path = start_infra()

    try do
      steps = execute(env)
      write_summary(summary_path, env, steps, true)
      IO.puts("\nE2E OK — #{length(steps)} step(s) passed")
    rescue
      error ->
        write_summary(summary_path, env, [], false, Exception.message(error))
        IO.puts(:stderr, "\nE2E FAILED: #{Exception.message(error)}")
        System.halt(1)
    after
      File.rm(db_path)
      File.rm(db_path <> "-shm")
      File.rm(db_path <> "-wal")
    end
  end

  defp execute(env) do
    scope = create_scope()
    server = create_server(scope, env)
    app = create_app(scope, server, env)

    steps = [
      deploy_step(env, app, "deploy inicial (#{env.ref})", env.ref, :success, env.http_timeout),
      deploy_step(
        env,
        app,
        "atualização (#{env.update_ref})",
        env.update_ref,
        :success,
        env.http_timeout
      ),
      deploy_step(
        env,
        app,
        "falha de build (#{env.fail_build_ref})",
        env.fail_build_ref,
        :failure,
        env.http_timeout
      )
    ]

    steps =
      if env.fail_release_ref == "" do
        IO.puts("==> skipping release-failure check (E2E_FAIL_RELEASE_REF is empty)")
        steps
      else
        steps ++
          [
            deploy_step(
              env,
              app,
              "falha de release (#{env.fail_release_ref})",
              env.fail_release_ref,
              :failure,
              env.http_timeout
            )
          ]
      end

    steps
  end

  defp deploy_step(env, app, label, ref, expected, http_timeout) do
    IO.puts("\n==> #{label}")
    started = System.monotonic_time(:second)
    {status, deployment_id} = deploy(app, ref)
    elapsed = System.monotonic_time(:second) - started

    if status != expected do
      raise "#{label}: expected #{expected} deploy, got #{status} (deployment ##{deployment_id})"
    end

    body = wait_http!(env, http_timeout)
    assert_body!(env, label, body)

    IO.puts("    deploy ##{deployment_id} #{status} in #{elapsed}s; HTTP still serving")

    %{name: label, ref: ref, status: status, deployment_id: deployment_id, seconds: elapsed}
  end

  defp deploy(app, ref) do
    {:ok, deployment} =
      Deployments.create_deployment(app, %{git_sha: "e2e", git_ref: ref})

    {:ok, running} = Deployments.mark_running(deployment)

    result =
      try do
        SshRunner.deploy(running)
      rescue
        error -> {:error, Exception.message(error)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end

    case result do
      {:ok, message} ->
        case Deployments.mark_success(running, message) do
          {:ok, _} -> {:success, deployment.id}
          {:error, reason} -> {:error, reason, deployment.id} |> fail_deploy()
        end

      {:error, reason} ->
        failure = describe(reason)
        _ = Deployments.mark_failed(running, failure)
        IO.puts("    deploy ##{deployment.id} failed: #{String.slice(failure, 0, 300)}")
        {:failure, deployment.id}
    end
  end

  defp fail_deploy({:error, reason, id}) do
    raise "could not mark deployment ##{id} as success: #{describe(reason)}"
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp wait_http!(env, timeout_s) do
    deadline = System.monotonic_time(:second) + timeout_s
    do_wait_http(env, deadline)
  end

  defp do_wait_http(env, deadline) do
    case http_get(env.ip) do
      {:ok, body} ->
        body

      {:error, reason} ->
        if System.monotonic_time(:second) >= deadline do
          raise "HTTP check failed for http://#{env.ip}/ after timeout: #{reason}"
        else
          Process.sleep(3_000)
          do_wait_http(env, deadline)
        end
    end
  end

  defp http_get(ip) do
    case Req.get("http://#{ip}/", retry: false, redirect: false, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, to_string(body)}
      {:ok, %{status: status}} -> {:error, "status #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp assert_body!(env, label, body) do
    expected = System.get_env("E2E_EXPECT_BODY", "")

    if expected != "" and not String.contains?(body, expected) do
      raise "#{label}: response body does not contain #{inspect(expected)}"
    end
  end

  defp start_infra do
    for app <- [:crypto, :ecto_sql, :ecto_sqlite3, :cloak, :cloak_ecto, :req] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    db_path = Path.join(System.tmp_dir!(), "cleat_e2e_#{System.unique_integer([:positive])}.db")

    repo_config =
      Application.get_env(:cleat_deploy, CleatDeploy.Repo, [])
      |> Keyword.merge(
        database: db_path,
        pool_size: 2,
        busy_timeout: 10_000,
        journal_mode: :wal
      )

    Application.put_env(:cleat_deploy, CleatDeploy.Repo, repo_config)
    Application.put_env(:cleat_deploy, :github_webhook_sync, false)

    {:ok, _} = Repo.start_link()
    {:ok, _} = Vault.start_link()

    migrations = Path.expand("priv/repo/migrations")
    _migrated = Ecto.Migrator.run(Repo, migrations, :up, all: true)

    db_path
  end

  defp create_scope do
    unique = System.unique_integer([:positive])

    {:ok, %{user: user, tenant: tenant}} =
      Accounts.register_user_with_tenant(%{
        email: "cleat-e2e-#{unique}@example.com",
        password: "cleat-e2e-#{unique}-Aa1"
      })

    Scope.for_user(user, tenant, "owner")
  end

  defp create_server(scope, env) do
    key = File.read!(env.key_path)

    {:ok, server} =
      Servers.create_server(scope, %{
        name: "cleat-e2e",
        host_ip: env.ip,
        ssh_user: "ubuntu",
        region: "fsn1",
        provider: "hetzner",
        ssh_private_key: key
      })

    IO.puts("==> registered disposable server ##{server.id} (#{server.host_ip})")
    server
  end

  defp create_app(scope, server, env) do
    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Cleat E2E",
        slug: "cleat-e2e",
        github_repo: env.repo,
        branch: env.ref,
        host: env.ip,
        runtime: @runtime,
        server_id: server.id
      })

    IO.puts("==> registered reference app ##{app.id} (#{@runtime})")
    Apps.get_app!(scope, app.id)
  end

  defp write_summary(path, env, steps, ok, error \\ nil) do
    payload = %{
      ok: ok,
      error: error,
      server_ip: env.ip,
      repo: env.repo,
      runtime: @runtime,
      steps: steps
    }

    File.write!(path, Jason.encode!(payload, pretty: true) <> "\n")
  end

  defp env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "missing required environment variable #{name}"
    end
  end
end

CleatE2E.DeploySmoke.run()
