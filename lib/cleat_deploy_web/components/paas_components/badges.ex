defmodule CleatDeployWeb.PaasComponents.Badges do
  @moduledoc false
  use Phoenix.Component

  import CleatDeployWeb.CoreComponents, only: [icon: 1]

  alias CleatDeploy.Apps.App

  attr :app, App, required: true

  def language_badge(assigns) do
    language = App.main_language(assigns.app)
    badge_classes = language_badge_classes(assigns.app.runtime)

    assigns = assign(assigns, language: language, badge_classes: badge_classes)

    ~H"""
    <span
      id={"app-#{@app.id}-language"}
      class={[
        "inline-flex items-center rounded border px-2 py-0.5 font-mono text-[10px] font-semibold uppercase tracking-wide",
        @badge_classes
      ]}
    >
      {@language}
    </span>
    """
  end

  defp language_badge_classes("golang"), do: "border-hd-green/40 bg-hd-green/10 text-hd-green"
  defp language_badge_classes("node"), do: "border-hd-blue/40 bg-hd-blue/10 text-hd-blue"
  defp language_badge_classes("rails"), do: "border-hd-red/40 bg-hd-red/10 text-hd-red"
  defp language_badge_classes("rust"), do: "border-amber-500/40 bg-amber-500/10 text-amber-500"
  defp language_badge_classes(_runtime), do: "border-hd-orange/40 bg-hd-orange/10 text-hd-orange"

  @doc """
  Whether the app opted into idle shutdown (auto sleep).

  The flag alone does not hibernate anything: the app also has to be deployed
  after it was turned on, which is what arms the wake agent.
  """
  attr :app, App, required: true

  def idle_badge(assigns) do
    assigns =
      assign(assigns,
        idle_label: if(assigns.app.idle_shutdown_enabled, do: "On", else: "Off"),
        idle_hint:
          if(assigns.app.idle_shutdown_enabled,
            do: "Auto sleep on — stops after the platform idle window, wakes on the next request",
            else: "Auto sleep off — this app never hibernates on its own"
          )
      )

    ~H"""
    <span
      id={"app-#{@app.id}-idle"}
      title={@idle_hint}
      class={[
        "inline-flex items-center gap-1 rounded border px-2 py-0.5 font-mono text-[10px] font-semibold uppercase tracking-wide",
        @app.idle_shutdown_enabled && "border-hd-green/40 bg-hd-green/10 text-hd-green",
        !@app.idle_shutdown_enabled && "border-hd-border bg-hd-aside text-hd-muted"
      ]}
    >
      <.icon :if={@app.idle_shutdown_enabled} name="hero-moon" class="size-3" />
      {@idle_label}
    </span>
    """
  end

  attr :app, App, required: true
  attr :memory, :any, default: nil

  @doc """
  Whether the app's unit is running (`On`) or stopped (`Off`).

  Comes from the same systemd probe that feeds the RAM/CPU columns. Static
  sites have no unit to probe, and a probe that has not answered yet reads as
  `—`.
  """
  def status_cell(assigns) do
    assigns = assign(assigns, state: status_state(assigns.app, assigns.memory))

    ~H"""
    <span
      id={"app-#{@app.id}-state"}
      title={@state.hint}
      class={[
        "inline-flex items-center gap-1.5 font-mono text-[11px] font-semibold uppercase tracking-wide",
        @state.class
      ]}
    >
      <span class={["size-1.5 rounded-full", @state.dot]} />
      {@state.label}
    </span>
    """
  end

  defp status_state(%App{runtime: "static"}, _memory) do
    %{
      label: "Static",
      hint: "Static site: served by Caddy, there is no process to stop",
      class: "text-hd-muted",
      dot: "bg-hd-muted/50"
    }
  end

  defp status_state(_app, %{active?: true}) do
    %{label: "On", hint: "Unit is running", class: "text-hd-green", dot: "bg-hd-green"}
  end

  defp status_state(_app, %{active?: false}) do
    %{
      label: "Off",
      hint: "Unit is stopped (auto sleep or hibernate) — the next request wakes it",
      class: "text-hd-blue",
      dot: "bg-hd-blue"
    }
  end

  defp status_state(_app, _memory) do
    %{
      label: "—",
      hint: "Reading systemd state",
      class: "text-hd-muted/60",
      dot: "bg-hd-muted/30"
    }
  end

  attr :app, App, required: true
  attr :memory, :any, default: nil

  def ram_cell(assigns) do
    peak = CleatDeploy.Apps.RuntimeMemory.format_peak(assigns.memory)

    assigns =
      assign(assigns, peak: peak, label: CleatDeploy.Apps.RuntimeMemory.format(assigns.memory))

    ~H"""
    <span
      id={"app-#{@app.id}-ram"}
      class="font-mono text-sm tabular-nums text-hd-text"
      title={@peak}
    >
      {@label}
    </span>
    """
  end

  attr :app, App, required: true
  attr :memory, :any, default: nil

  def cpu_cell(assigns) do
    assigns = assign(assigns, label: CleatDeploy.Apps.RuntimeMemory.format_cpu(assigns.memory))

    ~H"""
    <span
      id={"app-#{@app.id}-cpu"}
      class="font-mono text-sm tabular-nums text-hd-text"
      title="Share of one vCPU"
    >
      {@label}
    </span>
    """
  end

  attr :app, App, required: true
  attr :memory, :any, default: nil

  def disk_cell(assigns) do
    assigns = assign(assigns, label: CleatDeploy.Apps.RuntimeMemory.format_disk(assigns.memory))

    ~H"""
    <span
      id={"app-#{@app.id}-disk"}
      class="font-mono text-sm tabular-nums text-hd-text"
      title="Release + data"
    >
      {@label}
    </span>
    """
  end

  attr :status, :atom, required: true

  def deploy_status_badge(assigns) do
    {class, pulse?, label} =
      case assigns.status do
        :queued -> {"text-hd-orange", true, "queued"}
        :running -> {"text-sky-400", true, "running"}
        :success -> {"text-hd-green", false, "success"}
        :failed -> {"text-rose-500", false, "failed"}
      end

    assigns = assign(assigns, class: class, pulse?: pulse?, label: label)

    ~H"""
    <span class={["inline-flex items-center gap-1.5 font-mono text-xs capitalize", @class]}>
      <span
        :if={@pulse?}
        class={[
          "size-1.5 rounded-full bg-current",
          @status == :queued && "animate-ping",
          @status == :running && "animate-pulse"
        ]}
      />
      <span :if={not @pulse?} class="size-1.5 rounded-full bg-current" />
      {@label}
    </span>
    """
  end
end
