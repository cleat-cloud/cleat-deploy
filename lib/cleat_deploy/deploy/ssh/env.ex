defmodule CleatDeploy.Deploy.Ssh.Env do
  @moduledoc false

  alias CleatDeploy.Apps
  alias CleatDeploy.Deploy.Ssh.Session

  @exec_py File.read!(Path.expand("../../../../priv/scripts/cleat_env_exec.py", __DIR__))

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

  @doc """
  systemd EnvironmentFile body. Values are always double-quoted so spaces and
  shell metacharacters stay literal; systemd strips the quotes and does not
  expand `$()`, backticks or `$HOME`.
  """
  def format_env_file(env_map) when is_map(env_map) do
    env_map
    |> Enum.sort()
    |> Enum.map_join("\n", &format_pair/1)
    |> then(&(&1 <> "\n"))
  end

  defp format_pair({key, value}) when is_binary(key) and is_binary(value) do
    unless Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) do
      raise ArgumentError, "invalid env key: #{inspect(key)}"
    end

    if String.contains?(value, <<0>>) do
      raise ArgumentError, "env value for #{key} contains NUL"
    end

    "#{key}=#{systemd_quote(value)}"
  end

  defp systemd_quote(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"#{escaped}\""
  end

  def exec_script_path do
    Path.expand("../../../../priv/scripts/cleat_env_exec.py", __DIR__)
  end

  @doc """
  Remote snippet: load `env_file` literally and exec `argv` as root.

  Does not `source` the file. Values with `$()`, backticks and quotes stay
  data. Extra keys (`:extra_env`) and `:chdir` are applied after the file.
  """
  def exec_with_env(env_file, argv, opts \\ [])
      when is_binary(env_file) and is_list(argv) do
    chdir = Keyword.get(opts, :chdir)
    extra = Keyword.get(opts, :extra_env, %{})

    flags =
      []
      |> maybe_flag("--chdir", chdir)
      |> Kernel.++(Enum.flat_map(extra, fn {key, value} -> ["--set", "#{key}=#{value}"] end))
      |> Kernel.++([env_file | Enum.map(argv, &to_string/1)])
      |> Enum.map(&Session.shell_escape/1)
      |> Enum.join(" ")

    """
    sudo python3 - #{flags} <<'CLEAT_ENV_EXEC_PY'
    #{String.trim_trailing(@exec_py)}
    CLEAT_ENV_EXEC_PY
    """
    |> String.trim()
  end

  @doc """
  `eval` of `export KEY='literal'` lines from an EnvironmentFile.

  `file_arg` is a shell token (`'/etc/app/env'` or `"$TMP_ENV"`). Used when
  the caller must keep running in the same bash (functions like `run_rails`).
  """
  def print_exports_eval(file_arg) when is_binary(file_arg) do
    """
    eval "$(python3 - --print-exports #{file_arg} <<'CLEAT_ENV_EXEC_PY'
    #{String.trim_trailing(@exec_py)}
    CLEAT_ENV_EXEC_PY
    )"
    """
    |> String.trim()
  end

  defp maybe_flag(flags, _name, nil), do: flags
  defp maybe_flag(flags, name, value), do: flags ++ [name, value]

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
