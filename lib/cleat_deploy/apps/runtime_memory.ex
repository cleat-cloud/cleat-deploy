defmodule CleatDeploy.Apps.RuntimeMemory do
  @moduledoc """
  Reads systemd cgroup memory, CPU, and disk use for registered apps.
  """

  require Logger

  alias CleatDeploy.Apps.App

  @unit_pattern ~r/^[A-Za-z0-9:_.@-]+$/
  @path_pattern ~r"^/(opt|var/lib)/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$"
  @unset_memory 18_446_744_073_709_551_615
  @ssh_timeout_ms 15_000

  @callback run(App.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}

  def for_app(%App{} = app), do: Map.get(for_apps([app]), app.id)

  @doc """
  Runs the probe in a background task and sends `{:app_memory, ref, result}` to
  `pid`.

  The probe SSHes into the server and can take seconds, so a LiveView must never
  run it inline: doing that blocks every other event (buttons, filters) until the
  SSH call returns.
  """
  def probe_async(pid, ref, subject) when is_pid(pid) do
    Task.start(fn -> send(pid, {:app_memory, ref, probe(subject)}) end)
  end

  defp probe(%App{} = app), do: for_app(app)
  defp probe(apps) when is_list(apps), do: for_apps(apps)

  def for_apps(apps) when is_list(apps) do
    apps
    |> Enum.filter(& &1.server)
    |> Enum.group_by(& &1.server_id)
    |> Map.values()
    |> Task.async_stream(&fetch_server/1,
      timeout: @ssh_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, map}, acc when is_map(map) -> Map.merge(acc, map)
      _, acc -> acc
    end)
  end

  def format(%{bytes: bytes}) when is_integer(bytes) and bytes >= 0, do: format_bytes(bytes)
  def format(_), do: "—"

  def format_peak(%{peak_bytes: bytes}) when is_integer(bytes) and bytes >= 0,
    do: "Peak #{format_bytes(bytes)}"

  def format_peak(_), do: nil

  def format_cpu(%{cpu_pct: pct}) when is_number(pct) and pct >= 0,
    do: :erlang.float_to_binary(pct / 1, decimals: 1) <> "%"

  def format_cpu(_), do: "—"

  def format_disk(%{disk_bytes: bytes}) when is_integer(bytes) and bytes >= 0,
    do: format_bytes(bytes)

  def format_disk(_), do: "—"

  @doc """
  Live systemd state of the app's unit(s).

  `Stopped` is how a slept app shows up (the sweeper stops the unit); a crashed
  one is usually restarting instead of stopped.
  """
  def format_status(%{active?: true}), do: "Active"
  def format_status(%{active?: false}), do: "Stopped"
  def format_status(_), do: "—"

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576,
    do: "#{div(bytes, 1024)} KB"

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824 do
    :erlang.float_to_binary(bytes / 1_073_741_824, decimals: 1) <> " GB"
  end

  def format_bytes(bytes) when is_integer(bytes) do
    mb = bytes / 1_048_576

    if mb < 10 do
      :erlang.float_to_binary(mb, decimals: 1) <> " MB"
    else
      "#{round(mb)} MB"
    end
  end

  defp fetch_server([]), do: %{}

  defp fetch_server([%App{} = app | _] = apps) do
    units =
      apps
      |> Enum.flat_map(&units/1)
      |> Enum.filter(&valid_unit?/1)
      |> Enum.uniq()

    paths =
      apps
      |> Enum.flat_map(&disk_paths/1)
      |> Enum.filter(&valid_path?/1)
      |> Enum.uniq()

    if units == [] do
      %{}
    else
      case client().run(app, stats_argv(units, paths)) do
        {:ok, output} ->
          parsed = parse_output(output)

          Map.new(apps, fn item ->
            {item.id, combine(item, parsed)}
          end)

        {:error, reason} ->
          Logger.warning("runtime stats fetch failed for #{app.slug}: #{format_error(reason)}")
          %{}
      end
    end
  end

  defp client do
    Application.get_env(
      :cleat_deploy,
      :runtime_memory,
      CleatDeploy.Apps.RuntimeLogsSsh
    )
  end

  # The base unit (HTTP process) plus one per extra process; `combine/2` reads
  # liveness from the base unit only.
  defp units(%App{} = app), do: App.unit_names(app)

  defp disk_paths(%App{} = app) do
    release = app.release_path || App.default_release_path(app.slug, app.runtime || "phoenix")
    data = data_dir(app, release)
    prefix = String.trim_trailing(release, "/") <> "/"

    if String.starts_with?(data, prefix) do
      [release]
    else
      [release, data]
    end
  end

  defp data_dir(%App{runtime: "golang"}, release), do: Path.join(release, "data")
  defp data_dir(_app, release), do: "/var/lib/#{Path.basename(release)}"

  defp valid_unit?(unit) when is_binary(unit),
    do: unit != "" and Regex.match?(@unit_pattern, unit)

  defp valid_unit?(_), do: false

  defp valid_path?(path) when is_binary(path), do: Regex.match?(@path_pattern, path)
  defp valid_path?(_), do: false

  defp stats_argv(units, paths) do
    show =
      "sudo systemctl show #{join_escaped(units)} -p Id -p MemoryCurrent -p MemoryPeak -p ActiveState"

    du =
      if paths == [] do
        "true"
      else
        "timeout 12s sudo du -sb #{join_escaped(paths)} 2>/dev/null"
      end

    script = """
    set +e
    #{show}
    printf '%s\\n' '__PAAS_PS__'
    ps -eo pcpu=,unit= --no-headers 2>/dev/null
    printf '%s\\n' '__PAAS_DU__'
    #{du}
    :
    """

    ["bash", "-c", script]
  end

  defp join_escaped(values), do: Enum.map_join(values, " ", &shell_escape/1)

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp parse_output(output) when is_binary(output) do
    {show, rest} = split_marker(output, "__PAAS_PS__")
    {ps, du} = split_marker(rest, "__PAAS_DU__")

    %{
      by_unit: parse_show_output(show),
      cpu_by_unit: parse_ps(ps),
      disk_by_path: parse_du(du)
    }
  end

  defp split_marker(text, marker) do
    case String.split(text, marker, parts: 2) do
      [left] -> {left, ""}
      [left, right] -> {left, right}
    end
  end

  defp parse_show_output(output) when is_binary(output) do
    output
    |> String.split(~r/\n{2,}/)
    |> Enum.map(&parse_block/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp parse_block(block) do
    props =
      block
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(String.trim(line), "=", parts: 2) do
          [key, value] when key != "" -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    case normalize_unit(Map.get(props, "Id", "")) do
      "" ->
        nil

      unit ->
        {unit,
         %{
           bytes: parse_bytes(Map.get(props, "MemoryCurrent")),
           peak_bytes: parse_bytes(Map.get(props, "MemoryPeak")),
           active?: Map.get(props, "ActiveState") == "active"
         }}
    end
  end

  defp parse_ps(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^\s*([0-9]+(?:\.[0-9]+)?)\s+(\S+)\s*$/, line) do
        [_, pct, unit] ->
          case Float.parse(pct) do
            {cpu, ""} ->
              key = normalize_unit(unit)
              Map.update(acc, key, cpu, &(&1 + cpu))

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  defp parse_du(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(String.trim(line), "\t", parts: 2) do
        [bytes, path] ->
          case parse_bytes(bytes) do
            n when is_integer(n) -> Map.put(acc, String.trim_trailing(path, "/"), n)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp normalize_unit(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace_suffix(".service", "")
  end

  defp parse_bytes(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n < @unset_memory -> n
      _ -> nil
    end
  end

  defp parse_bytes(_), do: nil

  defp combine(%App{} = app, parsed) do
    parts =
      app
      |> units()
      |> Enum.map(&Map.get(parsed.by_unit, &1))
      |> Enum.reject(&is_nil/1)

    bytes = parts |> Enum.map(& &1.bytes) |> Enum.reject(&is_nil/1)
    peaks = parts |> Enum.map(& &1.peak_bytes) |> Enum.reject(&is_nil/1)

    cpu =
      app
      |> units()
      |> Enum.map(&Map.get(parsed.cpu_by_unit, &1))
      |> Enum.reject(&is_nil/1)

    disk =
      app
      |> disk_paths()
      |> Enum.map(&Map.get(parsed.disk_by_path, String.trim_trailing(&1, "/")))
      |> Enum.reject(&is_nil/1)

    if bytes == [] and cpu == [] and disk == [] do
      nil
    else
      %{
        bytes: if(bytes == [], do: nil, else: Enum.sum(bytes)),
        peak_bytes: if(peaks == [], do: nil, else: Enum.sum(peaks)),
        cpu_pct: if(cpu == [], do: nil, else: Float.round(Enum.sum(cpu), 1)),
        disk_bytes: if(disk == [], do: nil, else: Enum.sum(disk)),
        active?: main_unit_active?(app, parsed)
      }
    end
  end

  # Whether the unit the panel starts and stops is running. A Go app keeps its
  # `-worker` unit alive while hibernating, so "any unit active" would report a
  # sleeping app as On and never offer the Wake up button.
  defp main_unit_active?(%App{} = app, parsed) do
    case app |> units() |> List.first() |> then(&Map.get(parsed.by_unit, &1)) do
      %{active?: active?} -> active?
      _ -> false
    end
  end

  defp format_error(reason) when is_binary(reason), do: String.trim(reason)
  defp format_error(reason), do: inspect(reason)
end
