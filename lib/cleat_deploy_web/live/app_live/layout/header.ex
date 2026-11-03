defmodule CleatDeployWeb.AppLive.Layout.Header do
  @moduledoc false
  use CleatDeployWeb, :html

  attr :app, :map, required: true
  attr :apps, :list, required: true
  attr :instances, :list, default: []

  def shell_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex items-center gap-2.5">
        <span class="text-xs text-hd-muted">
          Active app
        </span>
        <select
          id="app-selector"
          class="paas-select"
          phx-change="select_app"
          name="app_id"
        >
          <option :for={app <- @apps} value={app.id} selected={app.id == @app.id}>
            {app.name} ({app.branch})
          </option>
        </select>
      </div>
      <div class="flex flex-wrap items-center gap-3 text-xs text-hd-muted">
        <div :if={@instances != []} id="app-instances" class="flex items-center gap-2">
          <span class="text-xs text-hd-muted">
            Instances
          </span>
          <.link
            :for={instance <- @instances}
            id={"app-instance-#{instance.slug}"}
            navigate={~p"/apps/#{instance.id}/deployments"}
            class="font-mono text-xs text-hd-secondary transition-colors hover:text-hd-text"
          >
            {instance.slug} ({instance.branch})
          </.link>
        </div>
        <div class="flex items-center gap-1.5">
          <span>Repository</span>
          <.repo_link
            id="app-repo-mapping"
            repo={@app.github_repo}
            class="font-mono text-xs text-hd-secondary hover:text-hd-text"
          />
        </div>
      </div>
    </div>
    """
  end

  def hibernated?(%{active?: false}), do: true
  def hibernated?(_memory), do: false

  def runtime_badge_label("golang"), do: "GO"
  def runtime_badge_label("node"), do: "JS"
  def runtime_badge_label("rails"), do: "RB"
  def runtime_badge_label("rust"), do: "RS"
  def runtime_badge_label("gleam"), do: "GL"
  def runtime_badge_label("static"), do: "HTML"
  def runtime_badge_label(_runtime), do: "PHX"

  # One neutral treatment for every runtime: the language is a fact, the
  # ember accent is reserved for the app that is live or selected.
  def runtime_badge_class(_runtime), do: "border-hd-border bg-hd-raised text-hd-secondary"

  attr :id, :string, required: true
  attr :hosts, :list, required: true
  attr :class, :string, default: nil

  def host_links(assigns) do
    ~H"""
    <div
      :if={@hosts != []}
      id={@id}
      class={[
        "flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-1",
        @class
      ]}
    >
      <.icon name="hero-globe-alt" class="size-3.5 shrink-0 text-hd-muted" />
      <%= for {host, index} <- Enum.with_index(@hosts) do %>
        <span :if={index > 0} class="select-none text-hd-muted/50" aria-hidden="true">·</span>
        <.link
          id={"#{@id}-#{host_dom_id(host)}"}
          href={"https://#{host}"}
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center whitespace-nowrap font-mono text-[13px] text-hd-secondary transition-colors hover:text-hd-text"
        >
          {host}
        </.link>
      <% end %>
    </div>
    """
  end

  defp host_dom_id(host) do
    host
    |> String.replace(~r/[^a-z0-9]+/i, "-")
    |> String.trim("-")
  end

  attr :id, :string, required: true
  attr :repo, :string, required: true
  attr :class, :string, required: true

  def repo_link(assigns) do
    ~H"""
    <.link
      id={@id}
      href={"https://github.com/#{@repo}"}
      target="_blank"
      rel="noopener noreferrer"
      class={[@class, "transition-colors hover:underline"]}
    >
      {@repo}
    </.link>
    """
  end
end
