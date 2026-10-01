defmodule CleatDeploy.Apps.EnvApply do
  @moduledoc """
  Writes the panel env file onto the server and restarts units that are already
  active, so `env_set` takes effect without a deploy.

  Hibernated units stay down: the file is updated and they pick it up on wake.
  Static apps have no unit. Vars scoped to a branch other than the running
  deploy are stored only; they apply on the next deploy of that branch.
  """

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Apps.AppEnvVar
  alias CleatDeploy.Deploy.Ssh

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
    #{restart_active(App.unit_names(app))}
    """
    |> String.trim()
  end

  defp restart_active(units) do
    Enum.map_join(units, "\n", fn unit ->
      quoted = sh_quote(unit)

      """
      if systemctl is-active --quiet #{quoted}; then
        sudo systemctl restart #{quoted}
      fi
      """
    end)
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
