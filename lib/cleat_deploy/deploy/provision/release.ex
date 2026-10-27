defmodule CleatDeploy.Deploy.Provision.Release do
  @moduledoc """
  Release-phase scripts: migrations, release commands and release pruning.
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Provision.Shell
  alias CleatDeploy.Deploy.Ssh.Env

  @doc false
  def migrate_script(config) do
    release_bin = "#{config.release_path}/current/bin/#{config.release_name}"
    otp_app = config.release_name

    """
    if [[ -f #{config.env_file} ]]; then
      if [[ -x #{config.release_path}/current/bin/migrate ]]; then
        log "Running migrations (bin/migrate)"
        #{Env.exec_with_env(config.env_file, ["#{config.release_path}/current/bin/migrate"])}
      elif [[ -x #{release_bin} ]]; then
        log "Running migrations (release eval)"
        #{Env.exec_with_env(config.env_file, [release_bin, "eval", migration_eval(otp_app)])}
      else
        log "Skipping migrations (no migrate command)"
      fi
    else
      log "Skipping migrations (env file missing)"
    fi
    """
  end

  @doc """
  Runs the app's `release_command`s from `.cleat_deploy/deploy.json` against the
  release already published in `current/`, before the service is restarted.

  Loaded from the app env file (literal values, no shell `source`) and
  `CLEAT_DATA_DIR` (same environment the unit will get), streamed into the
  deploy log, and with a timeout per command. A
  non-zero exit aborts the deploy because the caller's script runs under
  `set -e` — the restart never happens and the previous process keeps serving.

  Returns `""` when the manifest declares no release command.
  """
  def release_command_script(%App{}, config, %AppManifest{} = manifest) do
    commands = AppManifest.release_commands(manifest)

    if commands == [] do
      ""
    else
      timeout = AppManifest.release_timeout_s(manifest)

      extra_env =
        runtime_env_map(manifest)
        |> Map.put("CLEAT_DATA_DIR", Shell.data_dir_for(manifest, config))

      chdir = "#{config.release_path}/current"
      total = length(commands)

      commands
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {command, index} ->
        release_command_step(command, index, total, config, extra_env, timeout, chdir)
      end)
      |> String.trim()
    end
  end

  @doc """
  Deletes legacy/orphan release directories under `release_path/releases`.

  Every runtime publishes to `releases/build` and the caller runs this right
  after pointing `current` at it, so anything else is stale (e.g. the old
  timestamped releases that used to fill the disk).
  """
  def prune_releases_script(release_path) do
    """
    sudo find #{Shell.shell_escape(release_path)}/releases -mindepth 1 -maxdepth 1 -type d ! -name build -exec rm -rf {} + 2>/dev/null || true
    """
    |> String.trim()
  end

  @doc """
  Keeps the active release plus the previous `keep - 1` ones for rollback.

  Runs after `current` points at the freshly activated release. The active
  target is filtered by path, never by age, so a rollback by hand cannot be
  pruned by mistake. Best-effort: failing to prune never fails the deploy.
  """
  def prune_releases_keep_script(release_path, keep \\ 5) do
    releases = Path.join(release_path, "releases")
    current = Path.join(release_path, "current")

    """
    (
      CURRENT_TARGET="$(readlink -f #{Shell.shell_escape(current)} 2>/dev/null || true)"
      ls -1dt #{Shell.shell_escape(releases)}/*/ 2>/dev/null | grep -vxF "$CURRENT_TARGET/" | tail -n +#{keep} | xargs -r sudo rm -rf
    ) || true
    """
    |> String.trim()
  end

  @doc """
  Empties a release directory before publishing into it.

  `rm -rf "$DIR"/*` does not match dotfiles, so a stale `.next`, `.output` or
  `.gitignore` from a previous release survives the copy. `find -mindepth 1
  -delete` removes everything, hidden entries included.
  """
  def clean_release_script(release_path) do
    """
    sudo mkdir -p #{Shell.shell_escape(release_path)}
    sudo find #{Shell.shell_escape(release_path)} -mindepth 1 -delete
    """
    |> String.trim()
  end

  @doc false
  def reload_caddy_script do
    """
    log "Reloading Caddy (TLS/DNS catch-up)"
    sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
    """
  end

  # The command is shipped base64-encoded (no quoting games) and echoed back
  # through the file, so the log shows exactly what ran.
  defp release_command_step(command, index, total, config, extra_env, timeout, chdir) do
    """
    echo '#{Base.encode64(command)}' | base64 -d | sudo tee /tmp/cleat_release_cmd.sh > /dev/null
    sudo chmod 700 /tmp/cleat_release_cmd.sh
    log "Running release command (#{index}/#{total}): $(sudo cat /tmp/cleat_release_cmd.sh)"
    #{Env.exec_with_env(config.env_file, ["timeout", to_string(timeout), "bash", "/tmp/cleat_release_cmd.sh"], chdir: chdir, extra_env: extra_env)}
    sudo rm -f /tmp/cleat_release_cmd.sh
    """
  end

  defp runtime_env_map(%AppManifest{runtime: "rails"}), do: %{"RAILS_ENV" => "production"}
  defp runtime_env_map(%AppManifest{runtime: "node"}), do: %{"NODE_ENV" => "production"}
  defp runtime_env_map(%AppManifest{runtime: "rust"}), do: %{"LOCO_ENV" => "production"}
  defp runtime_env_map(%AppManifest{}), do: %{}

  defp migration_eval(otp_app) when is_binary(otp_app) do
    """
    Application.load(:#{otp_app}); case Application.get_env(:#{otp_app}, :ecto_repos, []) do [] -> :ok; repos -> for repo <- repos, do: {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true)) end
    """
    |> String.trim()
  end
end
