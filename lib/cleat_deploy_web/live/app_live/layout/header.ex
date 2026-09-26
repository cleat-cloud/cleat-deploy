defmodule CleatDeployWeb.AppLive.Layout.Header do
  @moduledoc false
  use CleatDeployWeb, :html

  attr :app, :map, required: true
  attr :apps, :list, required: true
  attr :instances, :list, default: []

  def shell_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3 border-b border-hd-border/40 pb-3">
      <div class="flex items-center gap-2">
        <span class="font-mono text-[10px] uppercase tracking-wider text-hd-muted">
          Active Application:
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
          <span class="font-mono text-[10px] uppercase tracking-wider text-hd-muted">
            Instances:
          </span>
          <.link
            :for={instance <- @instances}
            id={"app-instance-#{instance.slug}"}
            navigate={~p"/apps/#{instance.id}/deployments"}
            class="font-mono text-[11px] text-hd-orange hover:underline"
          >
            {instance.slug} ({instance.branch})
          </.link>
        </div>
        <div>
          Repository mapping:
          <.repo_link
            id="app-repo-mapping"
            repo={@app.github_repo}
            class="font-mono text-hd-orange hover:text-hd-orange-dark"
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

  def runtime_badge_class("golang"), do: "border-hd-green/40 bg-hd-green/10 text-hd-green"
  def runtime_badge_class("node"), do: "border-hd-blue/40 bg-hd-blue/10 text-hd-blue"
  def runtime_badge_class("rails"), do: "border-hd-red/40 bg-hd-red/10 text-hd-red"
  def runtime_badge_class("rust"), do: "border-amber-500/40 bg-amber-500/10 text-amber-500"
  def runtime_badge_class("gleam"), do: "border-pink-400/40 bg-pink-400/10 text-pink-400"
  def runtime_badge_class(_runtime), do: "border-hd-border bg-hd-aside text-hd-orange"

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
