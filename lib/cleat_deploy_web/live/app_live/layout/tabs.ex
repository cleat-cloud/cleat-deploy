defmodule CleatDeployWeb.AppLive.Layout.Tabs do
  @moduledoc false
  use CleatDeployWeb, :html

  attr :app, :map, required: true
  attr :active_tab, :atom, required: true
  attr :detail_tabs, :list, required: true

  def tab_bar(assigns) do
    ~H"""
    <div
      role="tablist"
      aria-label="App configuration"
      class="flex flex-wrap items-center gap-1 border-b border-hd-border"
    >
      <.detail_tab_link
        tab={:deployments}
        label="Deployments"
        icon="hero-rocket-launch"
        active?={@active_tab == :deployments}
        href={~p"/apps/#{@app.id}/deployments"}
      />
      <.detail_tab_link
        tab={:logs}
        label="Logs"
        icon="hero-command-line"
        active?={@active_tab == :logs}
        href={~p"/apps/#{@app.id}?tab=logs"}
      />
      <.detail_tab_link
        tab={:analytics}
        label="Analytics"
        icon="hero-chart-bar"
        active?={@active_tab == :analytics}
        href={~p"/apps/#{@app.id}?tab=analytics"}
      />
      <.detail_tab_link
        :if={:domains in @detail_tabs}
        tab={:domains}
        label="Tenant domains"
        icon="hero-globe-alt"
        active?={@active_tab == :domains}
        href={~p"/apps/#{@app.id}?tab=domains"}
      />
      <.detail_tab_link
        tab={:environment}
        label="Environment"
        icon="hero-circle-stack"
        active?={@active_tab == :environment}
        href={~p"/apps/#{@app.id}?tab=environment"}
      />
      <.detail_tab_link
        :if={:runtime in @detail_tabs}
        tab={:runtime}
        label="Runtime"
        icon="hero-cube"
        active?={@active_tab == :runtime}
        href={~p"/apps/#{@app.id}?tab=runtime"}
      />
      <.detail_tab_link
        tab={:webhook}
        label="Webhook"
        icon="hero-link"
        active?={@active_tab == :webhook}
        href={~p"/apps/#{@app.id}?tab=webhook"}
      />
      <.detail_tab_link
        tab={:danger}
        label="Danger zone"
        icon="hero-exclamation-triangle"
        tone={:danger}
        active?={@active_tab == :danger}
        href={~p"/apps/#{@app.id}?tab=danger"}
      />
    </div>
    """
  end

  attr :tab, :atom, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active?, :boolean, required: true
  attr :href, :string, required: true
  attr :tone, :atom, default: :default

  def detail_tab_link(assigns) do
    ~H"""
    <.link
      id={"app-detail-tab-#{@tab}"}
      navigate={@href}
      role="tab"
      aria-selected={@active?}
      class={[
        "-mb-px flex items-center gap-1.5 border-b-2 px-2.5 py-2 text-[13px] font-medium transition-colors",
        @active? && @tone == :danger && "border-hd-red text-hd-red",
        @active? && @tone != :danger && "border-hd-orange text-hd-text",
        !@active? && @tone == :danger && "border-transparent text-hd-muted hover:text-hd-red",
        !@active? && @tone != :danger && "border-transparent text-hd-muted hover:text-hd-text"
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      <span>{@label}</span>
    </.link>
    """
  end

  def detail_tabs(custom_domain_app?, runtime_packages) do
    [:deployments, :logs, :analytics]
    |> then(fn tabs -> if custom_domain_app?, do: tabs ++ [:domains], else: tabs end)
    |> Kernel.++([:environment])
    |> then(fn tabs -> if runtime_packages != [], do: tabs ++ [:runtime], else: tabs end)
    |> Kernel.++([:webhook, :danger])
  end

  def parse_detail_tab(tab)
      when tab in ["logs", "analytics", "domains", "environment", "runtime", "webhook", "danger"] do
    String.to_existing_atom(tab)
  end

  def parse_detail_tab(_), do: :environment
end
