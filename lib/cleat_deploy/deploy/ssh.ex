defmodule CleatDeploy.Deploy.Ssh do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Golang
  alias CleatDeploy.Deploy.Node
  alias CleatDeploy.Deploy.Rails
  alias CleatDeploy.Deploy.Runtime
  alias CleatDeploy.Deploy.Rust
  alias CleatDeploy.Deploy.Static
  alias CleatDeploy.Repo
  alias CleatDeploy.Deploy.Ssh.{Env, Phoenix, Session}

  @tar_excludes ~w(_build deps node_modules .git tmp priv/static/assets target)

  def cleanup_stale_identity_files, do: Session.cleanup_stale_identity_files()

  @doc """
  Best-effort `pkill` of the remote build directory for this deployment SHA.
  """
  def interrupt_build(server, app, deployment) when not is_nil(server) do
    sha =
      case deployment.git_sha do
        sha when is_binary(sha) and sha != "" -> String.slice(sha, 0, 7)
        _ -> nil
      end

    if is_nil(sha) do
      :ok
    else
      pattern = "cleat_deploy_build_#{sha}"
      _ = run(server, app, ["bash", "-lc", "pkill -f #{shell_escape(pattern)} || true"])
      :ok
    end
  end

  def interrupt_build(_server, _app, _deployment), do: :ok

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
    branch = deployment.git_ref || app.branch
    config = app |> CleatDeploy.Apps.App.deploy_config() |> Map.put(:branch, branch)
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
                 :ok <- record_manifest(app, work_dir),
                 config <- config_with_addons(app, config, work_dir),
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

  # The panel has no repo of its own, so the deploy is the only moment where the
  # manifest is known: remember which extra units and addons it declared.
  defp record_manifest(%App{} = app, work_dir) do
    manifest = AppManifest.resolve(work_dir, app)

    _ =
      CleatDeploy.Apps.record_deploy_manifest(app, %{
        units: AppManifest.extra_units(manifest),
        addons: AppManifest.addons(manifest),
        wake: CleatDeploy.Deploy.Wake.enabled?(app, manifest),
        release_name: manifest.release_name
      })

    :ok
  end

  # Addons (managed Postgres/Redis) need their credentials before the env file is
  # built, so they are resolved here and threaded through the runtime config for
  # the provision script.
  defp config_with_addons(%App{} = app, config, work_dir) do
    manifest = AppManifest.resolve(work_dir, app)
    {addons, credentials} = CleatDeploy.Deploy.Addons.ensure(app, manifest)

    Map.merge(config, %{addons: addons, addon_credentials: credentials})
  end

  defp target_log(stored_ip, host_ip, app_host) when stored_ip == host_ip do
    "==> Deploy target #{host_ip} (#{app_host})"
  end

  defp target_log(stored_ip, host_ip, app_host) do
    "==> Corrected deploy target #{stored_ip} -> #{host_ip} (DNS #{app_host})"
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
          "==> Cloning #{app.github_repo} (branch #{config.branch})",
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
    config = app |> CleatDeploy.Apps.App.deploy_config() |> Map.put(:branch, app.branch)
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

  defdelegate env_sync_enabled?(app), to: Env
  defdelegate env_file_content(app), to: Env
  defdelegate env_file_content(app, branch), to: Env
  defdelegate env_sync_script(app, config), to: Env

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

      manifest.runtime == "rust" or Runtime.kind(work_dir, app) == :rust ->
        Rust.remote_build_script(server, app, config, sha, remote_tar, manifest)

      Runtime.kind(work_dir, app) == :golang or manifest.runtime == "golang" ->
        Golang.remote_build_script(server, app, config, sha, remote_tar, manifest)

      true ->
        Phoenix.phoenix_remote_build_script(
          server,
          app,
          config,
          sha,
          remote_tar,
          runtime,
          manifest
        )
    end
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

  defp ensure_commands(commands), do: Session.ensure_commands(commands)
  defp write_temp_key(server), do: Session.write_temp_key(server)
  defp temp_path(prefix), do: Session.temp_path(prefix)
  defp cmd(command, args), do: Session.cmd(command, args)
  defp trim(value), do: Session.trim(value)
  defp shell_escape(value), do: Session.shell_escape(value)
  defp ssh_base(key_path, target), do: Session.ssh_base(key_path, target)
  defp scp_base(key_path), do: Session.scp_base(key_path)
  defp log_ssh_base(key_path, target), do: Session.log_ssh_base(key_path, target)

  defp clone_repo(github_repo, branch) do
    dir = temp_path("cleat_deploy_clone")
    _ = File.rm_rf(dir)
    url = github_clone_url(github_repo)

    case cmd("git", ["clone", "--depth", "50", "-b", branch, url, dir]) do
      {:ok, _output} -> {:ok, dir}
      {:error, output} -> {:error, "git clone failed:\n" <> output}
    end
  end

  defp create_tarball(work_dir) do
    path = temp_path("cleat_deploy_src") <> ".tar.gz"
    _ = File.rm(path)
    args = ["-czf", path] ++ tar_exclude_args() ++ ["-C", work_dir, "."]

    case cmd("tar", args) do
      {:ok, _output} -> {:ok, path}
      {:error, output} -> {:error, "tar failed:\n" <> output}
    end
  end

  defp tar_exclude_args do
    Enum.flat_map(@tar_excludes, fn entry -> ["--exclude", entry] end)
  end
end
