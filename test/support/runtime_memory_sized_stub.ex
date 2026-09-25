defmodule CleatDeploy.Apps.RuntimeMemorySizedStub do
  @moduledoc false
  @behaviour CleatDeploy.Apps.RuntimeMemory

  # Disk grows with the number in the release path (`/opt/app-3` -> 300 MB), so
  # the biggest app is not the alphabetically-first one. Lets tests prove the
  # metric sort ranks the whole filtered set before paginating.
  @impl true
  def run(_app, ["bash", "-c", script] = _argv) do
    units = extract_units(script)
    paths = extract_paths(script)

    show = Enum.map_join(units, "\n\n", &unit_block/1)
    ps = Enum.map_join(units, "\n", &ps_line/1)
    du = Enum.map_join(paths, "\n", &du_line/1)

    {:ok, show <> "\n__PAAS_PS__\n" <> ps <> "\n__PAAS_DU__\n" <> du}
  end

  defp du_line(path) do
    n =
      case Regex.run(~r/(\d+)\/?$/, path) do
        [_, digits] -> String.to_integer(digits)
        _ -> 1
      end

    "#{n * 100_000_000}\t#{path}"
  end

  defp extract_units(script) do
    case Regex.run(~r/systemctl show (.+) -p Id/, script) do
      [_, part] -> quoted_tokens(part)
      _ -> []
    end
  end

  defp extract_paths(script) do
    case Regex.run(~r/du -sb (.+) 2>/, script) do
      [_, part] -> quoted_tokens(part)
      _ -> []
    end
  end

  defp quoted_tokens(part) do
    Regex.scan(~r/'([^']+)'/, part)
    |> Enum.map(fn [_, token] -> token end)
  end

  defp unit_block(unit) do
    """
    Id=#{unit}.service
    MemoryCurrent=171200512
    MemoryPeak=187977728
    ActiveState=active
    """
  end

  defp ps_line(unit), do: " 2.8 #{unit}.service"
end
