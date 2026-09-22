defmodule CleatDeploy.Apps.IdleShutdown do
  @moduledoc """
  Stops apps that have not served a request for the configured idle window.

  The wake agent (`CleatDeploy.Deploy.Wake`) refreshes `<unit>.stamp` on every
  request that Caddy proxies. That stamp only exists for apps whose last deploy
  armed wake-on-request, so an app without one is never stopped — the sweeper
  would otherwise park an app that nothing can wake.

  Idle time is measured on the server (`date +%s` minus the stamp mtime) so the
  panel clock never enters the decision.
  """

  require Logger

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.Wake

  @report_marker "CLEAT"
  @ssh_timeout_ms 20_000

  @callback run(App.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Stops the apps among `apps` whose last access is older than `timeout_minutes`.

  Returns `%{stopped: [slug], skipped: [slug]}`.
  """
  def sweep(apps, timeout_minutes) when is_list(apps) and is_integer(timeout_minutes) do
    apps
    |> Enum.filter(& &1.server)
    |> Enum.group_by(& &1.server_id)
    |> Map.values()
    |> Task.async_stream(&sweep_server(&1, timeout_minutes),
      timeout: @ssh_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{stopped: [], skipped: []}, fn
      {:ok, result}, acc ->
        %{stopped: acc.stopped ++ result.stopped, skipped: acc.skipped ++ result.skipped}

      _other, acc ->
        acc
    end)
  end

  @doc "One shell command reporting `unit`, idle seconds and systemd state."
  def report_script(apps) when is_list(apps) do
    units = apps |> Enum.map(&unit/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    """
    set +e
    NOW=$(date +%s)
    for UNIT in #{Enum.map_join(units, " ", &sh_quote/1)}; do
      STAMP="#{Wake.stamp_dir()}/${UNIT}.stamp"
      if [ -f "$STAMP" ]; then IDLE=$((NOW - $(stat -c %Y "$STAMP"))); else IDLE=-1; fi
      STATE=$(systemctl is-active "$UNIT" 2>/dev/null || echo inactive)
      printf '#{@report_marker} %s %s %s\\n' "$UNIT" "$IDLE" "$STATE"
    done
    """
    |> String.trim()
  end

  def stop_script(units) when is_list(units) do
    "sudo systemctl stop #{Enum.map_join(units, " ", &sh_quote/1)}"
  end

  @doc "Parses the `report_script/1` output into `%{unit => %{idle_seconds, state}}`."
  def parse_report(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(String.trim(line), " ", parts: 4) do
        [@report_marker, unit, idle, state] ->
          Map.put(acc, unit, %{idle_seconds: to_integer(idle), state: state})

        _ ->
          acc
      end
    end)
  end

  @doc """
  Whether an app should be stopped: active in systemd and idle for at least
  `timeout_minutes`. A missing stamp (`idle_seconds: -1`) is never due.
  """
  def due?(%{idle_seconds: idle, state: state}, timeout_minutes)
      when is_integer(idle) and is_integer(timeout_minutes) do
    state == "active" and idle >= 0 and idle >= timeout_minutes * 60
  end

  def due?(_entry, _timeout_minutes), do: false

  def unit(%App{} = app), do: App.unit_name(app)

  defp sweep_server(apps, timeout_minutes) do
    [%App{} = subject | _] = apps

    case client().run(subject, ["bash", "-c", report_script(apps)]) do
      {:ok, output} ->
        report = parse_report(output)

        {due, skipped} =
          Enum.split_with(apps, fn app -> due?(Map.get(report, unit(app)), timeout_minutes) end)

        {stopped, failed} = stop_all(subject, due)

        %{stopped: stopped, skipped: Enum.map(skipped, & &1.slug) ++ failed}

      {:error, reason} ->
        Logger.warning(
          "idle_shutdown report failed on server #{subject.server_id}: #{format_error(reason)}"
        )

        %{stopped: [], skipped: Enum.map(apps, & &1.slug)}
    end
  end

  defp stop_all(_subject, []), do: {[], []}

  defp stop_all(subject, apps) do
    units = Enum.map(apps, &unit/1)

    case client().run(subject, ["bash", "-c", stop_script(units)]) do
      {:ok, _output} ->
        Enum.each(apps, fn app ->
          Logger.info("idle_shutdown stopping #{app.slug} (unit #{unit(app)})")
        end)

        {Enum.map(apps, & &1.slug), []}

      {:error, reason} ->
        Logger.warning(
          "idle_shutdown stop failed on server #{subject.server_id}: #{format_error(reason)}"
        )

        {[], Enum.map(apps, & &1.slug)}
    end
  end

  defp client do
    Application.get_env(
      :cleat_deploy,
      :idle_shutdown_runner,
      CleatDeploy.Apps.IdleShutdownSsh
    )
  end

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_integer(_value), do: nil

  defp format_error(reason) when is_binary(reason), do: String.trim(reason)
  defp format_error(reason), do: inspect(reason)

  defp sh_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
