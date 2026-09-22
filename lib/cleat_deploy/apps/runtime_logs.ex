defmodule CleatDeploy.Apps.RuntimeLogs do
  @moduledoc """
  Fetches recent systemd journal lines for a registered app.
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Repo
  alias CleatDeploy.Servers.Server

  @line_count 200
  @unit_pattern ~r/^[A-Za-z0-9:_.@-]+$/

  @callback run(App.t() | Server.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}

  def fetch(%App{} = app) do
    app = Repo.preload(app, :server)
    unit = unit_name(app)

    with :ok <- validate_unit(unit) do
      case client().run(app, journalctl_argv(unit)) do
        {:ok, output} ->
          {:ok,
           %{
             unit: unit,
             lines: split_lines(output),
             fetched_at: DateTime.utc_now(:second)
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  @doc """
  Runs `fetch/1` in a background task and sends `{:app_logs, ref, result}` to
  `pid`.

  Reading the journal goes over SSH, so a LiveView must not wait for it inline:
  that blocks every other event on the page until the call returns.
  """
  def probe_async(pid, ref, %App{} = app) when is_pid(pid) do
    Task.start(fn -> send(pid, {:app_logs, ref, fetch(app)}) end)
  end

  def line_count, do: @line_count

  defp client do
    Application.get_env(:cleat_deploy, :runtime_logs, CleatDeploy.Apps.RuntimeLogsSsh)
  end

  defp unit_name(%App{} = app) do
    app.systemd_unit || App.default_systemd_unit(app.slug, app.runtime || "phoenix")
  end

  defp validate_unit(unit) when is_binary(unit) do
    if unit != "" and Regex.match?(@unit_pattern, unit) do
      :ok
    else
      {:error, "Invalid systemd unit on this app"}
    end
  end

  defp validate_unit(_), do: {:error, "Invalid systemd unit on this app"}

  defp journalctl_argv(unit) do
    [
      "sudo",
      "journalctl",
      "-u",
      unit,
      "-n",
      Integer.to_string(@line_count),
      "--no-pager",
      "-o",
      "short-iso",
      "--utc"
    ]
  end

  defp split_lines(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_error(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    cond do
      trimmed == "" -> "Could not read logs from the VM"
      String.length(trimmed) > 400 -> String.slice(trimmed, 0, 400) <> "…"
      true -> trimmed
    end
  end

  defp format_error(reason), do: "Could not read logs from the VM (#{inspect(reason)})"
end
