defmodule CleatDeployWeb.AppLive.Show.LogsTab do
  @moduledoc false
  use CleatDeployWeb, :html

  def explorer(assigns) do
    ~H"""
    <div id="app-log-events" class="space-y-3">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="space-y-0.5">
          <h3 class="font-display text-xs font-semibold text-hd-text">Collected events</h3>
          <p class="text-[11px] text-hd-muted">
            Searchable store for this app, enriched with release and environment <span class="font-mono text-hd-orange">{@app.branch}</span>.
          </p>
        </div>
        <button
          id="refresh-log-events"
          type="button"
          phx-click="refresh_log_events"
          class="paas-btn-secondary text-[10px]"
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh store
        </button>
      </div>

      <form
        id="app-log-events-form"
        phx-change="search_log_events"
        phx-submit="search_log_events"
        class="grid gap-2 sm:grid-cols-3"
      >
        <input
          id="log-events-q"
          type="search"
          name="q"
          value={@log_filters["q"]}
          placeholder="Search message"
          class="paas-input font-mono text-[11px]"
        />
        <select
          id="log-events-min-severity"
          name="min_severity"
          class="paas-input font-mono text-[11px]"
        >
          <option value="" selected={@log_filters["min_severity"] in [nil, ""]}>All levels</option>
          <option
            :for={level <- ~w(err warning notice info debug)}
            value={level}
            selected={@log_filters["min_severity"] == level}
          >
            {level}+
          </option>
        </select>
        <input
          id="log-events-release"
          type="text"
          name="release"
          value={@log_filters["release"]}
          placeholder="Release sha"
          class="paas-input font-mono text-[11px]"
          spellcheck="false"
        />
      </form>

      <div
        :if={@log_groups != []}
        id="app-log-error-groups"
        class="grid gap-2 sm:grid-cols-2"
      >
        <article
          :for={group <- @log_groups}
          id={"log-group-#{group.fingerprint}"}
          class="rounded-md border border-hd-border bg-hd-aside px-3 py-2"
        >
          <div class="flex items-center justify-between gap-2">
            <span class="font-mono text-[10px] uppercase tracking-wider text-rose-400">
              {group.severity}
            </span>
            <span class="font-mono text-[10px] text-hd-muted">{group.count}×</span>
          </div>
          <p class="mt-1 truncate font-mono text-[11px] text-hd-text">{group.sample}</p>
        </article>
      </div>

      <div class="overflow-hidden rounded-md border border-hd-border bg-hd-bg font-mono text-[11px] text-hd-text">
        <div class="flex items-center justify-between border-b border-hd-border bg-hd-aside px-3 py-1.5">
          <span class="text-[10px] font-semibold tracking-wider text-hd-muted">EVENT STORE</span>
          <span class="font-mono text-[10px] text-hd-muted">{length(@log_events)} rows</span>
        </div>
        <div id="app-log-events-body" class="max-h-80 overflow-auto p-3 leading-5">
          <div :if={@log_events == []} class="text-hd-muted">
            No collected events yet. Deploy or wait for the collector.
          </div>
          <div
            :for={event <- @log_events}
            id={"log-event-#{event.id}"}
            class="grid grid-cols-[7rem_4.5rem_minmax(0,1fr)] gap-3 py-0.5"
          >
            <span class="text-hd-muted/70">{format_time(event.occurred_at)}</span>
            <span class={severity_class(event.severity)}>{event.severity}</span>
            <span class="min-w-0 whitespace-pre-wrap break-all">{event.message}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%H:%M:%S")
  defp format_time(_), do: "—"

  defp severity_class(level) when level in ~w(emerg alert crit err), do: "text-rose-400"
  defp severity_class("warning"), do: "text-hd-orange"
  defp severity_class(_), do: "text-hd-muted"
end
