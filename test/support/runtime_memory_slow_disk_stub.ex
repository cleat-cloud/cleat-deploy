defmodule CleatDeploy.Apps.RuntimeMemorySlowDiskStub do
  @moduledoc false
  @behaviour CleatDeploy.Apps.RuntimeMemory

  # Sleeps only when the remote command walks disk, so tests can prove live
  # systemd/ps stats arrive without waiting for `du`.
  @impl true
  def run(app, argv) do
    if disk_walk?(argv), do: Process.sleep(1_200)
    CleatDeploy.Apps.RuntimeMemoryStub.run(app, argv)
  end

  defp disk_walk?(["bash", "-c", script]) when is_binary(script),
    do: String.contains?(script, "du -sb")

  defp disk_walk?(_), do: false
end
