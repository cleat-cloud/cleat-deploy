defmodule CleatDeployWeb.AppLive.Index.Listing do
  @moduledoc false
  use CleatDeployWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, stream: 4]

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App

  @page_size 10

  def page_size, do: @page_size

  def apply_filter_params(socket, params) do
    socket
    |> assign(:apps_runtime, parse_runtime(params["runtime"]))
    |> assign(:apps_query, params["query"] || "")
    |> assign(:apps_idle, parse_toggle(params["idle"]))
    |> assign(:apps_state, parse_toggle(params["state"]))
    |> assign(:apps_page, 1)
    |> restream_apps()
  end

  def parse_runtime("golang"), do: :golang
  def parse_runtime("node"), do: :node
  def parse_runtime("static"), do: :static
  def parse_runtime("rails"), do: :rails
  def parse_runtime("rust"), do: :rust
  def parse_runtime("phoenix"), do: :phoenix
  def parse_runtime(_), do: :all

  # Filters live in the URL (`/apps?runtime=golang&idle=on&state=off&query=cat`)
  # so they are shareable and survive reload/back-forward.
  def apps_filter_path(socket, overrides) do
    attrs =
      Map.merge(
        %{
          runtime: socket.assigns.apps_runtime,
          query: socket.assigns.apps_query,
          idle: socket.assigns.apps_idle,
          state: socket.assigns.apps_state
        },
        overrides
      )

    params =
      %{}
      |> put_runtime_param(attrs.runtime)
      |> put_query_param(attrs.query)
      |> put_toggle_param(:idle, attrs.idle)
      |> put_toggle_param(:state, attrs.state)

    if map_size(params) == 0, do: ~p"/apps", else: ~p"/apps?#{params}"
  end

  def put_runtime_param(params, :all), do: params

  def put_runtime_param(params, runtime),
    do: Map.put(params, :runtime, Atom.to_string(runtime))

  def put_query_param(params, query) when query in [nil, ""], do: params
  def put_query_param(params, query), do: Map.put(params, :query, query)

  def put_toggle_param(params, _key, :all), do: params

  def put_toggle_param(params, key, value),
    do: Map.put(params, key, Atom.to_string(value))

  def parse_toggle("on"), do: :on
  def parse_toggle("off"), do: :off
  def parse_toggle(_value), do: :all

  # Re-reads the systemd state so the status column and the power buttons
  # reflect what just happened.
  def refresh_runtime(socket) do
    send(self(), :load_app_memory)
    socket
  end

  def find_app(apps, id) do
    Enum.find(apps, &(to_string(&1.id) == to_string(id)))
  end

  def server_options(servers) do
    Enum.map(servers, fn server -> {server.name, server.id} end)
  end

  def server_label(servers, server_id) do
    servers
    |> Enum.find_value(fn server ->
      if to_string(server.id) == to_string(server_id), do: server.name
    end)
  end

  def app_registered_message(:synced),
    do: "App registered — GitHub webhook connected for automatic deploys"

  def app_registered_message(:no_token),
    do: "App registered — set GITHUB_TOKEN on the panel to auto-configure webhooks"

  def app_registered_message({:error, message}),
    do: "App registered — webhook not configured (#{message})"

  def restream_apps(socket) do
    page =
      Apps.page_apps(socket.assigns.current_scope,
        page: socket.assigns.apps_page,
        page_size: @page_size,
        query: socket.assigns.apps_query,
        runtime: socket.assigns.apps_runtime,
        idle: socket.assigns.apps_idle,
        sort: socket.assigns.apps_sort,
        dir: socket.assigns.apps_sort_dir
      )

    memory = socket.assigns.app_memory

    entries =
      page.entries
      |> Enum.filter(&matches_state?(&1, memory, socket.assigns.apps_state))
      |> maybe_metric_sort(socket.assigns.apps_sort, socket.assigns.apps_sort_dir, memory)

    total =
      if socket.assigns.apps_state == :all, do: page.total, else: length(entries)

    total_pages =
      if socket.assigns.apps_state == :all,
        do: page.total_pages,
        else: max(div(total + @page_size - 1, @page_size), 1)

    ids = Enum.map(entries, & &1.id)

    filtered? =
      socket.assigns.apps_query not in [nil, ""] or
        socket.assigns.apps_runtime != :all or
        socket.assigns.apps_idle != :all or
        socket.assigns.apps_state != :all

    socket =
      socket
      |> assign(:apps_list, entries)
      |> assign(:apps_filtered?, filtered?)
      |> assign(:apps_page, page.page)
      |> assign(:apps_total_pages, total_pages)
      |> assign(:apps_visible_count, total)
      |> stream(:apps, entries, reset: true)

    if connected?(socket) and ids != [] and socket.assigns.apps_page_ids != ids do
      send(self(), :load_app_memory)
    end

    assign(socket, :apps_page_ids, ids)
  end

  def maybe_metric_sort(apps, field, dir, memory)
      when field in [:ram, :cpu, :disk, :state] do
    sort_apps(apps, field, dir, memory)
  end

  def maybe_metric_sort(apps, _field, _dir, _memory), do: apps

  def matches_state?(_app, _memory, :all), do: true

  def matches_state?(app, memory, state) do
    app_state(app, Map.get(memory, app.id)) == state
  end

  # Static sites have no unit to probe: Caddy serves them, so they count as on.
  # An app whose probe has not answered yet is `:unknown` and matches no filter.
  def app_state(%App{runtime: "static"}, _memory), do: :on
  def app_state(_app, %{active?: true}), do: :on
  def app_state(_app, %{active?: false}), do: :off
  def app_state(_app, _memory), do: :unknown

  def sort_apps(apps, field, dir, memory) do
    {present, missing} = Enum.split_with(apps, &(sort_value(&1, field, memory) != :missing))

    sorted = Enum.sort_by(present, &sort_value(&1, field, memory))
    sorted = if dir == :desc, do: Enum.reverse(sorted), else: sorted
    sorted ++ missing
  end

  def sort_value(app, :name, _memory), do: String.downcase(app.name || "")
  def sort_value(app, :host, _memory), do: String.downcase(app.host || "")
  def sort_value(app, :language, _memory), do: App.main_language(app)

  def sort_value(app, :server, _memory),
    do: String.downcase((app.server && app.server.name) || "")

  def sort_value(app, :ram, memory), do: metric(memory, app.id, :bytes)
  def sort_value(app, :cpu, memory), do: metric(memory, app.id, :cpu_pct)
  def sort_value(app, :disk, memory), do: metric(memory, app.id, :disk_bytes)

  # Booleans and ranks instead of labels: `:on/:off/:unknown` would otherwise
  # sort alphabetically (`:off` first) instead of by meaning.
  def sort_value(app, :idle, _memory), do: app.idle_shutdown_enabled

  def sort_value(app, :state, memory) do
    case app_state(app, Map.get(memory, app.id)) do
      :on -> 0
      :off -> 1
      :unknown -> 2
    end
  end

  def sort_value(app, _field, _memory), do: String.downcase(app.name || "")

  def metric(memory, app_id, key) do
    case memory[app_id] do
      %{^key => value} when is_number(value) -> value
      _ -> :missing
    end
  end

  def sort_field("host"), do: :host
  def sort_field("language"), do: :language
  def sort_field("ram"), do: :ram
  def sort_field("cpu"), do: :cpu
  def sort_field("disk"), do: :disk
  def sort_field("server"), do: :server
  def sort_field("idle"), do: :idle
  def sort_field("state"), do: :state
  def sort_field(_), do: :name

  def toggle_dir(:asc), do: :desc
  def toggle_dir(_dir), do: :asc

  def parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  def parse_page(page) when is_integer(page) and page > 0, do: page
  def parse_page(_), do: 1

  def apps_range(_page, 0), do: "0-0"

  def apps_range(page, total) when is_integer(page) and is_integer(total) do
    from = (page - 1) * @page_size + 1
    to = min(page * @page_size, total)
    "#{from}-#{to}"
  end
end
