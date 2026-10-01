defmodule CleatDeploy.Deploy.NodeTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, Node, ServerProvision}
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Cleat Web",
        slug: "cleat-web",
        github_repo: "puppe1990/cleat-web",
        host: "web.example.com",
        runtime: "node",
        port: 4020,
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)

    %{app: app, config: App.deploy_config(app)}
  end

  test "node apps default to /opt and a node-<slug> systemd unit", %{app: app} do
    assert app.release_path == "/opt/cleat-web"
    assert app.systemd_unit == "node-cleat-web"
    assert App.main_language(app) == "JavaScript"
  end

  test "provision script writes a systemd unit and a Caddy reverse proxy", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Provisioning Node host web.example.com on port 4020"
    assert script =~ "/etc/systemd/system/node-cleat-web.service"
    assert script =~ "ExecStart=/bin/bash /opt/cleat-web/current/start.sh"
    assert script =~ "Environment=PORT=4020"
    assert script =~ "reverse_proxy 127.0.0.1:4020"
    # An orphaned node from a previous unit kept the port and put the unit in an
    # infinite restart loop; kill the whole cgroup and rate-limit retries.
    assert script =~ "KillMode=control-group"
    assert script =~ "TimeoutStopSec=15"
    assert script =~ "StartLimitIntervalSec=60"
    assert script =~ "StartLimitBurst=5"
  end

  test "start.sh surfaces the app's own output instead of swallowing failures" do
    script = ServerProvision.start_script()

    # `exec cmd` with no wrapper made a crashing app look like a clean exit
    refute script =~ "exec bash -c"
    # the launcher logs the command and the exit status, then propagates it
    assert script =~ "==> starting"
    assert script =~ "exited with status"
    assert script =~ ~s|exit "$code"|
  end

  test "build script picks the lockfile package manager and falls back to npm", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Node.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    # A persistent npm cache survives between deploys (the tarballs do not live
    # in BUILD_DIR, which is wiped on every deploy).
    assert script =~ ~s|npm_config_cache="$HOME/.npm"|
    # `npm ci` only runs when a lockfile exists; a stale lock must say so loudly
    # instead of silently falling back to `npm install`.
    assert script =~ "package-lock.json out of sync"
    assert script =~ "npm install --no-audit --no-fund"

    # pnpm/yarn/bun projects must not fall through to npm install: npm 10 dies
    # on modern peer graphs (vitest) before build_command can run.
    assert script =~ "pnpm-lock.yaml"
    assert script =~ "pnpm install --frozen-lockfile"
    assert script =~ "yarn.lock"
    assert script =~ "yarn install --immutable"
    assert script =~ "bun.lock"
    assert script =~ "bun install --frozen-lockfile"
    assert script =~ "enable_package_manager pnpm"
    assert script =~ "enable_package_manager yarn"
    assert script =~ "sudo corepack enable"
    assert script =~ "export HUSKY=0"

    pnpm_pos = occurrence(script, "pnpm-lock.yaml")
    npm_fallback_pos = occurrence(script, "No package-lock.json")
    assert pnpm_pos < npm_fallback_pos
  end

  test "build script installs node, builds, resolves a start command, and restarts", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Node.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "Installing Node.js"
    assert script =~ "npm ci --no-audit --no-fund"
    assert script =~ "npm run build"
    assert script =~ ".output/server/index.mjs"
    assert script =~ "next start"
    assert script =~ "/opt/cleat-web/releases/build"
    assert script =~ "start.sh"
    assert script =~ "sudo systemctl restart node-cleat-web"
    # build dir and source tarball must not leak (they filled the disk in prod)
    assert script =~ ~s|trap 'rm -rf "$BUILD_DIR"; rm -f /tmp/src.tar.gz' EXIT|
    # orphan (non-build) release dirs are pruned
    assert script =~ "! -name build -exec rm -rf {} +"
  end

  test "build script timestamps each phase so slow deploys are measurable", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Node.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "SECONDS=0"
    assert script =~ ~s|log "Installing JS dependencies"|
    assert script =~ "Done in ${SECONDS}s"
  end

  test "build script prunes dev dependencies and drops node_modules for Nitro output", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Node.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    # devDependencies are only needed for the build; don't publish them
    assert script =~ "npm prune --omit=dev"
    # TanStack Start / Nitro output is self-contained (native deps live under
    # .output/server/node_modules), so the project node_modules is dead weight
    assert script =~ "rm -rf node_modules"
  end

  test "build script prunes with the lockfile package manager, not npm on a pnpm tree", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Node.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    {prune_pos, _} = :binary.match(script, "Pruning dev dependencies for the release")
    prune_tail = binary_part(script, prune_pos, byte_size(script) - prune_pos)

    # npm prune on a pnpm node_modules tree dies with
    # "Cannot read properties of null (reading 'matches')" (new-lp deploy 893).
    # pnpm prune --prod re-runs prepare after husky is gone (new-lp deploy 896).
    assert prune_tail =~ "pnpm-lock.yaml"
    assert prune_tail =~ "pnpm install --prod --frozen-lockfile --ignore-scripts"
    assert prune_tail =~ "yarn.lock"
    assert prune_tail =~ "yarn install --production"
    assert prune_tail =~ "--ignore-scripts"
    assert prune_tail =~ "bun.lock"
    assert prune_tail =~ "bun install --production"
    assert prune_tail =~ "npm prune --omit=dev"

    assert occurrence(prune_tail, "pnpm install --prod --frozen-lockfile --ignore-scripts") <
             occurrence(prune_tail, "npm prune --omit=dev")

    # pnpm 11 aborts `install --prod` when node_modules must be rebuilt and
    # stdin is not a TTY (gestao-bem-landing deploy 905):
    # ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY
    assert prune_tail =~ "CI=true"
    assert prune_tail =~ "confirmModulesPurge=false"
  end

  test "build script drops node_modules for nested Nitro start commands", %{
    app: app,
    config: config
  } do
    manifest = %AppManifest{
      runtime: "node",
      start_command: "node apps/landing/.output/server/index.mjs"
    }

    script = Node.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    # Exact `node .output/server/index.mjs` misses monorepo output
    # (`node apps/landing/.output/server/index.mjs`) and falls through to
    # `pnpm install --prod`, which then dies without a TTY.
    # The glob must be a single `[[ == ]]` word: `node *".output/..."` is two
    # words and bash dies with "syntax error in conditional expression"
    # (gestao-bem-landing deploy 906).
    assert script =~ ~s|if [[ "$START_CMD" == "node "*.output/server/index.mjs ]]|
    refute script =~ ~s|if [[ "$START_CMD" == node *".output/server/index.mjs" ]]|
    refute script =~ ~s|if [[ "$START_CMD" == "node .output/server/index.mjs" ]]|
    assert script =~ "Self-contained Nitro output; dropping node_modules before publish"
    assert_valid_bash(script)
  end

  test "build script detects Next standalone and drops node_modules", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Node.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    # Next standalone output carries its own node_modules, so the project's is
    # dropped and the app is started from the standalone server.
    assert script =~ ".next/standalone/server.js"
    assert script =~ "node .next/standalone/server.js"
    assert script =~ "Copying public and static assets into the standalone output"
    # standalone must win over a `start` script (e.g. `next start`), otherwise
    # it is never reached and the project node_modules come back.
    standalone_pos = :binary.match(script, ".next/standalone/server.js") |> elem(0)
    start_script_pos = :binary.match(script, "s.start?0:1") |> elem(0)
    assert standalone_pos < start_script_pos
    # the build cache is hundreds of MB and is not needed at runtime
    assert script =~ "rm -rf .next/cache"
  end

  test "manifest custom build/start commands and node version win over detection" do
    app = %App{
      name: "Web",
      slug: "web",
      host: "web.example.com",
      runtime: "node",
      port: 3000,
      release_path: "/opt/web",
      systemd_unit: "node-web"
    }

    config = App.deploy_config(app)

    manifest = %AppManifest{
      runtime: "node",
      build_command: "pnpm build",
      start_command: "pnpm start",
      node_version: "20"
    }

    script = Node.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    assert script =~ "pnpm build"
    assert script =~ "START_CMD='pnpm start'"
    assert script =~ ~s|NODE_MAJOR="20"|
  end

  test "release command runs after the env sync and before the restart" do
    app = %App{
      name: "Web",
      slug: "web",
      host: "web.example.com",
      runtime: "node",
      port: 3000,
      release_path: "/opt/web",
      systemd_unit: "node-web"
    }

    config = App.deploy_config(app)

    manifest = %AppManifest{runtime: "node", release_command: ["npm run db:migrate"]}

    script = Node.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    assert script =~ "Running release command (1/1)"
    assert script =~ "export NODE_ENV=production"
    assert script =~ "timeout 300 bash /tmp/cleat_release_cmd.sh"

    assert occurrence(script, "Running release command") <
             occurrence(script, "Restarting node-web")
  end

  defp occurrence(script, snippet) do
    {position, _length} = :binary.match(script, snippet)
    position
  end

  defp assert_valid_bash(script) do
    path =
      Path.join(
        System.tmp_dir!(),
        "cleat-node-build-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, script)

    try do
      {output, status} = System.cmd("bash", ["-n", path], stderr_to_stdout: true)
      assert status == 0, output
    after
      File.rm(path)
    end
  end
end
