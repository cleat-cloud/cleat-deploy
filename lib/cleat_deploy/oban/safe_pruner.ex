defmodule CleatDeploy.Oban.SafePruner do
  @moduledoc false

  # Oban's Pruner deletes completed jobs inside a transaction. Turso/libSQL
  # raises SQLITE_BUSY instead of waiting, which kills the plugin GenServer.
  # This plugin retries the transaction and, if it is still busy, waits for
  # the next tick.

  @behaviour Oban.Plugin

  use GenServer

  alias CleatDeploy.Repo.BusyRetry
  alias Oban.{Engine, Job, Peer}

  require Logger

  defstruct [
    :conf,
    :timer,
    interval: :timer.seconds(30),
    limit: 10_000,
    max_age: 60
  ]

  @impl Oban.Plugin
  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)

    if conf.testing in [:inline, :manual] do
      :ignore
    else
      {name, opts} = Keyword.pop(opts, :name)
      GenServer.start_link(__MODULE__, struct!(__MODULE__, opts), name: name)
    end
  end

  @impl Oban.Plugin
  def validate(_opts), do: :ok

  @impl GenServer
  def init(state) do
    {:ok, schedule_prune(state)}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    _ = prune(state)
    {:noreply, schedule_prune(state)}
  rescue
    error ->
      if BusyRetry.busy?(error) do
        Logger.warning("oban pruner sqlite busy, retrying next tick")
        {:noreply, schedule_prune(state)}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp prune(%{conf: conf} = state) do
    if Peer.leader?(conf) do
      BusyRetry.call(fn ->
        Oban.Repo.transaction(
          conf,
          fn ->
            {:ok, jobs} =
              Engine.prune_jobs(conf, Job, limit: state.limit, max_age: state.max_age)

            %{pruned_count: length(jobs)}
          end,
          on_exhausted: :log
        )
      end)
    else
      {:ok, %{pruned_count: 0}}
    end
  end

  defp schedule_prune(state) do
    %{state | timer: Process.send_after(self(), :prune, state.interval)}
  end
end
