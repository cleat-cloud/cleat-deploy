defmodule CleatDeploy.Deployments.Timing do
  @moduledoc """
  Deploy duration and its human-readable formatting.
  """

  alias CleatDeploy.Deployments.Deployment

  @doc """
  Returns deploy duration in seconds, or `nil` when not started or still queued.
  For running deployments, pass `now` (defaults to UTC now) to compute elapsed time.
  """
  def duration(%Deployment{} = deployment, now \\ DateTime.utc_now(:second)) do
    started = deployment.started_at

    cond do
      is_nil(started) ->
        nil

      deployment.status == :queued ->
        nil

      deployment.status == :running ->
        max(DateTime.diff(now, started, :second), 0)

      not is_nil(deployment.finished_at) ->
        max(DateTime.diff(deployment.finished_at, started, :second), 0)

      true ->
        nil
    end
  end

  def format_duration(nil), do: "—"

  def format_duration(seconds) when is_integer(seconds) and seconds >= 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 ->
        "#{hours}h #{minutes}m #{secs}s"

      minutes > 0 ->
        "#{minutes}m #{secs}s"

      true ->
        "#{secs}s"
    end
  end
end
