defmodule CleatDeployWeb.PaasComponents.Badges do
  @moduledoc false
  use Phoenix.Component

  import CleatDeployWeb.CoreComponents, only: [icon: 1]

  alias CleatDeploy.Apps.App

  attr :app, App, required: true

  # The runtime is a quiet mono word, not a colored identity badge: six
  # saturated hues in one table would fight the single ember accent.
  def language_badge(assigns) do
    language = App.main_language(assigns.app)

    assigns = assign(assigns, language: language)

    ~H"""
    <span id={"app-#{@app.id}-language"} class="font-mono text-xs text-hd-muted">
      {@language}
    </span>
    """
  end

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
        "inline-flex items-center gap-1.5 font-mono text-xs",
        @app.idle_shutdown_enabled && "text-hd-green",
        !@app.idle_shutdown_enabled && "text-hd-muted"
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
      class={["inline-flex items-center gap-1.5 font-mono text-xs", @state.class]}
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
      class: "text-hd-muted",
      dot: "bg-hd-muted/50"
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
      class={["font-mono text-[13px] tabular-nums", metric_value_class(@label)]}
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
      class={["font-mono text-[13px] tabular-nums", metric_value_class(@label)]}
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
      class={["font-mono text-[13px] tabular-nums", metric_value_class(@label)]}
      title="Release + data"
    >
      {@label}
    </span>
    """
  end

  defp metric_value_class("—"), do: "text-hd-muted/60"
  defp metric_value_class(_label), do: "text-hd-secondary"

  attr :status, :atom, required: true

  def deploy_status_badge(assigns) do
    {class, pulse?, label} =
      case assigns.status do
        :queued -> {"text-hd-orange", false, "queued"}
        :running -> {"text-hd-orange", true, "running"}
        :success -> {"text-hd-green", false, "success"}
        :failed -> {"text-hd-red", false, "failed"}
      end

    assigns = assign(assigns, class: class, pulse?: pulse?, label: label)

    ~H"""
    <span class={["inline-flex items-center gap-1.5 font-mono text-xs capitalize", @class]}>
      <span class={[
        "size-1.5 rounded-full bg-current",
        @pulse? && "motion-safe:animate-pulse"
      ]} />
      {@label}
    </span>
    """
  end
end
