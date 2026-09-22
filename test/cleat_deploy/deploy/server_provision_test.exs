defmodule CleatDeploy.Deploy.ServerProvisionTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.ServerProvision
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Phoenix TTS",
        slug: "phoenix-tts",
        github_repo: "puppe1990/phoenix_tts",
        host: "tts.gestaobem.com",
        port: 4004,
        systemd_unit: "phoenix_tts",
        release_path: "/opt/phoenix_tts",
        server_id: server.id
      })

    config = App.deploy_config(app)
    %{app: app, config: config, scope: scope, server: server}
  end

  test "provision_script creates systemd unit, data dir, and caddy site", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Provisioning host tts.gestaobem.com on port 4004"
    assert script =~ "/etc/systemd/system/phoenix_tts.service"
    assert script =~ "ExecStart=/opt/phoenix_tts/current/bin/phoenix_tts start"
    assert script =~ "sudo mkdir -p '/etc/phoenix_tts' '/var/lib/phoenix_tts'"
    assert script =~ "Environment=CLEAT_DATA_DIR=/var/lib/phoenix_tts"
    assert script =~ "tts.gestaobem.com {"
    assert script =~ "reverse_proxy 127.0.0.1:4004"
    assert script =~ "Writing Caddy site tts.gestaobem.com"
    assert script =~ "sudo awk -v site='tts.gestaobem.com'"
    assert script =~ ~s|sudo install -m 0644 -o root -g root "$TMPFILE" "$CADDYFILE"|
  end

  test "node apps get a persistent data dir outside the release", %{
    scope: scope,
    server: server
  } do
    {:ok, app, _webhook_status} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Leitor",
        slug: "leitor",
        github_repo: "owner/leitor",
        host: "leitor.example.com",
        runtime: "node",
        server_id: server.id
      })

    config = App.deploy_config(app)
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Environment=CLEAT_DATA_DIR=/opt/leitor/data"
    assert script =~ "sudo mkdir -p '/etc/leitor' '/opt/leitor/data'"
  end

  test "provision_script rewrites an existing caddy site when the port changes", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(%{app | port: 4088}, config, manifest)

    assert script =~ "reverse_proxy 127.0.0.1:4088"
    assert script =~ "Writing Caddy site tts.gestaobem.com"
    refute script =~ "reverse_proxy 127.0.0.1:4004"
  end

  test "migrate_script falls back to release eval when bin/migrate is absent", %{config: config} do
    script = ServerProvision.migrate_script(config)

    assert script =~ "bin/migrate"
    assert script =~ "release eval"
    assert script =~ "Ecto.Migrator.with_repo"
  end

  test "migrate_script skips release eval migrations when app has no ecto_repos" do
    config = %{
      release_path: "/opt/rapid_tools",
      release_name: "rapid_tools",
      env_file: "/etc/rapid_tools/env"
    }

    script = ServerProvision.migrate_script(config)

    assert script =~ "Application.get_env(:rapid_tools, :ecto_repos, [])"
    assert script =~ "[] -> :ok"
    refute script =~ "fetch_env!"
  end

  test "migrate_script still runs ecto migrations when ecto_repos is configured", %{
    config: config
  } do
    script = ServerProvision.migrate_script(config)

    assert script =~ "Application.get_env(:phoenix_tts, :ecto_repos, [])"
    assert script =~ "Ecto.Migrator.with_repo"
    refute script =~ "fetch_env!"
  end

  test "reload_caddy_script reloads or restarts caddy", %{config: _config} do
    script = ServerProvision.reload_caddy_script()

    assert script =~ "Reloading Caddy"
    assert script =~ "systemctl reload caddy"
  end

  test "IP hosts get an http:// site to avoid a broken HTTPS redirect", %{app: app} do
    app = %{app | host: "203.0.113.10"}
    config = App.deploy_config(app)
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "http://203.0.113.10 {"
    assert script =~ "Writing Caddy site http://203.0.113.10"
    assert script =~ "reverse_proxy 127.0.0.1:4004"
  end

  test "provision_script replaces caddyfile when manifest requests replace", %{
    app: app,
    config: config
  } do
    manifest = %AppManifest{
      caddy_mode: "replace",
      caddyfile: "deploy/Caddyfile",
      memory_max_mb: 1024
    }

    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Installing custom Caddyfile (deploy/Caddyfile)"
    assert script =~ ~s|sudo cp "$BUILD_DIR/deploy/Caddyfile" /etc/caddy/Caddyfile|
    assert script =~ "MemoryMax=1024M"
    refute script =~ "Writing Caddy site"
  end

  test "arms wake-on-request for apps that opted into auto sleep", %{app: app, config: config} do
    app = %{app | idle_shutdown_enabled: true}
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Installing wake agent"
    assert script =~ "/usr/local/lib/cleat/waker.py"
    assert script =~ "systemctl enable cleat-waker"
    assert script =~ "forward_auth 127.0.0.1:3900 {"
    assert script =~ "uri /wake?unit=phoenix_tts&port=4004"
    assert script =~ "reverse_proxy 127.0.0.1:4004"
    assert script =~ "Arming idle shutdown for phoenix_tts"
    assert script =~ "sudo touch '/var/lib/cleat/stamps/phoenix_tts.stamp'"

    # The agent has to be reachable before the site that depends on it is
    # written, and the stamp is armed only after the site exists.
    ready = :binary.match(script, "Wake agent listening") |> elem(0)
    site = :binary.match(script, "uri /wake?unit=phoenix_tts&port=4004") |> elem(0)
    armed = :binary.match(script, "Arming idle shutdown for phoenix_tts") |> elem(0)

    assert ready < site
    assert site < armed
  end

  test "leaves apps alone and disarms them when auto sleep is off", %{app: app, config: config} do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    refute script =~ "forward_auth"
    refute script =~ "cleat-waker"
    refute script =~ "cleat_waker.py"
    assert script =~ "sudo rm -f '/var/lib/cleat/stamps/phoenix_tts.stamp'"
  end

  test "never arms a custom caddyfile or a static site", %{app: app, config: config} do
    opted_in = %{app | idle_shutdown_enabled: true}

    replace_script =
      ServerProvision.provision_script(opted_in, config, %AppManifest{
        caddy_mode: "replace",
        caddyfile: "deploy/Caddyfile"
      })

    refute replace_script =~ "forward_auth"
    refute replace_script =~ "cleat_waker.py"

    static_app = %{opted_in | runtime: "static", systemd_unit: nil, release_path: "/var/www/tts"}
    static_config = App.deploy_config(static_app)

    static_script =
      ServerProvision.provision_script(static_app, static_config, %AppManifest{runtime: "static"})

    refute static_script =~ "forward_auth"
    refute static_script =~ "cleat_waker.py"
  end

  test "processes become one unit each, with the port only on web", %{
    app: app,
    config: config
  } do
    manifest = %AppManifest{
      runtime: "rails",
      processes: %{
        "web" => "bundle exec rails server",
        "worker" => "bundle exec sidekiq",
        "scheduler" => "bundle exec rake scheduler"
      }
    }

    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "/etc/systemd/system/phoenix_tts.service"
    assert script =~ "/etc/systemd/system/phoenix_tts-worker.service"
    assert script =~ "/etc/systemd/system/phoenix_tts-scheduler.service"

    web = unit_block(script, "phoenix_tts")
    worker = unit_block(script, "phoenix_tts-worker")
    scheduler = unit_block(script, "phoenix_tts-scheduler")

    # The web process keeps the base unit, the app port and the Caddy site.
    assert web =~ "ExecStart=/bin/bash /opt/phoenix_tts/current/start.sh"
    assert web =~ "Environment=PORT=4004"
    assert web =~ "Environment=HOST=127.0.0.1"
    assert script =~ "reverse_proxy 127.0.0.1:4004"

    # Extra processes get their own command file and never bind the port.
    assert worker =~ "ExecStart=/bin/bash /opt/phoenix_tts/current/start.sh start.worker.cmd"

    assert scheduler =~
             "ExecStart=/bin/bash /opt/phoenix_tts/current/start.sh start.scheduler.cmd"

    refute worker =~ "Environment=PORT"
    refute worker =~ "Environment=HOST"
    refute scheduler =~ "Environment=PORT"

    # Same limits and env for every process.
    for unit <- [web, worker, scheduler] do
      assert unit =~ "EnvironmentFile=/etc/phoenix_tts/env"
      assert unit =~ "Environment=CLEAT_DATA_DIR=/opt/phoenix_tts/data"
      assert unit =~ "Restart=always"
      assert unit =~ "KillMode=control-group"
      assert unit =~ "MemoryMax=400M"
    end
  end

  test "restart_units_script restarts web first and checks each unit", %{config: config} do
    manifest = %AppManifest{
      runtime: "rails",
      processes: %{"web" => "a", "worker" => "b"}
    }

    script = ServerProvision.restart_units_script(config, manifest)

    assert script =~ ~s|log "Restarting phoenix_tts"|
    assert script =~ ~s|log "Restarting phoenix_tts-worker"|

    assert occurrence(script, "Restarting phoenix_tts\"") <
             occurrence(script, "Restarting phoenix_tts-worker")

    assert script =~ "sudo systemctl restart phoenix_tts-worker"
    assert script =~ "exit 1"
  end

  test "extra_start_commands writes one command file per non-web process", %{config: config} do
    manifest = %AppManifest{
      runtime: "rails",
      processes: %{"web" => "bundle exec rails server", "worker" => "bundle exec sidekiq"}
    }

    script = ServerProvision.extra_start_commands(manifest, config)

    assert script =~ "/opt/phoenix_tts/releases/build/start.worker.cmd"
    assert script =~ Base.encode64("bundle exec sidekiq")
    refute script =~ "start.cmd'"
    refute script =~ "bundle exec rails server"
  end

  test "the launcher takes the command file as its first argument" do
    script = ServerProvision.start_script()

    assert script =~ ~s|CMD_FILE="${1:-start.cmd}"|
    assert script =~ ~s|CMD="$(cat "$(dirname "$0")/$CMD_FILE")"|
  end

  defp unit_block(script, unit) do
    pattern =
      Regex.compile!(
        Regex.escape("#{unit}.service > /dev/null <<'PAAS_SYSTEMD_UNIT'") <>
          "\n(.*?)\nPAAS_SYSTEMD_UNIT",
        "s"
      )

    case Regex.run(pattern, script) do
      [_, block] -> block
      nil -> flunk("no unit block for #{unit}")
    end
  end

  defp occurrence(script, snippet) do
    {position, _length} = :binary.match(script, snippet)
    position
  end

  test "release_command_script runs each command in order with the app env", %{
    app: app,
    config: config
  } do
    manifest = %AppManifest{
      runtime: "rails",
      release_command: [
        "bundle exec rails db:chatwoot_prepare",
        "bundle exec rails runner 'puts 1'"
      ],
      release_timeout_s: 900
    }

    script = ServerProvision.release_command_script(app, config, manifest)

    assert script =~ "Running release command (1/2)"
    assert script =~ "Running release command (2/2)"
    assert script =~ Base.encode64("bundle exec rails db:chatwoot_prepare")
    assert script =~ Base.encode64("bundle exec rails runner 'puts 1'")
    assert script =~ "source /etc/phoenix_tts/env"
    assert script =~ "cd /opt/phoenix_tts/current"
    assert script =~ "timeout 900 bash /tmp/cleat_release_cmd.sh"
    assert script =~ "export RAILS_ENV=production"

    first = :binary.match(script, "Running release command (1/2)") |> elem(0)
    second = :binary.match(script, "Running release command (2/2)") |> elem(0)
    assert first < second
  end

  test "release_command_script exports the runtime env and the app data dir", %{
    app: app,
    config: config
  } do
    node_script =
      ServerProvision.release_command_script(app, config, %AppManifest{
        runtime: "node",
        release_command: ["npm run db:migrate"]
      })

    assert node_script =~ "export NODE_ENV=production"
    assert node_script =~ "export CLEAT_DATA_DIR=/opt/phoenix_tts/data"

    phoenix_script =
      ServerProvision.release_command_script(app, config, %AppManifest{
        release_command: ["bin/migrate"]
      })

    refute phoenix_script =~ "export NODE_ENV"
    refute phoenix_script =~ "export RAILS_ENV"
    assert phoenix_script =~ "export CLEAT_DATA_DIR=/var/lib/phoenix_tts"
  end
end
