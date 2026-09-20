defmodule CleatDeploy.Deploy.Ssh do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Golang
  alias CleatDeploy.Deploy.Node
  alias CleatDeploy.Deploy.Rails
  alias CleatDeploy.Deploy.Runtime
  alias CleatDeploy.Deploy.ServerProvision
  alias CleatDeploy.Deploy.Static
  alias CleatDeploy.Repo

  @tar_excludes ~w(_build deps node_modules .git tmp priv/static/assets)

  def run(server, app, argv) when is_list(argv) do
    with :ok <- ensure_commands(["ssh"]),
         {:ok, key_path} <- write_temp_key(server) do
      try do
        host_ip = CleatDeploy.Deploy.Target.ssh_host_ip(app, server)
        target = "#{server.ssh_user}@#{host_ip}"
        args = log_ssh_base(key_path, target) ++ [command(argv)]
        cmd("ssh", args)
      after
        File.rm(key_path)
      end
    end
  end

  @doc """
  Shell-quotes `argv` into a single remote command.

  ssh joins the trailing arguments with spaces, so passing them raw would split
  scripts (and only prefix the first line with `bash -lc`). Quoting each element
  keeps the remote command exactly as intended.
  """
  def command(argv) when is_list(argv) do
    argv
    |> Enum.map(&shell_escape/1)
    |> Enum.join(" ")
  end

  def run_deploy(deployment, app, server) do
    config = CleatDeploy.Apps.App.deploy_config(app)
    branch = deployment.git_ref || app.branch
    sha = short_sha(deployment.git_sha)

    with :ok <- ensure_commands(["git", "ssh", "scp", "tar"]),
         {:ok, key_path} <- write_temp_key(server) do
      # Nested try/after so cleanup always sees the bound path. Outer `with`
      # bindings are not visible to a sibling `after` clause (classic Elixir
      # pitfall that left /tmp/cleat_deploy_clone_* forever and broke later
      # deploys when unique_integer collided after a BEAM restart).
      try do
        with {:ok, work_dir} <- clone_repo(app.github_repo, branch) do
          try do
            with :ok <- validate_manifest_for_server(work_dir, app, server),
                 {:ok, tarball} <- create_tarball(work_dir) do
              try do
                upload_and_build(tarball, key_path, server, app, config, sha, work_dir)
              after
                File.rm(tarball)
              end
            end
          after
            File.rm_rf(work_dir)
          end
        end
      after
        File.rm(key_path)
      end
    end
  end

  defp target_log(stored_ip, host_ip, app_host) when stored_ip == host_ip do
    "==> Deploy target #{host_ip} (#{app_host})"
  end

  defp target_log(stored_ip, host_ip, app_host) do
    "==> Corrected deploy target #{stored_ip} -> #{host_ip} (DNS #{app_host})"
  end

  defp ensure_commands(commands) do
    missing =
      Enum.reject(commands, fn cmd ->
        case System.find_executable(cmd) do
          nil -> false
          _ -> true
        end
      end)

    if missing == [] do
      :ok
    else
      {:error, "Missing commands: #{Enum.join(missing, ", ")}"}
    end
  end

  defp write_temp_key(%{ssh_private_key_encrypted: key}) when key in [nil, ""],
    do: {:error, "SSH private key not configured on server"}

  defp write_temp_key(%{ssh_private_key_encrypted: key}) do
    path = temp_path("cleat_deploy_ssh")

    with :ok <- File.write(path, key),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      {:error, reason} -> {:error, "Could not write SSH key: #{inspect(reason)}"}
    end
  end

  defp clone_repo(github_repo, branch) do
    dir = temp_path("cleat_deploy_clone")
    # Defensive: old BEAM restarts reused unique_integer counters and leftover
    # dirs from the cleanup bug would make `git clone` fail immediately.
    _ = File.rm_rf(dir)

    url = github_clone_url(github_repo)

    case cmd("git", ["clone", "--depth", "50", "-b", branch, url, dir]) do
      {:ok, _output} -> {:ok, dir}
      {:error, output} -> {:error, "git clone failed:\n#{output}"}
    end
  end

  defp create_tarball(work_dir) do
    path = temp_path("cleat_deploy_src") <> ".tar.gz"
    _ = File.rm(path)

    args = ["-czf", path] ++ tar_exclude_args() ++ ["-C", work_dir, "."]

    case cmd("tar", args) do
      {:ok, _output} -> {:ok, path}
      {:error, output} -> {:error, "tar failed:\n#{output}"}
    end
  end

  defp temp_path(prefix) when is_binary(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}_#{System.system_time(:nanosecond)}_#{:erlang.unique_integer([:positive])}"
    )
  end

  defp upload_and_build(tarball, key_path, server, app, config, sha, work_dir) do
    host_ip = CleatDeploy.Deploy.Target.ssh_host_ip(app, server)
    _ = CleatDeploy.Deploy.Target.sync_server_host_ip(server, host_ip)
    remote_tar = "/tmp/cleat_deploy_#{sha}.tar.gz"
    target = "#{server.ssh_user}@#{host_ip}"
    runtime = CleatDeploy.Deploy.RuntimePackages.resolve(app, work_dir)
    target_note = target_log(server.host_ip, host_ip, app.host)

    with {:ok, upload_out} <- scp(tarball, remote_tar, key_path, target),
         {:ok, build_out} <-
           remote_build(remote_tar, key_path, target, server, app, config, sha, runtime, work_dir) do
      log =
        [
          "==> Cloning #{app.github_repo} (branch #{app.branch})",
          target_note,
          "==> Uploading source to #{target}",
          trim(upload_out),
          "==> Building on #{server.provider || "lightsail"} VM",
          trim(build_out),
          "==> Deployment successful — live at https://#{app.host}"
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      {:ok, log}
    end
  end

  defp scp(local, remote, key_path, target) do
    case cmd("scp", scp_base(key_path) ++ [local, "#{target}:#{remote}"]) do
      {:ok, output} -> {:ok, output}
      {:error, output} -> {:error, "scp failed:\n#{output}"}
    end
  end

  defp remote_build(remote_tar, key_path, target, server, app, config, sha, runtime, work_dir) do
    script = remote_build_script(server, app, config, sha, remote_tar, runtime, work_dir)

    run_remote_script(script, key_path, target, "remote build", sha)
  end

  @doc """
  Publishes a git-less drop: uploads the stored artifact and serves its contents.
  """
  def run_drop(deployment, app, server) do
    config = CleatDeploy.Apps.App.deploy_config(app)
    manifest = AppManifest.resolve(nil, app)
    artifact = deployment.artifact_path

    with :ok <- ensure_commands(["ssh", "scp"]),
         :ok <- ensure_artifact(artifact),
         {:ok, key_path} <- write_temp_key(server) do
      try do
        sha = short_sha(deployment.git_sha)
        host_ip = CleatDeploy.Deploy.Target.ssh_host_ip(app, server)
        _ = CleatDeploy.Deploy.Target.sync_server_host_ip(server, host_ip)
        target = "#{server.ssh_user}@#{host_ip}"
        remote_tar = "/tmp/cleat_drop_#{sha}_#{:erlang.unique_integer([:positive])}.tar.gz"
        target_note = target_log(server.host_ip, host_ip, app.host)

        with {:ok, upload_out} <- scp(artifact, remote_tar, key_path, target) do
          script = Static.remote_drop_script(app, config, sha, remote_tar, manifest)

          case run_remote_script(script, key_path, target, "remote publish", sha) do
            {:ok, build_out} ->
              _ = File.rm(artifact)

              log =
                [
                  "==> Publishing drop for #{app.slug}",
                  target_note,
                  "==> Uploading artifact to #{target}",
                  trim(upload_out),
                  "==> Publishing on #{server.provider || "lightsail"} VM",
                  trim(build_out),
                  "==> Deployment successful — live at https://#{app.host}"
                ]
                |> Enum.reject(&(&1 == ""))
                |> Enum.join("\n")

              {:ok, log}

            {:error, message} ->
              {:error, message}
          end
        end
      after
        File.rm(key_path)
      end
    end
  end

  defp ensure_artifact(path) when is_binary(path) do
    if File.exists?(path), do: :ok, else: {:error, "Drop artifact not found: #{path}"}
  end

  defp ensure_artifact(_), do: {:error, "Drop artifact missing"}

  defp run_remote_script(script, key_path, target, label, sha) do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "cleat_deploy_remote_#{sha}_#{:erlang.unique_integer([:positive])}.sh"
      )

    try do
      :ok = File.write!(script_path, script)

      ssh_args =
        (ssh_base(key_path, target) ++ ["bash", "-s"])
        |> Enum.map(&shell_escape/1)
        |> Enum.join(" ")

      case System.cmd("bash", ["-c", "ssh #{ssh_args} < #{shell_escape(script_path)}"],
             stderr_to_stdout: true
           ) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, "#{label} failed:\n#{output}"}
      end
    after
      File.rm(script_path)
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  @doc false
  def env_sync_enabled?(%{env_vars: vars}) when is_list(vars), do: vars != []
  def env_sync_enabled?(_), do: false

  @doc false
  def env_file_content(app) do
    app
    |> Apps.env_map()
    |> format_env_file()
  end

  defp format_env_file(env_map) do
    env_map
    |> Enum.sort()
    |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{value}" end)
    |> then(&(&1 <> "\n"))
  end

  @doc false
  def env_sync_script(app, config) do
    if env_sync_enabled?(app) do
      content_b64 = app |> env_file_content() |> Base.encode64()

      """
      log "Syncing environment from panel"
      sudo mkdir -p "$(dirname #{config.env_file})"
      echo '#{content_b64}' | base64 -d | sudo tee #{config.env_file} > /dev/null
      sudo chmod 600 #{config.env_file}
      """
    else
      ""
    end
  end

  defp apply_manifest_config(config, %AppManifest{} = manifest) do
    config
    |> maybe_put(:release_name, manifest.release_name)
    |> maybe_put(:systemd_unit, manifest.systemd_unit)
    |> maybe_put(:release_path, manifest.release_path)
  end

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Map.put(config, key, value)

  defp validate_manifest_for_server(work_dir, %App{} = app, server) do
    manifest = AppManifest.resolve(work_dir, app)
    apps_on_server = Repo.all(from(a in App, where: a.server_id == ^server.id))

    case AppManifest.validate_for_server(manifest, server, apps_on_server, app) do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp remote_build_script(server, app, config, sha, remote_tar, runtime, work_dir) do
    manifest = AppManifest.resolve(work_dir, app)

    config =
      config
      |> apply_manifest_config(manifest)
      |> Map.put(:ssh_user, server.ssh_user)

    cond do
      manifest.runtime == "static" ->
        Static.remote_build_script(server, app, config, sha, remote_tar, manifest)

      manifest.runtime == "node" ->
        Node.remote_build_script(server, app, config, sha, remote_tar, manifest)

      manifest.runtime == "rails" or Runtime.kind(work_dir, app) == :rails ->
        Rails.remote_build_script(server, app, config, sha, remote_tar, manifest)

      Runtime.kind(work_dir, app) == :golang or manifest.runtime == "golang" ->
        Golang.remote_build_script(server, app, config, sha, remote_tar, manifest)

      true ->
        phoenix_remote_build_script(server, app, config, sha, remote_tar, runtime, manifest)
    end
  end

  defp phoenix_remote_build_script(server, app, config, sha, remote_tar, runtime, manifest) do
    packages_install =
      case runtime.packages do
        [] ->
          ""

        packages ->
          """
          log "Installing runtime packages: #{Enum.join(packages, " ")}"
          sudo DEBIAN_FRONTEND=noninteractive apt-get update
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y #{Enum.join(packages, " ")}
          """
      end

    post_install_script =
      case runtime.post_install do
        [] -> ""
        steps -> Enum.map_join(steps, "\n", & &1) <> "\n"
      end

    """
    set -euo pipefail

    log() { printf '==> %s\\n' "$*"; }

    #{packages_install}#{post_install_script}
    if ! swapon --show | grep -q /swapfile; then
      sudo fallocate -l 2G /swapfile || true
      sudo chmod 600 /swapfile || true
      sudo mkswap /swapfile || true
      sudo swapon /swapfile || true
    fi

    if ! command -v mise >/dev/null 2>&1; then
      log "Installing mise + Erlang/Elixir"
      sudo apt-get update
      sudo apt-get install -y curl build-essential git ca-certificates
      curl -fsSL https://mise.run | sh
    fi

    export PATH="/home/#{server.ssh_user}/.local/bin:$PATH"
    eval "$(/home/#{server.ssh_user}/.local/bin/mise activate bash)"
    mise install erlang@28.4.1 elixir@1.19.5-otp-28
    mise use -g erlang@28.4.1 elixir@1.19.5-otp-28

    BUILD_DIR="$HOME/cleat_deploy_build_#{sha}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    tar -xzf #{remote_tar} -C "$BUILD_DIR"
    cd "$BUILD_DIR"
    #{mix_project_cd(manifest)}

    export MIX_ENV=prod
    export SECRET_KEY_BASE=buildtime_secret_key_base_32chars_min
    export TURSO_DATABASE_URL=libsql://build.turso.io
    export TURSO_AUTH_TOKEN=build_token

    log "Fetching dependencies"
    mix local.hex --force
    mix local.rebar --force
    mix deps.get --only prod

    log "Compiling application"
    mix compile

    log "Compiling assets"
    mix assets.setup
    mix assets.deploy

    log "Building release #{config.release_name} (slug=#{app.slug})"
    mix release --overwrite

    REL_DIR="_build/prod/rel/#{config.release_name}"
    if [[ ! -d "$REL_DIR" ]]; then
      echo "Release directory missing: $REL_DIR" >&2
      echo "Available releases:" >&2
      ls -la _build/prod/rel 2>/dev/null || true
      echo "Hint: set release_name in .cleat_deploy/deploy.json to the Mix app atom (see mix.exs app:)." >&2
      exit 1
    fi

    RELEASE_DIR="#{config.release_path}/releases/build"
    sudo mkdir -p "$RELEASE_DIR"
    sudo rm -rf "${RELEASE_DIR:?}"/*
    sudo cp -a "$REL_DIR/." "$RELEASE_DIR/"
    sudo ln -sfn "$RELEASE_DIR" #{config.release_path}/current

    #{ServerProvision.provision_script(app, config, manifest)}
    #{env_sync_script(app, config)}
    #{ServerProvision.migrate_script(config)}

    log "Restarting #{config.systemd_unit}"
    sudo systemctl restart #{config.systemd_unit}
    sleep 2

    if sudo systemctl is-active --quiet #{config.systemd_unit}; then
      log "Service #{config.systemd_unit} is active"
    else
      sudo journalctl -u #{config.systemd_unit} -n 30 --no-pager
      exit 1
    fi

    #{ServerProvision.reload_caddy_script()}
    """
  end

  defp mix_project_cd(%AppManifest{build_dir: dir}) when is_binary(dir) and dir != "" do
    """
    log "Using mix project in #{dir}"
    cd #{dir}
    """
  end

  defp mix_project_cd(%AppManifest{}) do
    """
    if [[ ! -f mix.exs ]]; then
      nested=$(find . -maxdepth 2 -name mix.exs | head -1)
      if [[ -n "$nested" ]]; then
        log "Using mix project in $(dirname "$nested")"
        cd "$(dirname "$nested")"
      fi
    fi
    """
  end

  defp github_clone_url(repo) do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        "https://x-access-token:#{token}@github.com/#{repo}.git"

      _ ->
        "https://github.com/#{repo}.git"
    end
  end

  defp short_sha("manual"), do: Integer.to_string(System.system_time(:second))
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)

  defp tar_exclude_args do
    Enum.flat_map(@tar_excludes, fn entry -> ["--exclude", entry] end)
  end

  defp log_ssh_base(key_path, target) do
    [
      "-i",
      key_path,
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=8",
      target
    ]
  end

  defp ssh_base(key_path, target) do
    [
      "-i",
      key_path,
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "BatchMode=yes",
      "-o",
      "ServerAliveInterval=30",
      "-o",
      "ServerAliveCountMax=120",
      target
    ]
  end

  defp scp_base(key_path) do
    [
      "-i",
      key_path,
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "BatchMode=yes",
      "-o",
      "ServerAliveInterval=30",
      "-o",
      "ServerAliveCountMax=120"
    ]
  end

  defp cmd(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, output}
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""
end
