defmodule CleatDeployWeb.PaasComponents.Copy do
  @moduledoc false
  use Phoenix.Component

  import CleatDeployWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false
  attr :hidden?, :boolean, default: false

  def copy_field(assigns) do
    ~H"""
    <div class="space-y-1">
      <span
        :if={@label != ""}
        class="font-mono text-[9px] font-semibold uppercase tracking-wider text-hd-muted"
      >
        {@label}
      </span>
      <div class="flex items-center justify-between gap-2 rounded border border-hd-border bg-hd-aside px-2.5 py-1.5 text-xs">
        <span class={["min-w-0 flex-1 truncate font-medium text-hd-text", @mono && "font-mono"]}>
          {if @hidden?, do: String.duplicate("•", 32), else: @value}
        </span>
        <button
          :if={not @hidden?}
          id={"copy-#{@id}"}
          type="button"
          phx-hook=".Copy"
          data-clipboard={@value}
          class="shrink-0 text-hd-muted transition-colors hover:text-hd-orange"
          aria-label={"Copy #{@label}"}
        >
          <.icon name="hero-clipboard-document" class="size-3.5" />
        </button>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const text = this.el.dataset.clipboard || "";
                navigator.clipboard.writeText(text).then(() => {
                  this.el.classList.add("text-hd-green");
                  setTimeout(() => this.el.classList.remove("text-hd-green"), 1200);
                });
              });
            }
          }
        </script>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :id, :string, default: nil
  attr :value, :string, required: true
  attr :mono, :boolean, default: false
  attr :sub, :string, default: nil
  attr :href, :string, default: nil

  def info_tile(%{href: href} = assigns) when is_binary(href) do
    ~H"""
    <.link
      id={@id}
      navigate={@href}
      class="paas-card flex flex-col justify-between space-y-1 p-3 transition-colors hover:border-hd-orange/50"
    >
      <span class="font-mono text-[9px] font-bold uppercase tracking-widest text-hd-muted">
        {@label}
      </span>
      <p class={["truncate text-xs font-semibold text-hd-text", @mono && "font-mono"]}>{@value}</p>
      <p :if={@sub} class="block font-mono text-[10px] text-hd-orange">{@sub}</p>
    </.link>
    """
  end

  def info_tile(assigns) do
    ~H"""
    <div id={@id} class="paas-card flex flex-col justify-between space-y-1 p-3">
      <span class="font-mono text-[9px] font-bold uppercase tracking-widest text-hd-muted">
        {@label}
      </span>
      <p class={["truncate text-xs font-semibold text-hd-text", @mono && "font-mono"]}>{@value}</p>
      <p :if={@sub} class="block font-mono text-[10px] text-hd-muted">{@sub}</p>
    </div>
    """
  end
end
