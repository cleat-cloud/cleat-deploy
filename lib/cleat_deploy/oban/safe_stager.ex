defmodule CleatDeploy.Oban.SafeStager do
  @moduledoc false

  # Oban's Stager runs Engine.stage_jobs inside a transaction. Turso/libSQL
  # raises SQLITE_BUSY instead of waiting, that exception kills the GenServer,
  # and deploy jobs stay scheduled forever. This plugin retries the whole
  # transaction and, if it is still busy, waits for the next tick.

  @behaviour Oban.Plugin

  use GenServer

  alias CleatDeploy.Repo.BusyRetry
  alias Oban.{Engine, Job, Peer, Registry}

  require Logger

  @impl Oban.Plugin
  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)

    if conf.testing in [:inline, :manual] do
      :ignore
    else
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end
  end

  @impl Oban.Plugin
  def validate(_opts), do: :ok

  @impl GenServer
  def init(opts) do
    conf = Keyword.fetch!(opts, :conf)
    interval = Keyword.get(opts, :interval, conf.stage_interval)
    interval = if interval == :infinity, do: :timer.seconds(1), else: interval

    {:ok, schedule(%{conf: conf, interval: interval, timer: nil})}
  end

  @impl GenServer
  def handle_info(:stage, state) do
    _ = stage(state)
    {:noreply, schedule(state)}
  rescue
    error ->
      if BusyRetry.busy?(error) do
        Logger.warning("oban stager sqlite busy, retrying next tick")
        {:noreply, schedule(state)}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp stage(%{conf: conf} = state) do
    if Peer.leader?(conf) do
      BusyRetry.call(fn ->
        Oban.Repo.transaction(
          conf,
          fn ->
            {:ok, staged} = Engine.stage_jobs(conf, Job, limit: 5_000)
            notify(state)
            staged
          end,
          on_exhausted: :log
        )
      end)
    else
      notify(state)
    end
  end

  defp notify(%{conf: conf}) do
    match = [{{{conf.name, {:producer, :"$1"}}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}]

    for {queue, pid} <- Registry.select(match) do
      send(pid, {:notification, :insert, %{"queue" => queue}})
    end

    :ok
  rescue
    _ -> :ok
  end

  defp schedule(state) do
    %{state | timer: Process.send_after(self(), :stage, state.interval)}
  end
end
