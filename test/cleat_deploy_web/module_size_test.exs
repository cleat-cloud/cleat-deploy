defmodule CleatDeployWeb.ModuleSizeTest do
  @moduledoc """
  Guards issue #100: LiveView/component modules stay small enough to edit
  without paging the file. `~400` is the comfort ceiling from the issue.
  """

  use ExUnit.Case, async: true

  @max_lines 400

  @seeds [
    "lib/cleat_deploy_web/live/app_live/index.ex",
    "lib/cleat_deploy_web/live/app_live/show.ex",
    "lib/cleat_deploy_web/live/app_live/layout.ex",
    "lib/cleat_deploy_web/components/paas_components.ex",
    "lib/cleat_deploy_web/live/server_live/index.ex",
    "lib/cleat_deploy/deploy/ssh.ex"
  ]

  test "split LiveView and component modules stay under #{@max_lines} lines" do
    files = @seeds |> Enum.flat_map(&related_files/1) |> Enum.uniq() |> Enum.sort()

    assert files != [], "expected to find the LiveView/component sources to size-check"

    over =
      Enum.flat_map(files, fn path ->
        count = path |> File.stream!() |> Enum.count()
        if count > @max_lines, do: [{path, count}], else: []
      end)

    assert over == [],
           Enum.map_join(over, "\n", fn {path, count} ->
             "#{path} has #{count} lines (max #{@max_lines})"
           end)
  end

  defp related_files(seed) do
    dir = Path.rootname(seed)
    [seed | Path.wildcard(Path.join(dir, "**/*.ex"))]
  end
end
