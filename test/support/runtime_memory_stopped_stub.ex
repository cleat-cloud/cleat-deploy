defmodule CleatDeploy.Apps.RuntimeMemoryStoppedStub do
  @moduledoc false
  @behaviour CleatDeploy.Apps.RuntimeMemory

  # Mimics a hibernated app: a unit whose name contains "sleep" is stopped while
  # its `-worker` unit keeps running.
  @impl true
  def run(_app, ["bash", "-c", script] = _argv) do
    units = extract_units(script)
    paths = extract_paths(script)

    show = Enum.map_join(units, "\n\n", &unit_block/1)
    ps = Enum.map_join(units, "\n", &ps_line/1)
    du = Enum.map_join(paths, "\n", &du_line/1)

    {:ok, show <> "\n__PAAS_PS__\n" <> ps <> "\n__PAAS_DU__\n" <> du}
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
    {bytes, state} =
      cond do
        String.ends_with?(unit, "-worker") -> {10_416_128, "active"}
        String.contains?(unit, "sleep") -> {0, "inactive"}
        true -> {171_200_512, "active"}
      end

    """
    Id=#{unit}.service
    MemoryCurrent=#{bytes}
    MemoryPeak=#{bytes}
    ActiveState=#{state}
    """
  end

  defp ps_line(unit) do
    cpu = if String.ends_with?(unit, "-worker"), do: "1.7", else: "0.0"
    " #{cpu} #{unit}.service"
  end

  defp du_line(path) do
    "39009698\t#{path}"
  end
end
