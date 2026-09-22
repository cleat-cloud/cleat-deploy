defmodule CleatDeploy.Apps.RuntimeControl do
  @moduledoc """
  Manual stop/start of an app's systemd unit (hibernate / wake up).

  Hibernating only kills the process: the release, the persistent data dir and
  the Caddy site stay exactly where they are, so nothing has to be built or
  downloaded to bring the app back — it is the same `systemctl stop` the idle
  sweeper uses. Memory and CPU drop to zero while the app is down; an app armed
  for wake-on-request comes back on the next request, and one that is not armed
  comes back through `wake/1` (or the next deploy).
  """

  alias CleatDeploy.Apps.App

  @callback run(App.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}

  @doc "Stops the app's unit without touching anything on disk."
  def hibernate(%App{} = app) do
    run_action(app, &stop_script/1, "inactive")
  end

  @doc "Starts the app's unit again after a hibernate (or after an idle stop)."
  def wake(%App{} = app) do
    run_action(app, &start_script/1, "active")
  end

  @doc "Shell command that stops `unit` and reports the resulting state."
  def stop_script(unit) when is_binary(unit), do: script("stop", unit)

  @doc "Shell command that starts `unit` and reports the resulting state."
  def start_script(unit) when is_binary(unit), do: script("start", unit)

  @doc """
  How a hibernated app comes back, for the confirmation dialogs.

  Wording lives here so the app page and the apps list tell the same story.
  """
  def wake_hint(%App{} = app) do
    if App.wake_armed?(app) do
      "It is armed for wake-on-request, so the next request starts it again automatically."
    else
      "It only comes back with the Wake up button or on the next deploy."
    end
  end

  defp script(action, unit) do
    """
    sudo systemctl #{action} #{sh_quote(unit)}
    printf 'state=%s\\n' "$(systemctl is-active #{sh_quote(unit)} 2>/dev/null || echo unknown)"
    """
    |> String.trim()
  end

  defp run_action(%App{} = app, script_fun, expected_state) do
    case App.unit_name(app) do
      unit when is_binary(unit) -> perform(app, unit, script_fun, expected_state)
      _unit -> {:error, "app has no systemd unit to control"}
    end
  end

  defp perform(app, unit, script_fun, expected_state) do
    case client().run(app, ["bash", "-c", script_fun.(unit)]) do
      {:ok, output} ->
        case state(output) do
          ^expected_state -> :ok
          other -> {:error, "unit #{unit} is #{other}"}
        end

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  # `systemctl stop` can fail (missing unit, no sudo) and the script still exits
  # 0, so the reported state is what decides.
  defp state(output) when is_binary(output) do
    case Regex.run(~r/^state=(.+)$/m, output) do
      [_, value] -> String.trim(value)
      _ -> "unknown"
    end
  end

  defp state(_output), do: "unknown"

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
