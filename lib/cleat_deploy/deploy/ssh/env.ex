defmodule CleatDeploy.Deploy.Ssh.Env do
  @moduledoc false

  alias CleatDeploy.Apps

  @doc false
  def env_sync_enabled?(%{env_vars: vars}) when is_list(vars), do: vars != []
  def env_sync_enabled?(_), do: false

  @doc """
  Contents of the env file for a deploy.

  Env vars are scoped to a branch: everything written for all branches plus the
  variables of the branch being deployed.
  """
  def env_file_content(app, branch \\ nil) do
    app
    |> Apps.env_map(branch)
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
      content_b64 =
        app
        |> env_file_content(config[:branch] || app.branch)
        |> Base.encode64()

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
end
