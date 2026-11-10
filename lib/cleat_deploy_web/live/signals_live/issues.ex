defmodule CleatDeployWeb.SignalsLive.Issues do
  @moduledoc false
  use CleatDeployWeb, :html

  def tabs(assigns) do
    ~H"""
    <nav id="signals-tabs" class="flex flex-wrap gap-2">
      <.link
        id="signals-tab-overview"
        patch={~p"/signals?#{overview_query(@selected)}"}
        class={tab_class(@panel == :overview)}
      >
        Overview
      </.link>
      <.link
        id="signals-tab-issues"
        patch={~p"/signals?#{issues_query(@selected)}"}
        class={tab_class(@panel == :issues)}
      >
        Issues
      </.link>
    </nav>
    """
  end

  def panel(assigns) do
    ~H"""
    <div id="signals-issues" class="grid gap-4 lg:grid-cols-2">
      <section class="paas-card overflow-hidden">
        <div class="border-b border-hd-border px-5 py-3.5">
          <h3 class="text-sm font-medium text-hd-text">
            Erros em aberto
          </h3>
        </div>
        <div :if={@issues == []} class="px-4 py-6 text-sm text-hd-muted">
          Nenhum erro em aberto.
        </div>
        <ul :if={@issues != []} class="divide-y divide-hd-border">
          <li
            :for={issue <- @issues}
            class="flex flex-wrap items-start justify-between gap-3 px-4 py-3"
          >
            <.link
              id={"signals-issue-#{issue.id}"}
              patch={~p"/signals?#{issues_query(@selected, issue.id)}"}
              class="min-w-0 flex-1"
            >
              <p class="truncate font-mono text-sm text-hd-text">{issue.sample}</p>
              <p class="mt-1 font-mono text-xs text-hd-muted">
                {issue.app && issue.app.slug} · {issue.severity} · {issue.count}× · {issue.source}
              </p>
            </.link>
            <div class="flex flex-wrap gap-2">
              <button
                id={"signals-issue-resolve-#{issue.id}"}
                type="button"
                phx-click="resolve_issue"
                phx-value-id={issue.id}
                class="paas-btn-secondary px-3 py-1.5 text-xs"
              >
                Resolver
              </button>
              <button
                id={"signals-issue-ignore-#{issue.id}"}
                type="button"
                phx-click="ignore_issue"
                phx-value-id={issue.id}
                class="paas-btn-secondary px-3 py-1.5 text-xs"
              >
                Ignorar
              </button>
            </div>
          </li>
        </ul>
      </section>

      <section :if={@issue_detail} id="signals-issue-detail" class="paas-card overflow-hidden">
        <div class="border-b border-hd-border px-5 py-3.5">
          <h3 class="text-sm font-medium text-hd-text">
            {@issue_detail.sample}
          </h3>
          <p class="mt-1 font-mono text-xs text-hd-muted">
            {@issue_detail.app && @issue_detail.app.slug} · {@issue_detail.status} · {@issue_detail.count}× · {@issue_detail.source}
          </p>
        </div>
        <div class="space-y-2 px-4 py-3">
          <p :if={@issue_events == []} class="text-sm text-hd-muted">
            Sem eventos recentes.
          </p>
          <div
            :for={event <- @issue_events}
            id={"signals-issue-event-#{event.id}"}
            class="rounded-lg border border-hd-border bg-hd-aside px-3 py-2 font-mono text-xs"
          >
            <p class="text-hd-muted">{event.severity} · {event.occurred_at}</p>
            <p class="mt-1 whitespace-pre-wrap text-hd-text">{event.message}</p>
          </div>
        </div>
      </section>
    </div>
    """
  end

  def overview_query(nil), do: %{}
  def overview_query(app), do: %{"app" => app.slug}

  def issues_query(selected, issue_id \\ nil) do
    %{"tab" => "issues"}
    |> maybe_put("app", selected && selected.slug)
    |> maybe_put("issue_id", issue_id)
  end

  defp maybe_put(map, _key, empty) when empty in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp tab_class(true), do: "paas-btn-primary"
  defp tab_class(false), do: "paas-btn-secondary"
end
