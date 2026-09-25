defmodule CleatDeployWeb.PaasComponents.RepoPicker do
  @moduledoc false
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  import CleatDeployWeb.CoreComponents, only: [icon: 1]

  @repo_picker_limit 50

  attr :field, Phoenix.HTML.FormField, required: true
  attr :repos, :list, required: true
  attr :repo_search, :string, default: ""
  attr :open?, :boolean, default: false

  def github_repo_picker(assigns) do
    selected = to_string(assigns.field.value || "")
    filtered = filter_repo_options(assigns.repos, assigns.repo_search, @repo_picker_limit)
    total_matches = count_repo_matches(assigns.repos, assigns.repo_search)

    assigns =
      assigns
      |> assign(:selected, selected)
      |> assign(:filtered, filtered)
      |> assign(:total_matches, total_matches)
      |> assign(
        :search_display,
        repo_search_display(assigns.open?, assigns.repo_search, selected)
      )
      |> assign(:errors, assigns.field.errors)

    ~H"""
    <div
      id="github-repo-picker"
      class="fieldset relative mb-2"
      phx-click-away={JS.push("close_repo_picker")}
    >
      <label for="github-repo-search">
        <span class="label mb-1">GitHub repository</span>
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-hd-muted"
          />
          <input
            type="text"
            id="github-repo-search"
            name="repo_search"
            value={@search_display}
            phx-focus="open_repo_picker"
            phx-keyup="search_repos"
            phx-debounce="150"
            placeholder="Search repositories…"
            autocomplete="off"
            class={[
              "paas-input w-full pl-9",
              @errors != [] && "border-rose-500"
            ]}
          />
          <input type="hidden" name={@field.name} id={@field.id} value={@selected} />
        </div>
      </label>

      <ul
        :if={@open?}
        id="github-repo-options"
        class="absolute z-20 mt-1 max-h-56 w-full overflow-y-auto rounded-md border border-hd-border bg-hd-card shadow-xl"
      >
        <li :if={@filtered == []} class="px-3 py-2 text-xs text-hd-muted">
          No repositories match your search.
        </li>
        <li :for={{label, value} <- @filtered} id={"github-repo-option-#{slugify_option_id(value)}"}>
          <button
            type="button"
            phx-click="pick_repo"
            phx-value-repo={value}
            class={[
              "flex w-full items-center px-3 py-2 text-left font-mono text-xs transition-colors hover:bg-hd-aside",
              @selected == value && "bg-hd-aside/80 text-hd-orange"
            ]}
          >
            {label}
          </button>
        </li>
        <li
          :if={@total_matches > @repo_picker_limit}
          class="border-t border-hd-border px-3 py-2 text-[10px] text-hd-muted"
        >
          Showing first 50 of {@total_matches} matches. Refine your search.
        </li>
      </ul>

      <p :for={msg <- @errors} class="mt-1 text-xs text-rose-400">
        {translate_form_error(msg)}
      </p>
    </div>
    """
  end

  @doc false
  def filter_repo_options(repos, query, limit \\ @repo_picker_limit) do
    repos
    |> matching_repo_options(query)
    |> Enum.take(limit)
  end

  @doc false
  def count_repo_matches(repos, query) do
    repos |> matching_repo_options(query) |> length()
  end

  defp matching_repo_options(repos, query) do
    query = String.downcase(String.trim(to_string(query || "")))

    Enum.filter(repos, fn {label, _value} ->
      query == "" or String.contains?(String.downcase(label), query)
    end)
  end

  defp repo_search_display(true, repo_search, _selected), do: repo_search

  defp repo_search_display(false, _repo_search, selected) when selected != "",
    do: selected

  defp repo_search_display(false, repo_search, _selected), do: repo_search

  defp translate_form_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp translate_form_error(msg) when is_binary(msg), do: msg

  defp slugify_option_id(value) do
    value
    |> String.replace("/", "-")
    |> String.replace(~r/[^a-zA-Z0-9-]+/u, "-")
  end
end
