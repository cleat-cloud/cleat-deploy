defmodule CleatDeploy.Apps.EnvApply do
  @moduledoc """
  Writes the panel env file onto the server and restarts units that are already
  active, so `env_set` takes effect without a deploy.

  Failed / start-limit-hit units are reset and started: a crash from bad env
  is not hibernate. Hibernated units (inactive with a wake stamp) stay down.
  Static apps have no unit. Vars scoped to a branch other than the running
  deploy are stored only; they apply on the next deploy of that branch.
  """

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Apps.AppEnvVar
  alias CleatDeploy.Deploy.Ssh
  alias CleatDeploy.Deploy.Wake

  def apply(app, changed_branch \\ nil)

  def apply(%App{runtime: "static"}, _branch), do: :ok

  def apply(%App{} = app, changed_branch) do
    if live_scope?(app, changed_branch), do: sync(app), else: :ok
  end

  defp live_scope?(_app, nil), do: true
  defp live_scope?(app, branch), do: AppEnvVar.applies_to?(branch, app.branch)

  defp sync(%App{} = app) do
    app = Apps.get_app!(app.id)

    case App.unit_name(app) do
      unit when is_binary(unit) -> run(app)
      _unit -> :ok
    end
  end

  defp run(app) do
    case client().run(app, ["bash", "-c", script(app)]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp script(app) do
    config = App.deploy_config(app)
    encoded = app |> Ssh.env_file_content(app.branch) |> Base.encode64()

    """
    sudo mkdir -p "$(dirname #{config.env_file})"
    echo '#{encoded}' | base64 -d | sudo tee #{config.env_file} > /dev/null
    sudo chmod 600 #{config.env_file}
    #{restart_units(app)}
    """
    |> String.trim()
  end

  defp restart_units(%App{} = app) do
    primary = App.unit_name(app)

    Enum.map_join(App.unit_names(app), "\n", fn unit ->
      http_port = if unit == primary, do: app.port
      restart_unit(unit, http_port)
    end)
  end

  defp restart_unit(unit, http_port) do
    quoted = sh_quote(unit)
    stamp = sh_quote(Wake.stamp_path(unit))
    wait = wait_for_unit(quoted, http_port)

    """
    if ! systemctl cat --quiet #{quoted} > /dev/null 2>&1; then
      : # unit not provisioned (stale manifest entry); nothing to restart
    elif systemctl is-active --quiet #{quoted}; then
      sudo systemctl restart #{quoted}
    elif systemctl is-failed --quiet #{quoted}; then
      sudo systemctl reset-failed #{quoted} || true
      sudo systemctl start #{quoted}
    #{wait}
    elif [ -f #{stamp} ]; then
      : # hibernated; env file updated, unit stays down
    else
      sudo systemctl reset-failed #{quoted} || true
      sudo systemctl start #{quoted}
    #{wait}
    fi
    """
  end

  # Mirror the golang deploy gate: is-active + NRestarts=0, and HTTP on the
  # web unit. Failed recovery must not return 200 with the process still down.
  defp wait_for_unit(quoted, http_port) do
    http_check =
      case http_port do
        port when is_integer(port) ->
          """
            code=$(curl -sS -o /dev/null --max-time 2 -w '%{http_code}' "http://127.0.0.1:#{port}/" || true)
            if [[ "$code" == "000" || -z "$code" ]]; then
              sleep 1
              continue
            fi
          """

        _ ->
          ""
      end

    """
      ready=0
      for i in $(seq 1 30); do
        if sudo systemctl is-active --quiet #{quoted}; then
          n=$(systemctl show #{quoted} -p NRestarts --value 2>/dev/null || echo 0)
          if [[ "${n:-0}" -ne 0 ]]; then
            sleep 1
            continue
          fi
    #{http_check}
          ready=1
          break
        fi
        sleep 1
      done
      if [[ "$ready" -ne 1 ]]; then
        sudo journalctl -u #{quoted} -n 30 --no-pager
        exit 1
      fi
    """
  end

  defp client do
    Application.get_env(
      :cleat_deploy,
      :runtime_control_runner,
      CleatDeploy.Apps.RuntimeControlSsh
    )
  end

  defp format_error(reason) when is_binary(reason), do: String.trim(reason)
  defp format_error(reason), do: inspect(reason)

  defp sh_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
