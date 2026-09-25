defmodule CleatDeployWeb.PaasComponents.Terminal do
  @moduledoc false
  use Phoenix.Component

  import CleatDeployWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, default: "deploy-terminal"
  attr :deployment, :map, required: true
  attr :active?, :boolean, default: false
  attr :duration, :string, default: nil

  def deploy_terminal(assigns) do
    lines =
      assigns.deployment.log
      |> to_string()
      |> String.split("\n", trim: true)

    assigns = assign(assigns, :lines, lines)

    ~H"""
    <div
      id={@id}
      class="overflow-hidden rounded-md border border-hd-border bg-hd-bg font-mono text-[11px] text-hd-text"
    >
      <div class="flex items-center justify-between border-b border-hd-border bg-hd-aside px-3 py-1.5">
        <div class="flex items-center gap-1.5">
          <.icon name="hero-command-line" class="size-3.5 text-hd-orange" />
          <span class="text-[10px] font-semibold tracking-wider text-hd-muted">
            BUILD CONTAINER SHELL
          </span>
          <span class="rounded border border-hd-border bg-hd-card px-1 py-0.5 font-mono text-[9px] text-hd-muted">
            SHA: {@deployment.git_sha}
          </span>
        </div>
        <CleatDeployWeb.PaasComponents.Badges.deploy_status_badge status={@deployment.status} />
      </div>

      <div
        id="deploy-terminal-body"
        phx-hook=".TerminalScroll"
        class="h-56 overflow-auto p-3 font-mono text-[11px] leading-5"
      >
        <div :if={@lines == []} class="text-hd-muted">Waiting for build output…</div>
        <div :for={{line, index} <- Enum.with_index(@lines)} class="flex items-start">
          <span class="sticky left-0 z-10 mr-3 w-8 shrink-0 select-none bg-hd-bg pr-1 text-right tabular-nums text-hd-muted/40">
            {String.pad_leading(Integer.to_string(index + 1), 2, "0")}
          </span>
          <span class={["min-w-0 whitespace-pre", terminal_line_class(line)]}>{line}</span>
        </div>
        <span :if={@active?} class="ml-8 inline-block h-3 w-1 animate-pulse bg-hd-orange" />
        <script :type={Phoenix.LiveView.ColocatedHook} name=".TerminalScroll">
          export default {
            mounted() { this.scroll(); },
            updated() { this.scroll(); },
            scroll() {
              this.el.scrollTop = this.el.scrollHeight;
            }
          }
        </script>
      </div>

      <div class="flex items-center justify-between border-t border-hd-border bg-hd-aside px-3 py-1 text-[10px] text-hd-muted">
        <div class="flex items-center gap-2">
          <span>Elixir 1.16.2</span>
          <span>OTP 26.2.1</span>
          <span>Phoenix 1.7.12</span>
        </div>
        <div class="flex items-center gap-3">
          <span :if={@duration && @duration != "—"} class="tabular-nums text-hd-text">
            {@duration}
          </span>
          <span>Target VM: us-east-1</span>
        </div>
      </div>
    </div>
    """
  end

  defp terminal_line_class(line) do
    cond do
      String.starts_with?(line, "==>") ->
        "font-semibold text-hd-orange"

      String.starts_with?(line, "$") ->
        "text-hd-muted"

      String.contains?(line, "SUCCESS") or String.contains?(line, "successful") ->
        "text-hd-green"

      String.contains?(line, "FAIL") or String.contains?(line, "Error") ->
        "font-medium text-rose-500"

      true ->
        "text-hd-text"
    end
  end
end
