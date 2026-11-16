defmodule CleatDeploy.Deploy.PythonTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, Python, ServerProvision}
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Hermes",
        slug: "hermes",
        github_repo: "puppe1990/hermes-cleat",
        host: "hermes.example.com",
        runtime: "python",
        port: 4260,
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)

    %{app: app, config: App.deploy_config(app)}
  end

  test "python apps default to /opt and a python-<slug> systemd unit", %{app: app} do
    assert app.release_path == "/opt/hermes"
    assert app.systemd_unit == "python-hermes"
    assert App.main_language(app) == "Python"
    assert App.data_dir(app) == "/opt/hermes/data"
  end

  test "provision script writes a systemd unit and a Caddy reverse proxy", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Provisioning Python host hermes.example.com on port 4260"
    assert script =~ "/etc/systemd/system/python-hermes.service"
    assert script =~ "ExecStart=/bin/bash /opt/hermes/current/start.sh"
    assert script =~ "Environment=PORT=4260"
    assert script =~ "Environment=PYTHONUNBUFFERED=1"
    assert script =~ "Environment=CLEAT_DATA_DIR=/opt/hermes/data"
    assert script =~ "reverse_proxy 127.0.0.1:4260"
    assert script =~ "KillMode=control-group"
    assert script =~ "TimeoutStopSec=30"
  end

  test "build script installs uv, syncs deps, and publishes the venv", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Python.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "Installing uv"
    assert script =~ "astral.sh/uv/install.sh"
    assert script =~ ~s|UV_PYTHON_INSTALL_DIR="$PWD/.cleat-python"|
    assert script =~ "uv python install"
    assert script =~ "uv.lock"
    assert script =~ "uv venv --relocatable"
    assert script =~ "uv sync --frozen --no-dev"
    assert script =~ "requirements.txt"
    assert script =~ "pyproject.toml"
    assert script =~ "/opt/hermes/releases/build"
    assert script =~ "start.sh"
    assert script =~ "sudo systemctl restart python-hermes"
    assert script =~ ".venv/bin"

    assert occurrence(script, "Fixing data ownership for cleat-hermes") <
             occurrence(script, "Restarting python-hermes")

    refute script =~ "chmod -R a+rX"
  end

  test "publish empties the reused release dir with find, dotfiles included" do
    slug = "#{Faker.Lorem.word()}-#{Faker.Lorem.word()}"

    app = %App{
      name: Faker.Company.name(),
      slug: slug,
      host: "#{slug}.example.com",
      runtime: "python",
      port: 4260,
      release_path: "/opt/#{slug}",
      systemd_unit: "python-#{slug}"
    }

    config = App.deploy_config(app)

    script =
      Python.remote_build_script(
        nil,
        app,
        config,
        Faker.Internet.user_name(),
        "/tmp/src.tar.gz",
        %AppManifest{runtime: "python"}
      )

    refute script =~ ~S|rm -rf "${RELEASE_DIR:?}"/*|
    refute script =~ "find '/opt/#{slug}' -mindepth 1 -delete"
    assert script =~ "sudo find '/opt/#{slug}/releases/build' -mindepth 1 -delete"
    assert occurrence(script, "-mindepth 1 -delete") < occurrence(script, "sudo cp -a .")
  end

  test "manifest custom build/start commands and python version win over detection" do
    app = %App{
      name: "Hermes",
      slug: "hermes",
      host: "hermes.example.com",
      runtime: "python",
      port: 4260,
      release_path: "/opt/hermes",
      systemd_unit: "python-hermes"
    }

    config = App.deploy_config(app)

    manifest = %AppManifest{
      runtime: "python",
      build_command: "uv run python -m compileall .",
      start_command: "uv run gunicorn app:app --bind 127.0.0.1:$PORT",
      python_version: "3.14"
    }

    script = Python.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    assert script =~ "uv run python -m compileall ."
    assert script =~ "START_CMD='uv run gunicorn app:app --bind 127.0.0.1:$PORT'"
    assert script =~ ~s|PYTHON_VERSION="3.14"|
  end

  test "processes.web is used as the start command when start_command is absent" do
    app = %App{
      name: "Hermes",
      slug: "hermes",
      host: "hermes.example.com",
      runtime: "python",
      port: 4260,
      release_path: "/opt/hermes",
      systemd_unit: "python-hermes"
    }

    config = App.deploy_config(app)

    manifest = %AppManifest{
      runtime: "python",
      processes: %{"web" => "uv run uvicorn app:app --host 127.0.0.1 --port $PORT"}
    }

    script = Python.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    assert script =~ "START_CMD='uv run uvicorn app:app --host 127.0.0.1 --port $PORT'"
  end

  test "infers python main.py when no start_command is set", %{app: app, config: config} do
    manifest = %AppManifest{runtime: "python"}
    script = Python.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "main.py"
    assert script =~ "app.py"
    assert script =~ "Could not determine a start command"
  end

  test "release command runs after the env sync and before the restart" do
    app = %App{
      name: "Hermes",
      slug: "hermes",
      host: "hermes.example.com",
      runtime: "python",
      port: 4260,
      release_path: "/opt/hermes",
      systemd_unit: "python-hermes"
    }

    config = App.deploy_config(app)

    manifest = %AppManifest{runtime: "python", release_command: ["uv run alembic upgrade head"]}

    script = Python.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    assert script =~ "Running release command (1/1)"
    assert script =~ "PYTHONUNBUFFERED=1"
    assert script =~ "timeout"
    assert script =~ "/tmp/cleat_release_cmd.sh"

    assert occurrence(script, "Running release command") <
             occurrence(script, "Restarting python-hermes")
  end

  defp occurrence(script, snippet) do
    {position, _length} = :binary.match(script, snippet)
    position
  end
end
